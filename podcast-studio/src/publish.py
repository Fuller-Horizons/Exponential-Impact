"""Publish a finished project to YouTube, with a title and description written by the local model.

  python publish.py pack   --project P [--model gemma3:4b]   writes publish.json (title, description, tags) + thumbnail.jpg
  python publish.py upload --project P            (sign-in kept encrypted in <profile>\\secrets)

Upload uses the YouTube Data API with your own Google sign-in. Nothing is uploaded until you run `upload`,
and the video is private unless publish.json says otherwise. Scheduling ("publish_at") needs privacy "private".
"""
import argparse
import datetime
import os
import subprocess

from common import FF, fail, log, read_json, read_text, write_json

SCOPES = ["https://www.googleapis.com/auth/youtube.upload"]
PACK_SCHEMA = {"type": "object", "required": ["title", "description", "tags"], "properties": {
    "title": {"type": "string"}, "description": {"type": "string"},
    "tags": {"type": "array", "items": {"type": "string"}}}}
DEFAULTS = {"title": "", "description": "", "tags": "", "privacy": "private", "publish_at": ""}


def load(project):
    data = dict(DEFAULTS)
    data.update(read_json(os.path.join(project, "publish.json"), {}) or {})
    return data


def pack(project, model):
    """Write a title, description and tags from the script, and cut a thumbnail from the video."""
    import llm

    script_path = os.path.join(project, "script.txt")
    if not os.path.exists(script_path):
        fail("This project has no script yet. Make the video first.")
    script = read_text(script_path)[:4000]
    title = (read_json(os.path.join(project, "script.json"), {}) or {}).get("title", "")
    got = llm.chat("You write YouTube titles and descriptions for short podcast videos. Reply with JSON only. "
                   "Be specific and honest: no clickbait the video does not deliver, no emojis.",
                   f"Working title: {title}\n\nWhat is said in the video:\n{script}\n\n"
                   "Return JSON: \"title\" (under 70 characters), \"description\" (2 to 4 short sentences, then a blank "
                   "line, then 3 to 5 hashtags), \"tags\" (5 to 10 short search phrases, no # sign).",
                   model, schema=PACK_SCHEMA, temperature=0.5)
    data = load(project)
    data["title"] = " ".join(str(got.get("title") or title).split())[:100]
    data["description"] = str(got.get("description") or "").strip()[:4900]
    tags = [" ".join(str(t).replace("#", "").split()) for t in (got.get("tags") or []) if str(t).strip()]
    data["tags"] = ", ".join(tags[:15])
    write_json(os.path.join(project, "publish.json"), data)
    final = os.path.join(project, "final.mp4")
    if os.path.exists(final):
        subprocess.run(FF + ["-ss", "1", "-i", final, "-frames:v", "1", "-q:v", "2",
                             os.path.join(project, "thumbnail.jpg")], check=False)
    log(f"Title: {data['title']}\nTags: {data['tags']}\n\n{data['description']}")
    return data


def schedule_time(text):
    """'2026-12-01 09:30' (your local time) or an ISO time -> RFC 3339 UTC, or '' when empty."""
    text = (text or "").strip()
    if not text:
        return ""
    try:
        when = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        fail("Schedule time must look like 2026-12-01 09:30")
    if when.tzinfo is None:
        when = when.astimezone()                 # treat as this PC's local time
    if when <= datetime.datetime.now(datetime.timezone.utc):
        fail("The schedule time is in the past.")
    return when.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def request_body(data):
    """The YouTube videos.insert body for these publish settings (validated)."""
    title = data["title"].strip()
    if not title:
        fail("Add a title first.")
    if len(title) > 100:
        fail("The title is over YouTube's 100-character limit.")
    privacy = (data.get("privacy") or "private").lower()
    if privacy not in ("private", "unlisted", "public"):
        fail(f"Unknown privacy setting '{privacy}'.")
    status = {"privacyStatus": privacy, "selfDeclaredMadeForKids": False}
    at = schedule_time(data.get("publish_at"))
    if at:
        if privacy != "private":
            fail("A scheduled video must be set to private; YouTube makes it public at the scheduled time.")
        status["publishAt"] = at
    tags = [t.strip() for t in str(data.get("tags") or "").split(",") if t.strip()]
    return {"snippet": {"title": title, "description": data.get("description", ""), "tags": tags, "categoryId": "22"},
            "status": status}


def upload(project, service, media):
    """Send final.mp4 with the publish settings. `service` is a YouTube API client, `media` the upload object."""
    data = load(project)
    body = request_body(data)
    log(f"Uploading '{body['snippet']['title']}' as {body['status']['privacyStatus']}"
        + (f", scheduled for {body['status']['publishAt']}" if "publishAt" in body["status"] else "") + "...")
    request = service.videos().insert(part="snippet,status", body=body, media_body=media)
    response = None
    while response is None:
        progress, response = request.next_chunk()
        if progress:
            log(f"  {int(progress.progress() * 100)}%")
    data["video_id"] = response["id"]
    data["url"] = f"https://youtu.be/{response['id']}"
    data["uploaded"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    write_json(os.path.join(project, "publish.json"), data)
    log(f"UPLOADED: {data['url']}")
    return data


def youtube_service(workspace, secrets=None, token=None):
    """Sign in (a browser window opens the first time) and return a YouTube API client.

    The Google sign-in file and the remembered sign-in are kept encrypted in <profile>\\secrets (Windows DPAPI).
    --secrets / --token point at plain files instead (advanced use)."""
    import json

    import secretstore
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build

    secretstore.migrate(workspace)
    creds = None
    saved = read_text(token) if token and os.path.exists(token) else (None if token else secretstore.load("youtube_token", workspace))
    if saved:
        creds = Credentials.from_authorized_user_info(json.loads(saved), SCOPES)
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            client = read_text(secrets) if secrets and os.path.exists(secrets) else secretstore.load("youtube_client", workspace)
            if not client:
                fail("YouTube sign-in file not found. In Settings (or the setup wizard) press 'YouTube sign-in file...' "
                     "and choose the client_secret JSON from your Google Cloud project.")
            log("Opening your browser to sign in to YouTube...")
            creds = InstalledAppFlow.from_client_config(json.loads(client), SCOPES).run_local_server(port=0)
        if token:
            with open(token, "w", encoding="utf-8") as f:
                f.write(creds.to_json())
        else:
            secretstore.save("youtube_token", creds.to_json(), workspace)
    return build("youtube", "v3", credentials=creds)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["pack", "upload", "login"])
    ap.add_argument("--project", required=True)
    ap.add_argument("--model", default="gemma3:4b")
    ap.add_argument("--secrets", help="Google OAuth client_secret JSON (desktop app)")
    ap.add_argument("--token", help="Where the sign-in is remembered")
    a = ap.parse_args()
    project = os.path.abspath(a.project)
    if a.action == "pack":
        pack(project, a.model)
        return
    if a.action == "login":                 # Settings tab: sign in once, without uploading anything
        workspace = os.path.dirname(os.path.dirname(project)) if os.path.basename(os.path.dirname(project)) == "projects" else project
        youtube_service(workspace, a.secrets, a.token)
        log("YOUTUBE: signed in")
        return
    final = os.path.join(project, "final.mp4")
    if not os.path.exists(final):
        fail("This project has no finished video yet.")
    request_body(load(project))                       # check the settings before asking anyone to sign in
    workspace = os.path.dirname(os.path.dirname(project))
    from googleapiclient.http import MediaFileUpload
    upload(project, youtube_service(workspace, a.secrets, a.token), MediaFileUpload(final, chunksize=8 * 1024 * 1024, resumable=True))


if __name__ == "__main__":
    main()

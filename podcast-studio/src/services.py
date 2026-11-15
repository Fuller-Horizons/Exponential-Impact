"""Optional outside services, switched on per project. Everything in Podcast Studio works with all of them off.

  python services.py show   --project P                       the switches in force for P (defaults + overrides)
  python services.py set    --project P --on vidiq --off higgsfield [--cap-vidiq 100] [--default]
  python services.py block  --project P [--editor claude|codex] the rules added to every AI-agent prompt for P
  python services.py task   --project P --kind ideas|package|music|broll|dub [--scene 3] [--language spa]
                                                               write a cost-capped task prompt for Claude Code
  python services.py drive  --project P                       copy the finished files into the Drive folder

Higgsfield and vidIQ are connectors on the user's Claude account, so only Claude (Code) can use them; this app
never calls them itself. Google Drive is used through the Google Drive for desktop folder on this PC.
Switched-off services are named in every prompt as not allowed.
"""
import argparse
import datetime
import os
import re
import shutil
import sys

from common import fail, log, read_json, read_text, studio_root, write_json, write_text

SERVICES = {
    "higgsfield": {"name": "Higgsfield", "paid": True, "cap": 200,
                   "what": "generated B-roll video and images, upscaling, reframing, dubbing, virality score"},
    "vidiq": {"name": "vidIQ", "paid": True, "cap": 100,
              "what": "topic ideas, keyword research, title scores, thumbnails, music, chapters, stock B-roll"},
    "drive": {"name": "Google Drive", "paid": False, "cap": 0,
              "what": "copy finished videos, thumbnails and posts into a Google Drive folder synced to this PC"},
}
TASKS = {"ideas": "vidiq", "package": "vidiq", "music": "vidiq", "broll": "higgsfield", "dub": "higgsfield"}
DUB_LANGUAGES = {"eng": "English", "spa": "Spanish", "por": "Portuguese", "fra": "French", "deu": "German",
                 "ita": "Italian", "hin": "Hindi", "jpn": "Japanese", "kor": "Korean", "cmn": "Chinese",
                 "ara": "Arabic", "rus": "Russian", "tur": "Turkish", "pol": "Polish", "ind": "Indonesian",
                 "fil": "Filipino", "swe": "Swedish", "fin": "Finnish"}
APP = os.path.dirname(os.path.abspath(__file__))


def workspace():
    return os.path.join(studio_root(), "workspace")


def defaults():
    """Everything off, with conservative credit caps."""
    return {"services": {k: False for k in SERVICES}, "caps": {k: v["cap"] for k, v in SERVICES.items() if v["paid"]},
            "drive_folder": ""}


def _merge(base, extra):
    if not isinstance(extra, dict):
        return base
    for key in ("services", "caps"):
        for k, v in (extra.get(key) or {}).items():
            if k in base[key]:
                base[key][k] = bool(v) if key == "services" else max(0, int(v))
    if isinstance(extra.get("drive_folder"), str) and extra["drive_folder"].strip():
        base["drive_folder"] = extra["drive_folder"].strip()
    return base


def load(project=None):
    """Settings in force: all-off defaults, then workspace/settings.json "services", then <project>/services.json."""
    cfg = _merge(defaults(), (read_json(os.path.join(workspace(), "settings.json"), {}) or {}).get("services_default"))
    if project:
        cfg = _merge(cfg, read_json(os.path.join(project, "services.json"), {}))
    return cfg


def save(project, cfg, as_default=False):
    data = {"services": cfg["services"], "caps": cfg["caps"], "drive_folder": cfg["drive_folder"]}
    if as_default:
        path = os.path.join(workspace(), "settings.json")
        settings = read_json(path, {}) or {}
        settings["services_default"] = data
        os.makedirs(os.path.dirname(path), exist_ok=True)
        write_json(path, settings)
    if project:
        write_json(os.path.join(project, "services.json"), data)


def spent(project):
    """Credits already logged for this project, per service, from services-log.md."""
    totals = {k: 0 for k, v in SERVICES.items() if v["paid"]}
    path = os.path.join(project, "services-log.md")
    if not os.path.exists(path):
        return totals
    for line in read_text(path).splitlines():
        m = re.match(r"\s*-\s.*?\b(higgsfield|vidiq)\b.*?(\d+(?:\.\d+)?)\s*credits?", line, re.I)
        if m:
            totals[m.group(1).lower()] += round(float(m.group(2)))
    return totals


def block(project, editor="claude"):
    """The service rules added to every AI-agent prompt for this project."""
    cfg, used = load(project), spent(project)
    log_path = os.path.join(project, "services-log.md")
    lines = ["", "Outside services for this project (set in Podcast Studio's Services tab):"]
    for key, info in SERVICES.items():
        on = cfg["services"][key]
        if key == "drive":
            lines.append(f"- {info['name']}: {'on' if on else 'off'} (Podcast Studio copies files itself; you do not need it).")
            continue
        if not on:
            lines.append(f"- {info['name']}: OFF. Do not use any {info['name']} tool for this project.")
        elif editor == "codex":
            lines.append(f"- {info['name']}: on, but its tools are only connected to Claude, not Codex. Do not try to use it.")
        else:
            cap = cfg["caps"][key]
            lines.append(f"- {info['name']}: allowed, up to {cap} credits for this project ({used[key]} already used). "
                         f"Use it only where it clearly improves the result.")
    if any(cfg["services"][k] for k in ("higgsfield", "vidiq")) and editor != "codex":
        lines += [
            "- Before every paid call, check its cost (Higgsfield: get_cost; vidIQ: the cost in the tool's description), "
            "tell me, and wait for my yes. Never go over the project's cap.",
            f"- After every paid call, add one line to {log_path}: \"- <date> <service> <tool>: <N> credits - <what for>\".",
            "- If a service fails, is out of credits or I say no, carry on without it. Nothing in this project requires it.",
            "- Uploading footage to a service sends it to that company. Only do it for the task I asked for.",
        ]
    return "\n".join(lines) + "\n"


def _require(project, service):
    cfg = load(project)
    if not cfg["services"].get(service):
        fail(f"{SERVICES[service]['name']} is off for this project. Turn it on in the Services tab first.")
    return cfg


def task(project, kind, scene=None, language=None):
    """Write the prompt for one optional, cost-capped task and return its path."""
    if kind not in TASKS:
        fail(f"Unknown task '{kind}'.")
    service = TASKS[kind]
    cfg = _require(project, service)
    cap, used = cfg["caps"][service], spent(project)[service]
    if used >= cap:
        fail(f"This project has used {used} of its {cap} {SERVICES[service]['name']} credits. Raise the cap to continue.")
    name = os.path.basename(project.rstrip("/\\"))
    pcfg = read_json(os.path.join(project, "project.json"), {}) or {}
    fmt = pcfg.get("format", "9:16")
    short = fmt == "9:16"
    py, app = f'"{sys.executable}"', APP
    lines = [f"Podcast Studio task for the project folder {project} (project \"{name}\").", ""]
    if kind == "ideas":
        topic = read_text(os.path.join(project, "prompt.txt")).strip() if os.path.exists(os.path.join(project, "prompt.txt")) else ""
        if not topic:
            fail("Type the video's topic in the Create tab first.")
        lines += [f"Topic: {topic}", "",
                  "Use vidIQ to find what is working for this topic right now:",
                  "1. vidiq_keyword_research (mode research) on the topic's core phrase.",
                  f"2. vidiq_outliers with that keyword, contentType \"{'short' if short else 'long'}\".",
                  f"3. Write {os.path.join(project, 'ideas.md')}: five angles for this video, each with a working title, a "
                  "first line the host could say, the keywords it targets, and the outlier videos that suggest it works "
                  "(title, channel, views, link).",
                  "Do not change the outline or anything else. I will choose an angle in Podcast Studio."]
    elif kind == "package":
        if not os.path.exists(os.path.join(project, "final.mp4")):
            fail("Make the video first: packaging needs the finished video.")
        lines += [f"Read {os.path.join(project, 'script.txt')} and {os.path.join(project, 'publish.json')} if it exists.",
                  "1. Write five title options in the show's voice (house rules and style bible in the workspace apply).",
                  f"2. Score each with vidiq_score_title, type \"{'short' if short else 'long'}\".",
                  f"3. Make one thumbnail with vidiq_generate_thumbnail, orientation \"{'portrait' if short else 'landscape'}\", "
                  "using the best title and the script as the transcript. Download its imageUrl to "
                  f"{os.path.join(project, 'thumbnail_vidiq.png')}.",
                  f"4. Write {os.path.join(project, 'packaging.md')} with the titles, their scores and the thumbnail path.",
                  f"5. Ask me before putting the chosen title into {os.path.join(project, 'publish.json')} (keep every other field)."]
    elif kind == "music":
        bible = os.path.join(workspace(), "style-bible.md")
        music_dir = os.path.join(workspace(), "music")
        lines += [f"Make an instrumental music bed for this show with vidIQ's music generation tool. Read {bible} if it "
                  "exists for the mood. It plays quietly under speech, so: no vocals, steady, not busy, about 60-90 seconds.",
                  f"Download it into {music_dir} with a short descriptive file name.",
                  f"Then ask me before setting it as \"music\" in {os.path.join(workspace(), 'brand.json')} (keep every other field)."]
    elif kind == "broll":
        script = read_json(os.path.join(project, "script.json"), {}) or {}
        scenes = script.get("scenes") or []
        if not scene or not 1 <= scene <= len(scenes):
            fail(f"Choose a scene number between 1 and {len(scenes) or '?'} in the Scenes tab.")
        s = scenes[scene - 1]
        if s.get("visual") == "soundbite":
            fail("That scene is a soundbite (the hosts on camera). Choose a narrated scene.")
        wav = os.path.join(project, "voice", f"scene_{scene:02}.wav")
        clip = os.path.join(project, "generated", f"scene_{scene:02}.mp4")
        fields = os.path.join(project, "generated", f"scene_{scene:02}.json")
        lines += [f"Make generated B-roll for scene {scene}.",
                  f"- Narration: {s.get('narration', '')}",
                  f"- Picture idea: {s.get('image_prompt') or s.get('query') or s.get('narration', '')}",
                  f"- Length: at least the voice line {wav} (measure it with ffprobe), aspect ratio {fmt}.",
                  "1. Choose a suitable Higgsfield video model (models_explore) and check the cost with get_cost first.",
                  "2. After I agree, generate it with generate_video. No text, logos or real people's likenesses in the picture.",
                  f"3. Download the finished video to {clip}.",
                  f"4. Write {fields} containing {{\"clip\": \"{clip.replace(os.sep, '/')}\"}} and run:",
                  f"   {py} \"{os.path.join(app, 'scenes.py')}\" set --project \"{project}\" --index {scene} --fields-file \"{fields}\"",
                  f"   {py} \"{os.path.join(app, 'pipeline.py')}\" --project \"{project}\" --stage all",
                  "Do not change any other scene."]
    elif kind == "dub":
        if language not in DUB_LANGUAGES:
            fail("Choose a dubbing language.")
        final = os.path.join(project, "final.mp4")
        if not os.path.exists(final):
            fail("Make the video first: dubbing needs the finished video.")
        out = os.path.join(project, f"final.{language}.mp4")
        lines += [f"Dub {final} into {DUB_LANGUAGES[language]} with Higgsfield.",
                  "1. Upload it (media_upload, then the upload, then media_confirm). Tell me the cost before dubbing.",
                  f"2. After I agree, run dubbing with target_language \"{language}\".",
                  f"3. Download the result to {out}. Do not replace final.mp4.",
                  "Only do this if everyone whose voice is in the video has agreed to be dubbed."]
    lines.append(block(project))
    path = os.path.join(project, "tasks", f"{kind}.txt")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    write_text(path, "\n".join(lines))
    return path


def drive_copy(project):
    """Copy finished files into <Drive folder>/<project name>/ (a Google Drive for desktop folder). Local only."""
    cfg = _require(project, "drive")
    root = cfg["drive_folder"]
    if not root or not os.path.isdir(root):
        fail("Choose your Google Drive folder in the Services tab first (a folder Google Drive for desktop syncs).")
    name = os.path.basename(project.rstrip("/\\"))
    dest = os.path.join(root, name)
    os.makedirs(dest, exist_ok=True)
    copied = []
    for item in ("final.mp4", "thumbnail.jpg", "thumbnail_vidiq.png", "publish.json", "packaging.md", "ideas.md", "qa.json"):
        src = os.path.join(project, item)
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(dest, item))
            copied.append(item)
    for extra in sorted(os.listdir(project)):
        if re.match(r"final\.[a-z]{3}\.mp4$", extra):
            shutil.copy2(os.path.join(project, extra), os.path.join(dest, extra))
            copied.append(extra)
    social = os.path.join(project, "social")
    if os.path.isdir(social):
        shutil.copytree(social, os.path.join(dest, "social"), dirs_exist_ok=True)
        copied.append("social/")
    if not copied:
        fail("Nothing to copy yet: make the video first.")
    with open(os.path.join(project, "services-log.md"), "a", encoding="utf-8") as f:
        f.write(f"- {datetime.date.today()} drive copy: 0 credits - {', '.join(copied)} to {dest}\n")
    log(f"Copied {len(copied)} item(s) to {dest}")
    log(f"DRIVE: {dest}")
    return dest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["show", "json", "set", "block", "task", "drive"])
    ap.add_argument("--project", required=True)
    ap.add_argument("--on", nargs="*", default=[])
    ap.add_argument("--off", nargs="*", default=[])
    ap.add_argument("--cap-higgsfield", type=int)
    ap.add_argument("--cap-vidiq", type=int)
    ap.add_argument("--drive-folder")
    ap.add_argument("--default", action="store_true", help="Also save as the default for new projects")
    ap.add_argument("--editor", default="claude", choices=["claude", "codex"])
    ap.add_argument("--kind")
    ap.add_argument("--scene", type=int)
    ap.add_argument("--language")
    a = ap.parse_args()
    project = os.path.abspath(a.project)
    if a.action == "show":
        cfg, used = load(project), spent(project)
        for k, info in SERVICES.items():
            extra = f", cap {cfg['caps'][k]}, used {used[k]}" if info["paid"] else f", folder {cfg['drive_folder'] or '-'}"
            log(f"{info['name']}: {'on' if cfg['services'][k] else 'off'}{extra}")
    elif a.action == "json":
        import json
        print(json.dumps(dict(load(project), spent=spent(project))))
    elif a.action == "set":
        cfg = load(project)
        for k in a.on + a.off:
            if k not in SERVICES:
                fail(f"Unknown service '{k}'. Use: {', '.join(SERVICES)}")
        for k in a.on:
            cfg["services"][k] = True
        for k in a.off:
            cfg["services"][k] = False
        for k in ("higgsfield", "vidiq"):
            v = getattr(a, f"cap_{k}")
            if v is not None:
                cfg["caps"][k] = max(0, v)
        if a.drive_folder is not None:
            cfg["drive_folder"] = a.drive_folder.strip()
        os.makedirs(project, exist_ok=True)
        save(project, cfg, a.default)
        log("Saved." + (" Also the default for new projects." if a.default else ""))
    elif a.action == "block":
        print(block(project, a.editor), end="")
    elif a.action == "task":
        log(f"TASK: {task(project, a.kind, a.scene, a.language)}")
    else:
        drive_copy(project)


if __name__ == "__main__":
    main()

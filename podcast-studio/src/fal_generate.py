"""Run any fal.ai model (Wan image-to-video, Wan-Animate, LatentSync lip-sync...) and download the video.

Local files are uploaded automatically. Needs the FAL_KEY environment variable.
"""
import argparse
import json
import os
import urllib.request

from common import fail, log


def find_video_url(obj):
    if isinstance(obj, dict):
        for k in ("video", "output", "result"):
            if k in obj:
                u = find_video_url(obj[k])
                if u:
                    return u
        if isinstance(obj.get("url"), str):
            return obj["url"]
        for v in obj.values():
            u = find_video_url(v)
            if u:
                return u
    elif isinstance(obj, list):
        for v in obj:
            u = find_video_url(v)
            if u:
                return u
    elif isinstance(obj, str) and obj.startswith("http") and obj.split("?")[0].lower().endswith((".mp4", ".webm", ".mov")):
        return obj
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", required=True, help="e.g. fal-ai/latentsync")
    ap.add_argument("--prompt")
    ap.add_argument("--image", help="Reference image (file or URL) -> image_url")
    ap.add_argument("--video", help="Video (file or URL) -> video_url")
    ap.add_argument("--audio", help="Audio (file or URL) -> audio_url")
    ap.add_argument("--extra", default="{}", help="Extra JSON arguments for the model")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    if not os.environ.get("FAL_KEY"):
        fail("FAL_KEY is not set. Use Settings > fal.ai key in the app.")
    import fal_client

    args = {}
    if a.prompt:
        args["prompt"] = a.prompt
    for key, val in (("image_url", a.image), ("video_url", a.video), ("audio_url", a.audio)):
        if not val:
            continue
        if val.startswith("http"):
            args[key] = val
        else:
            if not os.path.exists(val):
                fail(f"File not found: {val}")
            log(f"Uploading {os.path.basename(val)}...")
            args[key] = fal_client.upload_file(val)
    try:
        args.update(json.loads(a.extra or "{}"))
    except json.JSONDecodeError as e:
        fail(f"Extra JSON is invalid: {e}")

    def on_update(update):
        if isinstance(update, fal_client.InProgress):
            for entry in update.logs or []:
                log("  " + str(entry.get("message", entry)))
        else:
            log(f"  status: {type(update).__name__}")

    log(f"Submitting to {a.endpoint} with keys: {', '.join(args)}")
    result = fal_client.subscribe(a.endpoint, arguments=args, with_logs=True, on_queue_update=on_update)

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(os.path.splitext(a.out)[0] + ".json", "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2)
    url = find_video_url(result)
    if not url:
        fail("No video URL in result - see the .json next to the output.")
    log(f"Downloading {url}")
    urllib.request.urlretrieve(url, a.out)
    log(f"Saved clip: {a.out}")


if __name__ == "__main__":
    main()

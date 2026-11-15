"""Download your own YouTube videos into the episode folder and add them to the footage index.

  python ytimport.py --url <video, playlist or channel link> --dest <workspace>/episodes --lib <workspace>/library [--max 5]

Only use this for videos you own or have permission to reuse.
"""
import argparse
import os
import shutil
import subprocess

from common import ensure_dir, fail, log


def command(url, dest, limit):
    """The yt-dlp command: best MP4 up to 1080p, skipping anything already downloaded."""
    return ["yt-dlp", "--no-warnings", "--ignore-errors", "--playlist-end", str(limit),
            "-f", "bv*[height<=1080][ext=mp4]+ba[ext=m4a]/b[height<=1080][ext=mp4]/b[height<=1080]/b",
            "--merge-output-format", "mp4", "--restrict-filenames",
            "--download-archive", os.path.join(dest, "downloaded.txt"),
            "-o", os.path.join(dest, "%(upload_date)s-%(title).80s-%(id)s.%(ext)s"), url]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--dest", required=True)
    ap.add_argument("--lib", required=True)
    ap.add_argument("--max", type=int, default=5, dest="limit", help="Most videos to take from a playlist or channel")
    ap.add_argument("--no-index", action="store_true")
    a = ap.parse_args()
    if not a.url.lower().startswith("http"):
        fail("Paste a full YouTube link.")
    if not shutil.which("yt-dlp"):
        fail("yt-dlp is not installed. Re-run Setup-PodcastStudio.ps1.")
    dest = ensure_dir(os.path.abspath(a.dest))
    before = {f for f in os.listdir(dest) if f.lower().endswith(".mp4")}
    log(f"Downloading up to {a.limit} video(s) into {dest} ...")
    subprocess.run(command(a.url, dest, max(1, a.limit)))
    new = sorted({f for f in os.listdir(dest) if f.lower().endswith(".mp4")} - before)
    if not new and not before:
        fail("Nothing was downloaded. Check the link, and that the video is public or unlisted.")
    log(f"{len(new)} new video(s): " + (", ".join(new) if new else "none (already downloaded)"))
    if not a.no_index:
        import library
        library.index(dest, os.path.abspath(a.lib))
    log(f"EPISODES: {dest}")


if __name__ == "__main__":
    main()

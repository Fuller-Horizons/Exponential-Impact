"""Cut a clean reference voice sample (and its transcript) from a YouTube URL or local file."""
import argparse
import glob
import hashlib
import os

from common import ensure_dir, fail, log, run, transcribe


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", help="YouTube URL or local audio/video file")
    ap.add_argument("--start", default="0", help="Start time (SS, MM:SS or HH:MM:SS)")
    ap.add_argument("--duration", type=float, default=12, help="Seconds (3-20 works best)")
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--name", default="ref")
    a = ap.parse_args()

    out = ensure_dir(a.outdir)
    src = a.source
    if src.lower().startswith("http"):
        cache = ensure_dir(os.path.join(out, "_downloads"))
        key = hashlib.sha1(src.encode()).hexdigest()[:10]
        hits = glob.glob(os.path.join(cache, key + ".*"))
        if hits:
            src = hits[0]
            log(f"Using cached download {src}")
        else:
            run(["yt-dlp", "-f", "bestaudio/best", "-x", "--audio-format", "wav",
                 "-o", os.path.join(cache, key + ".%(ext)s"), a.source])
            hits = glob.glob(os.path.join(cache, key + ".*"))
            if not hits:
                fail("yt-dlp produced no file")
            src = hits[0]
    elif not os.path.exists(src):
        fail(f"File not found: {src}")

    wav = os.path.join(out, a.name + ".wav")
    # 24 kHz mono, light denoise + loudness normalisation for cloning
    run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-ss", a.start, "-t", str(a.duration),
         "-i", src, "-ac", "1", "-ar", "24000",
         "-af", "highpass=f=70,afftdn=nf=-25,loudnorm=I=-18:TP=-2", wav])

    segs = transcribe(wav)
    text = " ".join(t for _, _, t in segs).strip()
    with open(os.path.join(out, a.name + ".txt"), "w", encoding="utf-8") as f:
        f.write(text)
    log(f"Reference audio: {wav}")
    log(f"Reference text : {text}")


if __name__ == "__main__":
    main()

"""Transcribe a video/audio file to .srt and .txt with faster-whisper."""
import argparse
import os

from common import log, transcribe, write_srt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("--out", help="Output base path (no extension)")
    ap.add_argument("--model", default="small", help="tiny/base/small/medium")
    ap.add_argument("--max-words", type=int, default=7)
    a = ap.parse_args()

    base = a.out or os.path.splitext(a.source)[0]
    segs = transcribe(a.source, a.model)
    write_srt(segs, base + ".srt", a.max_words)
    with open(base + ".txt", "w", encoding="utf-8") as f:
        for s, _, t in segs:
            f.write(f"[{int(s // 60):02}:{int(s % 60):02}] {t}\n")
    log(f"Saved {base}.srt and {base}.txt")


if __name__ == "__main__":
    main()

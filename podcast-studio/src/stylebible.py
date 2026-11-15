"""Build style-bible.md on this PC from the indexed episodes: transcripts + measured pacing, written by the local model.

  python stylebible.py --lib <workspace>/library --out <workspace>/style-bible.md [--model gemma3:4b]
"""
import argparse
import os
import re
import subprocess

from common import duration, fail, log, read_json, write_text


def cut_rate(video, seconds=180):
    """Scene cuts per minute over the first few minutes (ffmpeg scene detection)."""
    span = min(seconds, duration(video))
    if span < 5:
        return None
    out = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-t", str(span), "-i", video, "-an",
                          "-vf", "scale=320:-2,select='gt(scene,0.30)',showinfo", "-f", "null", "-"],
                         capture_output=True, text=True)
    return len(re.findall(r"pts_time:", out.stderr)) / (span / 60.0)


def measure(index):
    files = [f for f in index["files"] if os.path.exists(f)]
    lengths = [duration(f) for f in files]
    words = secs = 0.0
    for c in index["chunks"]:
        for a, b, t in c.get("segs") or [[c["start"], c["end"], c["text"]]]:
            words += len(t.split())
            secs += max(0.0, b - a)
    cuts = [r for r in (cut_rate(f) for f in sorted(files, key=duration)[:4]) if r is not None]
    shorts = [x for x in lengths if x <= 180]
    return {
        "videos": len(files),
        "short_videos": len(shorts),
        "typical_short_seconds": round(sorted(shorts)[len(shorts) // 2]) if shorts else None,
        "speaking_words_per_second": round(words / secs, 2) if secs else None,
        "cuts_per_minute": round(sum(cuts) / len(cuts), 1) if cuts else None,
    }


def sample_text(index, budget=7000):
    """Evenly spaced transcript excerpts, plus the opening lines of each video (the hooks)."""
    by_file = {}
    for c in index["chunks"]:
        by_file.setdefault(c["file"], []).append(c)
    hooks = [f"- {os.path.basename(f)}: {cs[0]['text'][:220]}" for f, cs in list(by_file.items())[:25]]
    chunks = index["chunks"]
    step = max(1, len(chunks) // 20)
    body = [c["text"] for c in chunks[::step]]
    text = "OPENING LINES:\n" + "\n".join(hooks) + "\n\nEXCERPTS:\n" + "\n---\n".join(body)
    return text[:budget]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--model", default="gemma3:4b")
    a = ap.parse_args()

    index = read_json(os.path.join(a.lib, "index.json"))
    if not index or not index.get("chunks"):
        fail("No footage library yet. Use 'Index footage' in the Create tab first.")
    log("Measuring pacing (cut rate, speaking speed, lengths)...")
    stats = measure(index)
    log(f"  {stats}")

    import llm
    system = ("You are a video producer writing a style guide for a podcast's short videos. "
              "Base every statement on the transcript excerpts and measurements given. "
              "If something cannot be known from them, say 'not observed'. Plain markdown.")
    user = (f"MEASUREMENTS:\n{stats}\n\n{sample_text(index)}\n\n"
            "Write the style guide with exactly these sections:\n"
            "## Voice and tone\n## Recurring topics\n## Hook patterns (with 8 example hooks in this voice)\n"
            "## Pacing and length\n## Vocabulary and phrases to use\n## Things to avoid\n## Call-to-action style")
    text = llm.chat(system, user, a.model, temperature=0.4)
    header = ("# Style bible\n\n_Built locally from the indexed episodes._\n\n## Measured\n"
              + "\n".join(f"- {k.replace('_', ' ')}: {v}" for k, v in stats.items() if v is not None) + "\n\n")
    write_text(a.out, header + text.strip() + "\n")
    log(f"Saved {a.out}")


if __name__ == "__main__":
    main()

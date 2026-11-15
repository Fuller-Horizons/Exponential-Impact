"""Find the best moments in an episode and cut them into finished short videos. No narration: the hosts' own words.

  python highlights.py --lib <workspace>/library --episode <video file> --out <workspace>/highlights
                       [--count 5 --min 20 --max 45 --format 9:16 --framing speaker --model gemma3:4b]

The episode must be in the footage index (Create tab > Index footage). For each clip it writes clip_NN.mp4
and lists them, best first, in highlights.json.
"""
import argparse
import os
import re
import subprocess
import sys
import time

from common import FORMATS, duration, ensure_dir, fail, log, read_json, write_json

BATCH = 8
MAX_CANDIDATES = 64
SCHEMA = {"type": "object", "required": ["ratings"], "properties": {"ratings": {"type": "array", "items": {
    "type": "object", "required": ["id", "score", "title"],
    "properties": {"id": {"type": "integer"}, "score": {"type": "integer"}, "title": {"type": "string"}}}}}}


def passages(chunks, min_s=20.0, max_s=45.0):
    """Candidate passages built from whole transcript sentences: [{"start", "end", "text", "words"}]."""
    segs, words = [], []
    for c in sorted(chunks, key=lambda c: c["start"]):
        segs += c.get("segs") or [[c["start"], c["end"], c["text"]]]
        words += c.get("words") or []
    out, step = [], max(1, len(segs) // 200 + 1)
    for i in range(0, len(segs), step):
        start, end, text = segs[i][0], segs[i][1], [segs[i][2]]
        for seg in segs[i + 1:]:
            if seg[1] - start > max_s or (seg[0] - end) > 3.0:     # too long, or a long pause
                break
            end = seg[1]
            text.append(seg[2])
            if end - start >= (min_s + max_s) / 2 and re.search(r"[.!?]$", seg[2].strip()):
                break                                              # stop at a sentence end once long enough
        if end - start >= min_s:
            out.append({"start": round(start, 2), "end": round(end, 2), "text": " ".join(text),
                        "words": [w for w in words if w[0] >= start - 0.05 and w[1] <= end + 0.05]})
    if len(out) > MAX_CANDIDATES:                                  # keep the model's workload bounded
        keep = [round(k * (len(out) - 1) / (MAX_CANDIDATES - 1)) for k in range(MAX_CANDIDATES)]
        out = [out[k] for k in sorted(set(keep))]
    return out


def rate(cands, model, bible=""):
    """Ask the local model to score each passage 0-100 and give it a headline. Adds "score" and "title"."""
    import llm

    system = ("You pick moments from a podcast that work as standalone short videos. Reply with JSON only."
              + (f"\n\nSHOW STYLE GUIDE:\n{bible[:3000]}" if bible else ""))
    for at in range(0, len(cands), BATCH):
        batch = cands[at:at + BATCH]
        listing = "\n\n".join(f"[{at + k}] {c['text'][:900]}" for k, c in enumerate(batch))
        user = ("Rate each passage from 0 to 100 as a standalone short video. High scores need: a strong first "
                "sentence, one clear point, a story, surprise or strong opinion, and no missing context. "
                "Rambling, greetings and housekeeping score low. Give each a headline of at most 7 words.\n\n"
                f"{listing}\n\nReturn JSON: {{\"ratings\": [{{\"id\": <number in brackets>, \"score\": 0-100, \"title\": str}}]}}")
        try:
            got = llm.chat(system, user, model, schema=SCHEMA, temperature=0.2).get("ratings") or []
        except Exception as e:  # noqa: BLE001 - one bad batch should not stop the run
            log(f"  rating failed for passages {at}-{at + len(batch) - 1} ({e})")
            got = []
        for r in got:
            try:
                i = int(r["id"])
                if at <= i < at + len(batch):
                    cands[i]["score"] = max(0, min(100, int(r["score"])))
                    cands[i]["title"] = " ".join(str(r.get("title") or "").split())[:60]
            except (KeyError, TypeError, ValueError):
                continue
        log(f"  rated {min(at + BATCH, len(cands))}/{len(cands)} passages")
    for c in cands:
        c.setdefault("score", 0)
        c.setdefault("title", "")
    return cands


def choose(cands, count):
    """The top `count` passages that do not overlap each other by more than a fifth."""
    picked = []
    for c in sorted(cands, key=lambda c: -c["score"]):
        clash = any(min(c["end"], p["end"]) - max(c["start"], p["start"]) > 0.2 * (c["end"] - c["start"]) for p in picked)
        if not clash:
            picked.append(c)
        if len(picked) == count:
            break
    return picked


def render(episode, clip, out_mp4, fmt, framing, kit, title=True):
    """One finished clip: framed footage with its own sound, word captions, headline, logo, loudness."""
    import brand
    import subs
    import visuals

    W, H = FORMATS[fmt]
    start, secs = max(0.0, clip["start"] - 0.15), clip["end"] - clip["start"] + 0.35
    raw = os.path.splitext(out_mp4)[0] + ".raw.mp4"
    used = visuals.footage_clip(episode, start, raw, secs, fmt, audio=True, choice=framing)
    real = duration(raw)
    if clip["words"]:
        words = [(w, a - start, min(b - start, real)) for a, b, w in clip["words"] if a - start < real]
    else:
        words = subs.word_times(clip["text"], 0.15, max(0.5, real - 0.2))
    ass = os.path.splitext(out_mp4)[0] + ".ass"
    subs.build_ass(words, W, H, ass, font=brand.caption_font(kit), highlight=brand.ass_colour(kit["caption_highlight"]),
                   uppercase=bool(kit["caption_uppercase"]),
                   title=(clip["title"], min(3.5, real)) if title and clip.get("title") else None)
    cmd = [sys.executable, "-u", os.path.join(os.path.dirname(os.path.abspath(__file__)), "assemble.py"),
           "--clips", raw, "--format", fmt, "--ass", ass, "--out", out_mp4]
    if kit["logo"] and os.path.exists(kit["logo"]):
        cmd += ["--logo", kit["logo"], "--logo-position", kit["logo_position"]]
    subprocess.run(cmd, check=True, capture_output=True)
    os.remove(raw)
    return used


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True)
    ap.add_argument("--episode", required=True, help="An indexed episode video file")
    ap.add_argument("--out", required=True, help="Folder for the clips (a sub-folder per episode is made)")
    ap.add_argument("--count", type=int, default=5)
    ap.add_argument("--min", type=float, default=20, dest="min_s")
    ap.add_argument("--max", type=float, default=45, dest="max_s")
    ap.add_argument("--format", default="9:16", choices=list(FORMATS))
    ap.add_argument("--framing", default="speaker")
    ap.add_argument("--model", default="gemma3:4b")
    ap.add_argument("--no-title", action="store_true", help="Do not show the headline at the top of each clip")
    a = ap.parse_args()

    import brand
    index = read_json(os.path.join(a.lib, "index.json"), {"chunks": []})
    episode = os.path.abspath(a.episode)
    chunks = [c for c in index["chunks"] if os.path.abspath(c["file"]) == episode]
    if not chunks:
        fail("That episode is not in the footage index yet. Use 'Index footage' in the Create tab first.")
    if a.min_s >= a.max_s:
        fail("The shortest length must be below the longest length.")
    t0 = time.time()
    cands = passages(chunks, a.min_s, a.max_s)
    if not cands:
        fail("No passage of that length was found in this episode. Try a shorter minimum length.")
    log(f"{len(cands)} candidate passages in {os.path.basename(episode)}; rating them with {a.model}...")
    workspace = os.path.dirname(os.path.abspath(a.lib))
    bible_path = os.path.join(workspace, "style-bible.md")
    bible = open(bible_path, encoding="utf-8-sig").read() if os.path.exists(bible_path) else ""
    picked = choose(rate(cands, a.model, bible), a.count)

    out_dir = ensure_dir(os.path.join(a.out, re.sub(r"[^\w\-]+", "-", os.path.splitext(os.path.basename(episode))[0]).strip("-")))
    kit = brand.load(os.path.join(workspace, "projects", "_"))
    report = []
    for n, clip in enumerate(picked, 1):
        out = os.path.join(out_dir, f"clip_{n:02}.mp4")
        log(f"[clip {n}/{len(picked)}] score {clip['score']}  {clip['start']:.0f}s-{clip['end']:.0f}s  {clip['title']}")
        try:
            used = render(episode, clip, out, a.format, a.framing, kit, title=not a.no_title)
        except Exception as e:  # noqa: BLE001
            log(f"  could not make this clip: {e}")
            continue
        report.append({"file": out, "score": clip["score"], "title": clip["title"], "start": clip["start"],
                       "end": clip["end"], "seconds": round(duration(out), 1), "framing": used, "text": clip["text"]})
    write_json(os.path.join(out_dir, "highlights.json"),
               {"episode": episode, "made": time.strftime("%Y-%m-%d %H:%M"), "seconds": round(time.time() - t0, 1),
                "clips": report})
    if not report:
        fail("No clips could be made.")
    log(f"Made {len(report)} clips in {out_dir}")
    log(f"HIGHLIGHTS: {out_dir}")


if __name__ == "__main__":
    main()

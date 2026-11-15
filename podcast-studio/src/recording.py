"""Edit a raw recording, the hybrid way: this PC prepares it, Claude Code edits it with the Herk Edit Kit.

  python recording.py prepare --recording take.mp4 --slug my-take [--tighten]
        copy into the kit, transcribe locally (and optionally remove pauses here), write the prompts for Claude Code
  python recording.py split   --recording long.mp4 --slug my-talk --minutes 8 [--tighten]
        cut a long recording into parts at natural pauses; each part becomes its own kit project
  python recording.py join    --slug my-talk                       join the edited parts into one video
  python recording.py tighten --recording take.mp4 --out tight.mp4  quick local silence trim, no AI
  python recording.py render  --video in.mp4 --keep keep.json --out out.mp4
        render a list of kept time ranges piece by piece (memory-safe; Claude Code is told to use this)

The Herk Edit Kit (MIT, by Nate Herk) lives in <PodcastStudio>/repos/herk-edit-kit. Its skills run inside
Claude Code, which is a cloud model: the transcript and editing decisions go to Claude; the video files stay here.

Memory: cutting many pieces out of one video with a single ffmpeg filter graph (trim/atrim + concat) keeps
decoded frames for every later piece in memory. Measured on a 10-minute 1080p file with 60 cuts it passed
13 GB and was killed. Everything here renders one piece at a time instead (under 0.5 GB).
"""
import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

from common import (FF, FORMATS, duration, ensure_dir, fail, log, read_json, studio_root, transcribe_words, venc,
                    video_size, write_json, write_text)

SLUG = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
SKILLS = {"short": "short-form-edit", "long": "edit-video"}
APP = os.path.dirname(os.path.abspath(__file__))


def kit_dir():
    return os.environ.get("PSTUDIO_KIT") or os.path.join(studio_root(), "repos", "herk-edit-kit")


def make_slug(name):
    return re.sub(r"[^a-z0-9]+", "-", os.path.splitext(os.path.basename(name))[0].lower()).strip("-") or "recording"


def kit_transcript(segments, seconds):
    """Our word-level transcript in the kit's format: {"text", "audio_duration_secs", "words": [{"text", "start", "end"}]}."""
    words = [{"text": w, "start": a, "end": b} for seg in segments for a, b, w in seg["words"]]
    return {"text": " ".join(seg["text"] for seg in segments).strip(), "audio_duration_secs": round(seconds, 3),
            "words": words}


def prompt(slug, kind, workspace, tightened=False):
    """What the app asks Claude Code to do, as plain text the user can read and change."""
    rules = os.path.join(workspace, "house-rules.md")
    brand = os.path.join(workspace, "brand.json")
    bible = os.path.join(workspace, "style-bible.md")
    render = os.path.join(APP, "recording.py")
    py = sys.executable
    if tightened:
        source = (f"- Source: video-projects/{slug}/assets/silenced.mp4 with its transcript silenced.json. Pauses were "
                  "already removed on this PC, so skip the cut-silences render and start with mistakes. raw.mp4 and "
                  "raw.json are the untouched original; keep them.\n")
    else:
        source = (f"- Source: video-projects/{slug}/assets/raw.mp4. Keep it untouched. Transcript: "
                  f"video-projects/{slug}/assets/raw.json, made on this PC in this kit's word-level format.\n")
    return (
        f"Use the {SKILLS[kind]} skill to edit the recording in video-projects/{slug}.\n\n"
        + source +
        "- Do not call ElevenLabs, Kie.ai or any other paid or cloud service, and do not upload the footage anywhere.\n"
        "- Follow the kit's order: cut silences, then mistakes, then the story and motion graphics.\n"
        "- This PC has 16 GB of memory and a 4 GB graphics card. Do not render cuts with one ffmpeg filter graph of "
        "many trim/atrim filters: it keeps frames for every later piece in memory and runs out on long recordings. "
        f"To render a list of kept ranges, write them as JSON [[start, end], ...] in seconds and run:\n"
        f"  \"{py}\" \"{render}\" render --video <input.mp4> --keep <keep.json> --out <output.mp4>\n"
        "  It renders one piece at a time and joins them. If a HyperFrames render runs out of memory, render the "
        "composition in shorter sections and join them the same way.\n"
        f"- House rules: read {rules} if it exists and follow every rule. When I give you a note about the edit, "
        "apply it and add it to that file as one short rule so the next edit follows it too.\n"
        f"- Brand: use the colours, font and logo in {brand} if it exists. Show style: {bible} if it exists.\n"
        "- Show me the planned cuts before rendering, then render the final video into this project's renders folder "
        "and tell me its path.\n")


def _kit_project(slug):
    """Create (or reuse) video-projects/<slug> inside the kit. Returns its folder."""
    kit = kit_dir()
    if not os.path.exists(os.path.join(kit, "CLAUDE.md")):
        fail(f"The Herk Edit Kit is not installed at {kit}. Re-run Setup-PodcastStudio.ps1.")
    if not SLUG.match(slug):
        fail("The project name must be lowercase letters, digits and dashes, like my-first-take.")
    project = os.path.join(kit, "video-projects", slug)
    if not os.path.exists(project):
        made = False
        if os.path.exists(os.path.join(kit, "node_modules", "gsap")):
            done = subprocess.run(["node", os.path.join("scripts", "new-video.mjs"), slug], cwd=kit,
                                  capture_output=True, text=True, shell=os.name == "nt")
            made = done.returncode == 0 and os.path.exists(project)
            if not made:
                log("  the kit could not create its starter project: " + (done.stderr or done.stdout)[-200:].strip())
        else:
            log("  the kit's packages are not installed (npm ci) - making a bare project; Claude Code can finish the setup")
        if not made:
            for sub in ("assets", "compositions", "renders"):
                ensure_dir(os.path.join(project, sub))
    ensure_dir(os.path.join(project, "assets"))
    return project


def _finish_project(project, slug, workspace, words, total, tighten):
    """Write raw.json (and silenced.mp4/.json when tightening) and the two prompts."""
    assets = os.path.join(project, "assets")
    write_json(os.path.join(assets, "raw.json"), kit_transcript_from_words(words, total))
    if tighten:
        silenced = os.path.join(assets, "silenced.mp4")
        ranges = keep_ranges(words, total)
        if not os.path.exists(silenced) or abs(duration(silenced) - sum(b - a for a, b in ranges)) > 0.5:
            log("Removing pauses on this PC...")
            render_pieces(os.path.join(assets, "raw.mp4"), ranges, silenced)
        moved = retime(words, ranges)
        write_json(os.path.join(assets, "silenced.json"), kit_transcript_from_words(moved, duration(silenced)))
    for kind in SKILLS:
        write_text(os.path.join(project, f"prompt-{kind}.txt"), prompt(slug, kind, workspace, tightened=tighten))


def kit_transcript_from_words(words, seconds):
    return {"text": " ".join(w for _, _, w in words), "audio_duration_secs": round(seconds, 3),
            "words": [{"text": w, "start": a, "end": b} for a, b, w in words]}


def _words(recording, whisper, cache):
    segs = transcribe_words(recording, whisper, cache=cache)
    words = [w for seg in segs for w in seg["words"]]
    if not words:
        fail("No speech was found in this recording.")
    return words


def prepare(recording, slug, workspace, whisper="small", tighten=False):
    if not os.path.exists(recording):
        fail(f"Recording not found: {recording}")
    project = _kit_project(slug)
    assets = os.path.join(project, "assets")
    raw = os.path.join(assets, "raw.mp4")
    if not os.path.exists(raw) or abs(duration(raw) - duration(recording)) > 0.5:
        if recording.lower().endswith(".mp4"):
            shutil.copy2(recording, raw)
        else:
            log("Converting the recording to MP4...")
            subprocess.run(FF + ["-i", recording, *venc(18), "-c:a", "aac", "-b:a", "192k", raw], check=True)
    cached = os.path.join(assets, "raw.words.json")
    if os.path.exists(cached):
        words = [tuple(w) for w in read_json(cached)]
    else:
        log("Transcribing on this PC (word-level)...")
        words = _words(raw, whisper, os.path.join(assets, "raw.partial.json"))
        write_json(cached, words)
        if os.path.exists(os.path.join(assets, "raw.partial.json")):
            os.remove(os.path.join(assets, "raw.partial.json"))
    total = duration(raw)
    _finish_project(project, slug, workspace, [list(w) for w in words], total, tighten)
    log(f"Ready: {project}\n  raw.mp4 ({total:.0f}s), raw.json ({len(words)} words)"
        + (", silenced.mp4" if tighten else "") + ", prompt-short.txt, prompt-long.txt")
    log(f"RECORDING PROJECT: {project}")
    return project


def split_points(words, total, minutes):
    """Where to cut a long recording into parts of about `minutes`: at the longest pause within a minute of
    each target time, so no sentence is cut in half. Returns [(start, end), ...] covering the whole recording."""
    size = minutes * 60.0
    if total <= size * 1.25:
        return [(0.0, round(total, 3))]
    cuts, target = [], size
    while target < total - size * 0.25:
        best, width = None, 0.0
        for (_, b0, _), (a1, _, _) in zip(words, words[1:]):
            mid = (b0 + a1) / 2
            if abs(mid - target) <= 60 and a1 - b0 > width:
                best, width = mid, a1 - b0
        cut = best if best is not None else target
        cuts.append(round(cut, 3))
        target = cut + size
    edges = [0.0] + cuts + [round(total, 3)]
    return list(zip(edges, edges[1:]))


def split(recording, slug, workspace, minutes=8.0, whisper="small", tighten=False):
    """Cut a long recording into parts at natural pauses, one kit project per part, so each edit and render
    stays small enough for a 16 GB PC."""
    if not os.path.exists(recording):
        fail(f"Recording not found: {recording}")
    if not SLUG.match(slug):
        fail("The project name must be lowercase letters, digits and dashes, like my-first-take.")
    if minutes < 2:
        fail("Parts must be at least 2 minutes long.")
    total = duration(recording)
    cache_dir = ensure_dir(os.path.join(os.path.dirname(recording), ".pstudio"))
    cached = os.path.join(cache_dir, make_slug(recording) + ".words.json")
    if os.path.exists(cached) and (read_json(cached) or {}).get("total") == round(total, 2):
        words = [list(w) for w in read_json(cached)["words"]]
    else:
        log("Transcribing on this PC (word-level, in 10-minute pieces)...")
        words = _words(recording, whisper, os.path.join(cache_dir, make_slug(recording) + ".partial.json"))
        write_json(cached, {"total": round(total, 2), "words": words})
    parts = split_points(words, total, minutes)
    if len(parts) == 1:
        log(f"This recording is only {total / 60:.1f} minutes - no need to split it. Preparing it as one project.")
        return [prepare(recording, slug, workspace, whisper, tighten)]
    log(f"Splitting {total / 60:.1f} minutes into {len(parts)} parts at natural pauses...")
    projects = []
    for n, (a, b) in enumerate(parts, 1):
        part_slug = f"{slug}-part-{n:02}"
        project = _kit_project(part_slug)
        raw = os.path.join(project, "assets", "raw.mp4")
        if not os.path.exists(raw) or abs(duration(raw) - (b - a)) > 0.5:
            render_pieces(recording, [(a, b)], raw)
        mine = [[round(s - a, 2), round(e - a, 2), w] for s, e, w in words if s >= a - 0.01 and e <= b + 0.01]
        _finish_project(project, part_slug, workspace, mine, duration(raw), tighten)
        log(f"  part {n}: {a / 60:5.1f}-{b / 60:5.1f} min -> video-projects/{part_slug}")
        projects.append(project)
    log(f"PARTS: {len(projects)}")
    return projects


def join(slug):
    """Join the newest render of every part of `slug` into video-projects/<slug>-joined.mp4."""
    kit = kit_dir()
    parts = sorted(glob.glob(os.path.join(kit, "video-projects", f"{slug}-part-[0-9][0-9]")))
    if not parts:
        fail(f"No parts named {slug}-part-01, -02 ... were found. Use 'Split into parts' first.")
    clips, missing = [], []
    for p in parts:
        renders = sorted(glob.glob(os.path.join(p, "renders", "*.mp4")), key=os.path.getmtime)
        (clips.append(renders[-1]) if renders else missing.append(os.path.basename(p)))
    if missing:
        fail("These parts have not been rendered yet: " + ", ".join(missing))
    w, h = video_size(clips[0])
    fmt = next((k for k, v in FORMATS.items() if v == (w, h)), "16:9" if w >= h else "9:16")
    out = os.path.join(kit, "video-projects", f"{slug}-joined.mp4")
    log(f"Joining {len(clips)} parts ({fmt})...")
    subprocess.run([sys.executable, "-u", os.path.join(APP, "assemble.py"), "--clips", *clips, "--format", fmt,
                    "--out", out], check=True)
    log(f"JOINED: {out}")
    return out


def keep_ranges(words, total, gap=0.55, head=0.22, tail=0.34):
    """Parts of a recording to keep once dead air is trimmed, using the rules documented in the kit's cut-silences
    skill: pauses under `gap` stay; longer ones shrink to a natural breath (0.24 s after a 2 s+ pause, 0.20 s after
    a sentence, 0.14 s otherwise); silence before the first and after the last word is trimmed to `head`/`tail`."""
    if not words:
        return [(0.0, total)]
    ranges, start = [], max(0.0, words[0][0] - head)
    for (a0, b0, w0), (a1, b1, w1) in zip(words, words[1:]):
        pause = a1 - b0
        if pause >= gap:
            breath = 0.24 if pause >= 2.0 else 0.20 if w0.rstrip()[-1:] in ".!?" else 0.14
            ranges.append((start, b0 + breath * 0.6))
            start = a1 - breath * 0.4
    ranges.append((start, min(total, words[-1][1] + tail)))
    return [(round(a, 3), round(b, 3)) for a, b in ranges if b - a > 0.02]


def retime(words, ranges):
    """Word timings moved onto the trimmed timeline."""
    out, shift = [], 0.0
    for a, b in ranges:
        out += [[round(s - a + shift, 2), round(e - a + shift, 2), w] for s, e, w in words if s >= a - 0.01 and e <= b + 0.01]
        shift += b - a
    return out


def render_pieces(src, ranges, out_mp4):
    """Render the kept time ranges of `src` one at a time and join them: memory stays under about 0.5 GB however
    long the recording is. Pieces keep their sound uncompressed until the end, so the joins have no gaps."""
    ranges = [(float(a), float(b)) for a, b in ranges if float(b) - float(a) > 0.02]
    if not ranges:
        fail("Nothing to keep.")
    tmp = tempfile.mkdtemp(prefix="pstudio_cut_")
    try:
        names = []
        for n, (a, b) in enumerate(ranges):
            name = f"p{n:04}.mkv"
            subprocess.run(FF + ["-ss", f"{a:.3f}", "-i", src, "-t", f"{b - a:.3f}", "-map", "0:v:0", "-map", "0:a:0?",
                                 *venc(18), "-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2", os.path.join(tmp, name)],
                           check=True)
            names.append(name)
            if len(ranges) > 20 and (n + 1) % 20 == 0:
                log(f"  rendered {n + 1} of {len(ranges)} pieces")
        with open(os.path.join(tmp, "list.txt"), "w", encoding="utf-8") as f:
            f.write("".join(f"file '{x}'\n" for x in names))
        os.makedirs(os.path.dirname(os.path.abspath(out_mp4)), exist_ok=True)
        subprocess.run(FF + ["-f", "concat", "-safe", "0", "-i", "list.txt", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                             "-movflags", "+faststart", os.path.abspath(out_mp4)], cwd=tmp, check=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return out_mp4


def read_keep(path):
    """Kept ranges from JSON: [[start, end], ...], [{"start", "end"}, ...], or {"keep": either of those}."""
    data = read_json(path)
    if isinstance(data, dict):
        data = data.get("keep") or data.get("keepRanges") or data.get("ranges") or []
    out = []
    for r in data or []:
        if isinstance(r, dict):
            r = (r.get("start", r.get("from")), r.get("end", r.get("to")))
        try:
            a, b = float(r[0]), float(r[1])
        except (TypeError, ValueError, IndexError):
            fail(f"Could not read the range {r!r} in {path}.")
        if b > a:
            out.append((a, b))
    if not out:
        fail(f"No kept ranges found in {path}.")
    return sorted(out)


def tighten(recording, out_mp4, whisper="small"):
    """Trim dead air from a recording on this PC (no AI decisions): writes the video and its re-timed words."""
    if not os.path.exists(recording):
        fail(f"Recording not found: {recording}")
    total = duration(recording)
    words = [w for seg in transcribe_words(recording, whisper, cache=out_mp4 + ".partial.json") for w in seg["words"]]
    if os.path.exists(out_mp4 + ".partial.json"):
        os.remove(out_mp4 + ".partial.json")
    if not words:
        fail("No speech was found in this recording.")
    ranges = keep_ranges(words, total)
    render_pieces(recording, ranges, out_mp4)
    kept = duration(out_mp4)
    write_json(os.path.splitext(out_mp4)[0] + ".words.json", retime(words, ranges))
    log(f"Trimmed {total - kept:.1f}s of dead air ({(total - kept) / total:.0%}): {total:.1f}s -> {kept:.1f}s in {len(ranges)} pieces")
    log(f"TIGHTENED: {out_mp4}")
    return ranges


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["prepare", "split", "join", "tighten", "render"])
    ap.add_argument("--recording")
    ap.add_argument("--slug")
    ap.add_argument("--workspace", default=os.path.join(studio_root(), "workspace"))
    ap.add_argument("--out")
    ap.add_argument("--whisper", default="small")
    ap.add_argument("--tighten", action="store_true", help="Remove pauses on this PC before handing over to Claude Code")
    ap.add_argument("--minutes", type=float, default=8.0, help="Length of each part when splitting")
    ap.add_argument("--video", help="render: the input video")
    ap.add_argument("--keep", help="render: JSON list of [start, end] ranges to keep")
    a = ap.parse_args()
    need = {"prepare": "recording", "split": "recording", "tighten": "recording", "join": "slug"}
    if a.action in need and not getattr(a, need[a.action]):
        fail(f"--{need[a.action]} is required for {a.action}.")
    if a.action == "prepare":
        prepare(os.path.abspath(a.recording), a.slug or make_slug(a.recording), os.path.abspath(a.workspace),
                a.whisper, a.tighten)
    elif a.action == "split":
        split(os.path.abspath(a.recording), a.slug or make_slug(a.recording), os.path.abspath(a.workspace),
              a.minutes, a.whisper, a.tighten)
    elif a.action == "join":
        join(a.slug)
    elif a.action == "render":
        if not (a.video and a.keep and a.out):
            fail("render needs --video, --keep and --out.")
        ranges = read_keep(a.keep)
        render_pieces(os.path.abspath(a.video), ranges, os.path.abspath(a.out))
        log(f"RENDERED: {a.out} ({len(ranges)} pieces, {duration(a.out):.1f}s)")
    else:
        out = a.out or os.path.splitext(a.recording)[0] + ".tight.mp4"
        tighten(os.path.abspath(a.recording), os.path.abspath(out), a.whisper)


if __name__ == "__main__":
    main()

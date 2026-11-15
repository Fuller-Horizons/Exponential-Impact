"""Edit a raw recording, the hybrid way: this PC prepares it, Claude Code edits it with the Herk Edit Kit.

  python recording.py prepare --recording take.mp4 --slug my-take      copy into the kit, transcribe locally,
                                                                      write the prompts for Claude Code
  python recording.py tighten --recording take.mp4 --out tight.mp4    quick local silence trim, no AI

The Herk Edit Kit (MIT, by Nate Herk) lives in <PodcastStudio>/repos/herk-edit-kit. Its skills run inside
Claude Code, which is a cloud model: the transcript and editing decisions go to Claude; the video files stay here.
"""
import argparse
import os
import re
import shutil
import subprocess

from common import FF, duration, ensure_dir, fail, log, read_json, studio_root, transcribe_words, write_json, write_text

SLUG = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
SKILLS = {"short": "short-form-edit", "long": "edit-video"}


def kit_dir():
    return os.environ.get("PSTUDIO_KIT") or os.path.join(studio_root(), "repos", "herk-edit-kit")


def make_slug(name):
    return re.sub(r"[^a-z0-9]+", "-", os.path.splitext(os.path.basename(name))[0].lower()).strip("-") or "recording"


def kit_transcript(segments, seconds):
    """Our word-level transcript in the kit's format: {"text", "audio_duration_secs", "words": [{"text", "start", "end"}]}."""
    words = [{"text": w, "start": a, "end": b} for seg in segments for a, b, w in seg["words"]]
    return {"text": " ".join(seg["text"] for seg in segments).strip(), "audio_duration_secs": round(seconds, 3),
            "words": words}


def prompt(slug, kind, workspace):
    """What the app asks Claude Code to do, as plain text the user can read and change."""
    rules = os.path.join(workspace, "house-rules.md")
    brand = os.path.join(workspace, "brand.json")
    bible = os.path.join(workspace, "style-bible.md")
    return (
        f"Use the {SKILLS[kind]} skill to edit the recording in video-projects/{slug}.\n\n"
        f"- Source: video-projects/{slug}/assets/raw.mp4. Keep it untouched.\n"
        f"- Transcript: video-projects/{slug}/assets/raw.json was made on this PC and is already in this kit's "
        "word-level format. Do not call ElevenLabs, Kie.ai or any other paid or cloud service, and do not upload "
        "the footage anywhere.\n"
        "- Follow the kit's order: cut silences, then mistakes, then the story and motion graphics.\n"
        f"- House rules: read {rules} if it exists and follow every rule. When I give you a note about the edit, "
        "apply it and add it to that file as one short rule so the next edit follows it too.\n"
        f"- Brand: use the colours, font and logo in {brand} if it exists. Show style: {bible} if it exists.\n"
        "- Show me the planned cuts before rendering, then render the final video into this project's renders folder "
        "and tell me its path.\n")


def prepare(recording, slug, workspace, whisper="small"):
    kit = kit_dir()
    if not os.path.exists(os.path.join(kit, "CLAUDE.md")):
        fail(f"The Herk Edit Kit is not installed at {kit}. Re-run Setup-PodcastStudio.ps1.")
    if not os.path.exists(recording):
        fail(f"Recording not found: {recording}")
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
    assets = ensure_dir(os.path.join(project, "assets"))
    raw = os.path.join(assets, "raw.mp4")
    if not os.path.exists(raw) or abs(duration(raw) - duration(recording)) > 0.5:
        if recording.lower().endswith(".mp4"):
            shutil.copy2(recording, raw)
        else:
            log("Converting the recording to MP4...")
            subprocess.run(FF + ["-i", recording, "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
                                 "-c:a", "aac", "-b:a", "192k", raw], check=True)
    transcript = os.path.join(assets, "raw.json")
    if not os.path.exists(transcript):
        log("Transcribing on this PC (word-level)...")
        data = kit_transcript(transcribe_words(raw, whisper), duration(raw))
        if not data["words"]:
            fail("No speech was found in this recording.")
        write_json(transcript, data)
    words = len(read_json(transcript)["words"])
    for kind in SKILLS:
        write_text(os.path.join(project, f"prompt-{kind}.txt"), prompt(slug, kind, workspace))
    log(f"Ready: {project}\n  raw.mp4 ({duration(raw):.0f}s), raw.json ({words} words), prompt-short.txt, prompt-long.txt")
    log(f"RECORDING PROJECT: {project}")
    return project


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


def tighten(recording, out_mp4, whisper="small"):
    """Trim dead air from a recording on this PC (no AI decisions): writes the video and its re-timed words."""
    if not os.path.exists(recording):
        fail(f"Recording not found: {recording}")
    total = duration(recording)
    words = [w for seg in transcribe_words(recording, whisper) for w in seg["words"]]
    if not words:
        fail("No speech was found in this recording.")
    ranges = keep_ranges(words, total)
    parts = []
    for n, (a, b) in enumerate(ranges):
        parts.append(f"[0:v]trim=start={a}:end={b},setpts=PTS-STARTPTS[v{n}];"
                     f"[0:a]atrim=start={a}:end={b},asetpts=PTS-STARTPTS[a{n}]")
    graph = ";".join(parts) + ";" + "".join(f"[v{n}][a{n}]" for n in range(len(ranges))) + f"concat=n={len(ranges)}:v=1:a=1[v][a]"
    script = out_mp4 + ".filter.txt"
    write_text(script, graph)
    tail_args = ["-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
                 "-c:a", "aac", "-b:a", "192k", out_mp4]
    done = subprocess.run(FF + ["-i", recording, "-/filter_complex", script] + tail_args, capture_output=True, text=True)
    if done.returncode != 0:   # older ffmpeg spells the option differently
        done = subprocess.run(FF + ["-i", recording, "-filter_complex_script", script] + tail_args, capture_output=True, text=True)
    os.remove(script)
    if done.returncode != 0:
        fail("ffmpeg could not trim the recording: " + done.stderr[-300:])
    kept = duration(out_mp4)
    write_json(os.path.splitext(out_mp4)[0] + ".words.json", retime(words, ranges))
    log(f"Trimmed {total - kept:.1f}s of dead air ({(total - kept) / total:.0%}): {total:.1f}s -> {kept:.1f}s in {len(ranges)} pieces")
    log(f"TIGHTENED: {out_mp4}")
    return ranges


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["prepare", "tighten"])
    ap.add_argument("--recording", required=True)
    ap.add_argument("--slug")
    ap.add_argument("--workspace", default=os.path.join(studio_root(), "workspace"))
    ap.add_argument("--out")
    ap.add_argument("--whisper", default="small")
    a = ap.parse_args()
    if a.action == "prepare":
        prepare(os.path.abspath(a.recording), a.slug or make_slug(a.recording), os.path.abspath(a.workspace), a.whisper)
    else:
        out = a.out or os.path.splitext(a.recording)[0] + ".tight.mp4"
        tighten(os.path.abspath(a.recording), os.path.abspath(out), a.whisper)


if __name__ == "__main__":
    main()

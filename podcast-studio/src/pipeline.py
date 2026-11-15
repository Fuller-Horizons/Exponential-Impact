"""Prompt -> outline -> script + shot list -> voice -> visuals -> finished video. All local.

  python pipeline.py --project <dir> --stage outline --prompt-file prompt.txt [--seconds 45 ...]
  (edit <dir>/outline.txt, then)
  python pipeline.py --project <dir> --stage all

Every stage writes into the project folder and skips work that already exists, so a failed
run resumes where it stopped. `--force` redoes the chosen stage.
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import time

from common import (FF, FORMATS, duration, ensure_dir, fail, gpu_used_mb, log, read_json, read_text,
                    record_metric, run, write_json, write_text)

STAGES = ["outline", "script", "voice", "visuals", "render"]
WORDS_PER_SECOND = 2.5


# ------------------------------------------------------------------ project state
def load(project):
    return read_json(os.path.join(project, "project.json"), {})


def save(project, cfg):
    write_json(os.path.join(project, "project.json"), cfg)


def style_bible(project):
    for p in (os.path.join(project, "style-bible.md"),
              os.path.join(os.path.dirname(os.path.dirname(project)), "style-bible.md")):
        if os.path.exists(p):
            return read_text(p)[:6000]
    return ""


def library_dir(cfg, project):
    return cfg.get("library") or os.path.join(os.path.dirname(os.path.dirname(project)), "library")


# ------------------------------------------------------------------ stage: outline
def stage_outline(project, cfg, force):
    import llm

    out = os.path.join(project, "outline.txt")
    if os.path.exists(out) and not force:
        log("outline.txt exists - keeping it (use --force to redraft)")
        return
    bible = style_bible(project)
    system = ("You plan short videos for a podcast. Be concrete and punchy. Plain text only, no markdown."
              + (f"\n\nSHOW STYLE GUIDE:\n{bible}" if bible else ""))
    user = (f"Write an outline for a {cfg['seconds']}-second video about:\n{cfg['prompt']}\n\n"
            "Use exactly this layout:\n"
            "TITLE: <max 8 words>\n"
            "HOOK: <the opening line, said in the first 3 seconds>\n"
            "BEATS:\n1. <one line>\n2. <one line>\n(4 to 7 beats)\n"
            "CTA: <closing line>")
    t0 = time.time()
    text = llm.chat(system, user, cfg["model"])
    write_text(out, text.strip() + "\n")
    record_metric(project, "outline", seconds=round(time.time() - t0, 1), model=cfg["model"])
    log(f"Outline saved: {out}\n\n{text}\n")


# ------------------------------------------------------------------ stage: script
def clean_scenes(raw, kinds):
    """Coerce whatever the model returned into a valid scene list."""
    scenes = []
    for s in (raw.get("scenes") or []) if isinstance(raw, dict) else []:
        if not isinstance(s, dict):
            continue
        narration = " ".join(str(s.get("narration", "")).split())
        if not narration:
            continue
        visual = str(s.get("visual", "")).lower().strip()
        if visual not in kinds:
            visual = kinds[0]
        scenes.append({
            "narration": narration,
            "visual": visual,
            "query": str(s.get("query") or narration)[:200],
            "card_text": " ".join(str(s.get("card_text") or "").split())[:120],
            "image_prompt": str(s.get("image_prompt") or s.get("query") or narration)[:300],
        })
    return scenes


def stage_script(project, cfg, force):
    import llm

    out = os.path.join(project, "script.json")
    outline_path = os.path.join(project, "outline.txt")
    if not os.path.exists(outline_path):
        stage_outline(project, cfg, False)
    outline = read_text(outline_path).strip()
    digest = hashlib.sha1(outline.encode("utf-8")).hexdigest()
    old = read_json(out)
    if old and not force and old.get("outline_sha1") == digest:
        log("script.json matches the outline - keeping it")
        return
    if old:  # outline was edited: everything built from the old script is stale
        log("Outline changed - rebuilding script, voice and visuals")
        for sub in ("voice", "visuals", "scenes"):
            shutil.rmtree(os.path.join(project, sub), ignore_errors=True)

    from library import Library
    kinds = []
    if len(Library(library_dir(cfg, project))):
        kinds.append("footage")
    kinds.append("card")
    if cfg.get("stills"):
        kinds.append("still")
    words = int(cfg["seconds"] * WORDS_PER_SECOND)
    explain = {"footage": '"footage" = a real clip from the podcast; give "query": words to search the episode transcripts',
               "card": '"card" = bold text on screen; give "card_text": max 10 words',
               "still": '"still" = a generated photo; give "image_prompt": a visual description, no text in image'}
    bible = style_bible(project)
    system = ("You write narration scripts and shot lists for short podcast videos. Reply with JSON only."
              + (f"\n\nSHOW STYLE GUIDE:\n{bible}" if bible else ""))
    user = (f"Turn this outline into a narrated video of about {cfg['seconds']} seconds "
            f"(about {words} spoken words in total).\n\nOUTLINE:\n{outline}\n\n"
            "Return JSON: {\"title\": str, \"scenes\": [{\"narration\": str, \"visual\": str, "
            "\"query\": str, \"card_text\": str, \"image_prompt\": str}]}\n"
            "Rules:\n- One scene per sentence or two of narration (6 to 12 scenes).\n"
            "- The first scene is the hook. The last scene is the call to action.\n"
            "- Narration is spoken aloud: no emojis, no stage directions, no hashtags.\n"
            "- \"visual\" must be one of: " + ", ".join(kinds) + ".\n"
            + "\n".join("- " + explain[k] for k in kinds) + "\n- Vary the visuals.")
    t0 = time.time()
    scenes, raw = [], {}
    for attempt in range(3):
        raw = llm.chat(system, user, cfg["model"], as_json=True, temperature=0.6 + 0.1 * attempt)
        scenes = clean_scenes(raw, kinds)
        if len(scenes) >= 3:
            break
        log(f"  attempt {attempt + 1}: unusable script, retrying")
    if len(scenes) < 3:
        fail("The local model did not produce a usable script. Try another model in the Create tab.")
    title = str(raw.get("title") or outline.splitlines()[0].replace("TITLE:", "").strip())[:80]
    write_json(out, {"title": title, "outline_sha1": digest, "scenes": scenes})
    write_text(os.path.join(project, "script.txt"), "\n\n".join(s["narration"] for s in scenes) + "\n")
    total = sum(len(s["narration"].split()) for s in scenes)
    record_metric(project, "script", seconds=round(time.time() - t0, 1), scenes=len(scenes), words=total)
    log(f"Script saved: {len(scenes)} scenes, {total} words (~{total / WORDS_PER_SECOND:.0f}s)")


# ------------------------------------------------------------------ stage: voice
def stage_voice(project, cfg, force):
    script = read_json(os.path.join(project, "script.json"))
    if not script:
        fail("No script.json - run the script stage first.")
    vdir = ensure_dir(os.path.join(project, "voice"))
    todo = []
    for i, s in enumerate(script["scenes"], 1):
        wav = os.path.join(vdir, f"scene_{i:02}.wav")
        if force or not os.path.exists(wav) or duration(wav) < 0.2:
            todo.append((i, s, wav))
    if not todo:
        log("All voice lines exist - skipping")
        return
    ref = cfg.get("voice")
    if not ref or not os.path.exists(ref):
        fail("No reference voice set. Make one in the Voice clone tab, then pick it in Create.")
    ref_text = None
    txt = cfg.get("voice_text") or os.path.splitext(ref)[0] + ".txt"
    if os.path.exists(txt):
        ref_text = read_text(txt).strip() or None

    from tts import Voice
    t0, before = time.time(), gpu_used_mb()
    voice = Voice(ref, ref_text, device=cfg.get("device", "cuda"), language=cfg.get("language", "English"))
    for i, s, wav in todo:
        log(f"[voice {i}/{len(script['scenes'])}] {s['narration'][:70]}")
        voice.speak(s["narration"], wav, pause=0.15)
    record_metric(project, "voice", seconds=round(time.time() - t0, 1), torch_peak_mb=voice.peak_mb(),
                  gpu_used_before_mb=before, gpu_used_after_mb=gpu_used_mb(), dtype=str(voice.dtype))
    log(f"Voice done. Peak VRAM (torch): {voice.peak_mb()} MiB")


# ------------------------------------------------------------------ stage: visuals
def stage_visuals(project, cfg, force):
    import visuals
    from library import Library

    script = read_json(os.path.join(project, "script.json"))
    if not script:
        fail("No script.json - run the script stage first.")
    fmt = cfg["format"]
    vdir = ensure_dir(os.path.join(project, "visuals"))
    lib = Library(library_dir(cfg, project))
    stills, t0 = None, time.time()
    counts = {"footage": 0, "card": 0, "still": 0}
    for i, s in enumerate(script["scenes"], 1):
        out = os.path.join(vdir, f"scene_{i:02}.mp4")
        wav = os.path.join(project, "voice", f"scene_{i:02}.wav")
        if not os.path.exists(wav):
            fail(f"Missing voice line {wav} - run the voice stage first.")
        secs = duration(wav) + 0.05
        if os.path.exists(out) and not force and abs(duration(out) - secs) < 0.6:
            continue
        kind = s["visual"]
        log(f"[visual {i}/{len(script['scenes'])}] {kind} ({secs:.1f}s)")
        try:
            if kind == "footage":
                hit = lib.search(s["query"])
                if not hit:
                    raise RuntimeError("no matching footage")
                log(f"  {os.path.basename(hit['file'])} @ {hit['start']}s (score {hit['score']})")
                visuals.footage_clip(hit["file"], hit["start"], out, secs, fmt)
                s["source"] = {"file": hit["file"], "start": hit["start"]}
            elif kind == "still":
                stills = stills or visuals.StillMaker()
                png = os.path.splitext(out)[0] + ".png"
                stills.make(s["image_prompt"], png, fmt)
                visuals.kenburns(png, out, secs, fmt)
            else:
                raise LookupError
        except Exception as e:
            if not isinstance(e, LookupError):
                log(f"  {kind} failed ({e}) - using a text card instead")
            kind = "card"
            text = s["card_text"] or " ".join(s["narration"].split()[:10])
            visuals.card_clip(text, out, secs, fmt, kicker=script.get("title") if i == 1 else None)
        counts[kind] += 1
    write_json(os.path.join(project, "script.json"), script)
    record_metric(project, "visuals", seconds=round(time.time() - t0, 1), gpu_used_after_mb=gpu_used_mb(),
                  torch_peak_mb=stills.peak_mb() if stills else 0, **counts)
    log(f"Visuals done: {counts}")


# ------------------------------------------------------------------ stage: render
def stage_render(project, cfg, force):
    script = read_json(os.path.join(project, "script.json"))
    if not script:
        fail("No script.json.")
    sdir = ensure_dir(os.path.join(project, "scenes"))
    W, H = FORMATS[cfg["format"]]
    clips, expected = [], 0.0
    for i in range(1, len(script["scenes"]) + 1):
        vis = os.path.join(project, "visuals", f"scene_{i:02}.mp4")
        wav = os.path.join(project, "voice", f"scene_{i:02}.wav")
        for p in (vis, wav):
            if not os.path.exists(p):
                fail(f"Missing {p} - run earlier stages first.")
        out = os.path.join(sdir, f"scene_{i:02}.mp4")
        secs = duration(wav)
        expected += secs
        # hold the last frame if the picture is shorter than the voice line, then cut to the voice
        run(FF + ["-i", vis, "-i", wav, "-filter_complex",
                  f"[0:v]scale={W}:{H},setsar=1,tpad=stop_mode=clone:stop_duration=2[v]",
                  "-map", "[v]", "-map", "1:a", "-t", f"{secs:.3f}", "-r", "30",
                  "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p",
                  "-c:a", "aac", "-ar", "48000", "-ac", "2", out])
        clips.append(out)

    final = os.path.join(project, "final.mp4")
    cmd = [sys.executable, "-u", os.path.join(os.path.dirname(os.path.abspath(__file__)), "assemble.py"),
           "--clips", *clips, "--format", cfg["format"], "--out", final]
    if cfg.get("captions", True):
        cmd.append("--captions")
    if cfg.get("music") and os.path.exists(cfg["music"]):
        cmd += ["--music", cfg["music"]]
    run(cmd)
    got = duration(final)
    ok = abs(got - expected) < 1.5
    record_metric(project, "render", final_seconds=round(got, 2), expected_seconds=round(expected, 2), duration_ok=ok)
    log(f"{'OK' if ok else 'WARNING: length mismatch'} - final video {got:.1f}s (voice total {expected:.1f}s)")
    log(f"FINAL: {final}")


RUN = {"outline": stage_outline, "script": stage_script, "voice": stage_voice,
       "visuals": stage_visuals, "render": stage_render}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True)
    ap.add_argument("--stage", default="all", choices=STAGES + ["all"])
    ap.add_argument("--prompt")
    ap.add_argument("--prompt-file")
    ap.add_argument("--seconds", type=int)
    ap.add_argument("--format", choices=list(FORMATS))
    ap.add_argument("--model")
    ap.add_argument("--voice")
    ap.add_argument("--voice-text")
    ap.add_argument("--language")
    ap.add_argument("--library")
    ap.add_argument("--music")
    ap.add_argument("--device", choices=["cuda", "cpu"])
    ap.add_argument("--stills", choices=["on", "off"])
    ap.add_argument("--captions", choices=["on", "off"])
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()

    project = ensure_dir(os.path.abspath(a.project))
    cfg = {"seconds": 45, "format": "9:16", "model": "gemma3:4b", "language": "English",
           "device": "cuda", "stills": False, "captions": True}
    cfg.update(load(project))
    if a.prompt_file:
        cfg["prompt"] = read_text(a.prompt_file).strip()
    for key in ("prompt", "seconds", "format", "model", "voice", "voice_text", "language", "library", "music", "device"):
        if getattr(a, key) is not None:
            cfg[key] = getattr(a, key)
    for key in ("stills", "captions"):
        if getattr(a, key) is not None:
            cfg[key] = getattr(a, key) == "on"
    if not cfg.get("prompt"):
        fail("No prompt. Pass --prompt or --prompt-file.")
    save(project, cfg)

    if a.stage != "all":
        RUN[a.stage](project, cfg, a.force)
        return
    # Each stage runs in its own process so GPU memory is fully released between models.
    for stage in STAGES[1:]:
        log(f"\n===== {stage.upper()} =====")
        cmd = [sys.executable, "-u", os.path.abspath(__file__), "--project", project, "--stage", stage]
        if subprocess.run(cmd).returncode != 0:
            fail(f"Stage '{stage}' failed. Fix the problem and run it again (step 2 in the Create tab) - finished work is kept.")
    log("\nAll stages complete.")


if __name__ == "__main__":
    main()

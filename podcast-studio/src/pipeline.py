"""Prompt -> outline -> script + shot list -> voice -> visuals -> video -> quality gate. All local.

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

STAGES = ["outline", "script", "voice", "visuals", "render", "qa"]
WORDS_PER_SECOND = 2.5


# ------------------------------------------------------------------ project state
def load(project):
    return read_json(os.path.join(project, "project.json"), {})


def save(project, cfg):
    write_json(os.path.join(project, "project.json"), cfg)


def style_bible(project):
    """The show's style guide, with the house rules (lasting corrections) placed first so they win."""
    workspace = os.path.dirname(os.path.dirname(project))
    text = ""
    for p in (os.path.join(project, "style-bible.md"), os.path.join(workspace, "style-bible.md")):
        if os.path.exists(p):
            text = read_text(p)[:6000]
            break
    rules = os.path.join(workspace, "house-rules.md")
    if os.path.exists(rules) and read_text(rules).strip():
        text = "HOUSE RULES (always follow these):\n" + read_text(rules).strip()[:3000] + ("\n\n" + text if text else "")
    return text


def library_dir(cfg, project):
    return cfg.get("library") or os.path.join(os.path.dirname(os.path.dirname(project)), "library")


# ------------------------------------------------------------------ stage: outline
OUTLINE_SCHEMA = {"type": "object", "required": ["title", "hooks", "beats", "cta"], "properties": {
    "title": {"type": "string"},
    "hooks": {"type": "array", "items": {"type": "string"}, "minItems": 3, "maxItems": 3},
    "beats": {"type": "array", "items": {"type": "string"}},
    "cta": {"type": "string"}}}


def stage_outline(project, cfg, force):
    """Draft outline.txt plus hooks.json (three opening lines to choose from)."""
    import llm

    out = os.path.join(project, "outline.txt")
    if os.path.exists(out) and not force:
        log("outline.txt exists - keeping it (use --force to redraft)")
        return
    bible = style_bible(project)
    system = ("You plan short videos for a podcast. Be concrete and punchy. No markdown."
              + (f"\n\nSHOW STYLE GUIDE:\n{bible}" if bible else ""))
    ask = f"Plan a {cfg['seconds']}-second video about:\n{cfg['prompt']}\n\n"
    t0, hooks, text = time.time(), [], ""
    try:
        plan = llm.chat(system, ask + "Return JSON with: \"title\" (max 8 words), \"hooks\" (exactly 3 different "
                        "opening lines, each said in the first 3 seconds: one a bold claim, one a question, one a "
                        "short story opener), \"beats\" (4 to 7 one-line points), \"cta\" (closing line).",
                        cfg["model"], schema=OUTLINE_SCHEMA)
        hooks = [" ".join(str(h).split()) for h in plan.get("hooks") or [] if str(h).strip()][:3]
        beats = [" ".join(str(b).split()) for b in plan.get("beats") or [] if str(b).strip()]
        if hooks and len(beats) >= 3:
            text = (f"TITLE: {plan.get('title', '').strip()}\nHOOK: {hooks[0]}\nBEATS:\n"
                    + "\n".join(f"{n}. {b}" for n, b in enumerate(beats, 1)) + f"\nCTA: {plan.get('cta', '').strip()}")
    except Exception as e:  # noqa: BLE001 - fall back to a plain-text outline
        log(f"  structured outline failed ({e}); asking for plain text")
    if not text:
        hooks = []
        text = llm.chat(system, ask + "Use exactly this layout, plain text only:\nTITLE: <max 8 words>\n"
                        "HOOK: <the opening line, said in the first 3 seconds>\nBEATS:\n1. <one line>\n2. <one line>\n"
                        "(4 to 7 beats)\nCTA: <closing line>", cfg["model"])
    write_text(out, text.strip() + "\n")
    write_json(os.path.join(project, "hooks.json"), hooks)
    record_metric(project, "outline", seconds=round(time.time() - t0, 1), model=cfg["model"], hooks=len(hooks))
    log(f"Outline saved: {out}\n\n{text}\n")
    if len(hooks) > 1:
        log("Other hooks to choose from:\n" + "\n".join(f"  - {h}" for h in hooks[1:]))


# ------------------------------------------------------------------ stage: script
SOUNDBITE_SECONDS = 7.0
MAX_SOUNDBITES = 2
EXPLAIN = {
    "soundbite": '"soundbite" = the hosts themselves, a real clip played with its own sound (use at most 2); '
                 'give "query": words to search the episode transcripts, and set "narration" to ""',
    "footage": '"footage" = silent episode footage under the narration; give "query": words to search the transcripts',
    "card": '"card" = bold text on screen; give "card_text": max 10 words',
    "still": '"still" = a generated photo; give "image_prompt": a visual description, no text in the image',
}


def scene_schema(kinds):
    text = {"type": "string"}
    return {"type": "object", "required": ["title", "scenes"], "properties": {
        "title": text,
        "scenes": {"type": "array", "items": {"type": "object", "required": ["narration", "visual"], "properties": {
            "narration": text, "visual": {"type": "string", "enum": kinds},
            "query": text, "card_text": text, "image_prompt": text}}}}}


def clean_scenes(raw, kinds):
    """Coerce whatever the model returned into a valid scene list."""
    scenes, bites = [], 0
    for s in (raw.get("scenes") or []) if isinstance(raw, dict) else []:
        if not isinstance(s, dict):
            continue
        narration = " ".join(str(s.get("narration") or "").split())
        visual = str(s.get("visual") or "").lower().strip()
        query = " ".join(str(s.get("query") or "").split())[:200]
        if visual == "soundbite" and "soundbite" in kinds and query and bites < MAX_SOUNDBITES:
            bites += 1
        elif not narration:
            continue
        elif visual not in kinds or visual == "soundbite":
            visual = next(k for k in kinds if k != "soundbite")
        scenes.append({
            "narration": narration,
            "visual": visual,
            "query": query or narration[:200],
            "card_text": " ".join(str(s.get("card_text") or "").split())[:120],
            "image_prompt": str(s.get("image_prompt") or query or narration)[:300],
        })
    return scenes


def estimate_seconds(scenes):
    spoken = sum(len(s["narration"].split()) for s in scenes if s["visual"] != "soundbite")
    return spoken / WORDS_PER_SECOND + SOUNDBITE_SECONDS * sum(s["visual"] == "soundbite" for s in scenes)


def resolve_sources(scenes, lib):
    """Find the real clip for every footage/soundbite scene now, so later stages know each scene's type."""
    from library import pick_soundbite

    out = []
    for s in scenes:
        if s["visual"] in ("footage", "soundbite"):
            hit = lib.search(s["query"])
            if hit and s["visual"] == "soundbite":
                start, secs, segs, words = pick_soundbite(hit, s["query"])
                s["source"] = {"file": hit["file"], "start": start, "seconds": secs, "segs": segs, "words": words}
                s["narration"] = ""
            elif hit:
                s["source"] = {"file": hit["file"], "start": hit["start"]}
            elif not s["narration"]:
                continue  # a soundbite with nothing to play and nothing to say
            else:
                s["visual"] = "card"
        out.append(s)
    return out


def script_request(outline, target, kinds, bible=""):
    """The (system, user) messages that ask a model for the narration and shot list."""
    system = ("You write narration scripts and shot lists for short podcast videos. Reply with JSON only."
              + (f"\n\nSHOW STYLE GUIDE:\n{bible}" if bible else ""))
    user = (f"Turn this outline into a video of about {target:.0f} seconds. Narration is spoken at "
            f"{WORDS_PER_SECOND} words per second, so write about {int(target * WORDS_PER_SECOND)} words of narration "
            f"in total (each soundbite replaces about {int(SOUNDBITE_SECONDS * WORDS_PER_SECOND)} of those words)."
            f"\n\nOUTLINE:\n{outline}\n\n"
            "Return JSON: {\"title\": str, \"scenes\": [{\"narration\": str, \"visual\": str, "
            "\"query\": str, \"card_text\": str, \"image_prompt\": str}]}\n"
            "Rules:\n- One scene per sentence or two of narration (6 to 12 scenes).\n"
            "- The first scene is the hook. The last scene is the call to action.\n"
            "- Narration is spoken aloud: no emojis, no stage directions, no hashtags.\n"
            "- \"visual\" must be one of: " + ", ".join(kinds) + ".\n"
            + "\n".join("- " + EXPLAIN[k] for k in kinds) + "\n- Vary the visuals.")
    return system, user


def stage_script(project, cfg, force):
    import llm
    from library import Library

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

    lib = Library(library_dir(cfg, project))
    kinds = []
    if len(lib):
        if cfg.get("soundbites", True):
            kinds.append("soundbite")
        kinds.append("footage")
    kinds.append("card")
    if cfg.get("stills"):
        kinds.append("still")
    target = float(cfg["seconds"])
    system, base = script_request(outline, target, kinds, style_bible(project))
    t0, best, feedback = time.time(), None, ""
    for attempt in range(3):
        raw = llm.chat(system, base + feedback, cfg["model"], schema=scene_schema(kinds),
                       temperature=0.6 + 0.1 * attempt)
        scenes = clean_scenes(raw, kinds)
        if len(scenes) < 3:
            log(f"  attempt {attempt + 1}: unusable script, retrying")
            continue
        est = estimate_seconds(scenes)
        title = raw.get("title") if isinstance(raw, dict) else None
        if best is None or abs(est - target) < abs(best[0] - target):
            best = (est, scenes, title)
        if abs(est - target) <= 0.25 * target:
            break
        log(f"  attempt {attempt + 1}: would run ~{est:.0f}s, target {target:.0f}s - asking for a rewrite")
        feedback = (f"\n\nYour last draft would run about {est:.0f} seconds. Rewrite it to run about {target:.0f} "
                    f"seconds by {'adding' if est < target else 'cutting'} narration.")
    if best is None:
        fail("The local model did not produce a usable script. Try another model in the Create tab.")
    est, scenes, title = best
    scenes = resolve_sources(scenes, lib)
    if len(scenes) < 2 or not any(s["narration"] for s in scenes):
        fail("The script has too few usable scenes. Press step 2 again or try another model.")
    title = str(title or outline.splitlines()[0].replace("TITLE:", "").strip())[:80]
    write_json(out, {"title": title, "outline_sha1": digest, "scenes": scenes})
    write_text(os.path.join(project, "script.txt"),
               "\n\n".join(s["narration"] or f"[soundbite: {s['query']}]" for s in scenes) + "\n")
    kinds_used = {k: sum(s["visual"] == k for s in scenes) for k in kinds}
    record_metric(project, "script", seconds=round(time.time() - t0, 1), scenes=len(scenes),
                  estimated_seconds=round(estimate_seconds(scenes), 1), **kinds_used)
    log(f"Script saved: {len(scenes)} scenes, ~{estimate_seconds(scenes):.0f}s, {kinds_used}")


# ------------------------------------------------------------------ stage: voice
def repair_voice(voice, lines, threshold=0.6, tries=2):
    """Listen back to each new line (speech-to-text on the CPU) and re-make garbled ones, keeping the best take."""
    from common import speech_match

    retried, still_bad = [], []
    try:
        for i, s, wav in lines:
            best = speech_match(wav, s["narration"], device="cpu")
            for attempt in range(tries):
                if best >= threshold:
                    break
                log(f"  line {i} sounds wrong ({best:.0%} of words heard) - re-making, try {attempt + 1}")
                if i not in retried:
                    retried.append(i)
                backup = wav + ".prev"
                os.replace(wav, backup)
                voice.speak(s["narration"], wav, pause=0.15)
                score = speech_match(wav, s["narration"], device="cpu")
                if score > best:
                    best = score
                    os.remove(backup)
                else:
                    os.replace(backup, wav)
            if best < threshold:
                still_bad.append(i)
    except Exception as e:  # noqa: BLE001 - the check is a bonus, never a blocker
        log(f"  voice check skipped ({e})")
    if retried:
        log(f"Voice check: re-made lines {retried}; still unclear: {still_bad or 'none'}")
    return retried, still_bad


def stage_voice(project, cfg, force):
    script = read_json(os.path.join(project, "script.json"))
    if not script:
        fail("No script.json - run the script stage first.")
    vdir = ensure_dir(os.path.join(project, "voice"))
    todo = []
    for i, s in enumerate(script["scenes"], 1):
        wav = os.path.join(vdir, f"scene_{i:02}.wav")
        if s["visual"] != "soundbite" and (force or not os.path.exists(wav) or duration(wav) < 0.2):
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
    retried, still_bad = repair_voice(voice, todo) if cfg.get("voice_check", True) else ([], [])
    record_metric(project, "voice", seconds=round(time.time() - t0, 1), torch_peak_mb=voice.peak_mb(),
                  gpu_used_before_mb=before, gpu_used_after_mb=gpu_used_mb(), dtype=str(voice.dtype),
                  lines_retried=retried, lines_still_unclear=still_bad)
    log(f"Voice done. Peak VRAM (torch): {voice.peak_mb()} MiB")


# ------------------------------------------------------------------ stage: visuals
def stage_visuals(project, cfg, force):
    import brand
    import lipsync
    import visuals

    script = read_json(os.path.join(project, "script.json"))
    if not script:
        fail("No script.json - run the script stage first.")
    kit = brand.load(project)
    fmt = cfg["format"]
    vdir = ensure_dir(os.path.join(project, "visuals"))
    stills, t0 = None, time.time()
    counts = {"soundbite": 0, "footage": 0, "card": 0, "still": 0}
    for i, s in enumerate(script["scenes"], 1):
        out = os.path.join(vdir, f"scene_{i:02}.mp4")
        kind, src = s["visual"], s.get("source")
        if kind == "soundbite":
            secs = src["seconds"]
        else:
            wav = os.path.join(project, "voice", f"scene_{i:02}.wav")
            if not os.path.exists(wav):
                fail(f"Missing voice line {wav} - run the voice stage first.")
            secs = duration(wav) + 0.05
        choice = s.get("layout") or cfg.get("framing", "auto")
        want_sync = bool(cfg.get("lipsync")) and kind == "footage"
        same_framing = kind not in ("soundbite", "footage") or (
            s.get("framing_choice") == choice and bool(s.get("lipsync")) == (want_sync and lipsync.available()))
        if os.path.exists(out) and not force and same_framing and abs(duration(out) - secs) < 0.6:
            counts[kind] += 1
            continue
        log(f"[visual {i}/{len(script['scenes'])}] {kind} ({secs:.1f}s)")
        try:
            if kind in ("soundbite", "footage"):
                if not src or not os.path.exists(src["file"]):
                    raise RuntimeError("source footage is missing")
                log(f"  {os.path.basename(src['file'])} @ {src['start']}s")
                s["framing"] = visuals.footage_clip(src["file"], src["start"], out, secs, fmt,
                                                    audio=kind == "soundbite", choice=choice)
                s["framing_choice"] = choice
                s["lipsync"] = False
                if want_sync and s["framing"] == "single":
                    s["lipsync"] = lipsync.sync(out, wav)
                elif want_sync:
                    log("  lip-sync skipped: it needs one person on screen (set the framing to a single person)")
            elif kind == "still":
                stills = stills or visuals.StillMaker()
                png = os.path.splitext(out)[0] + ".png"
                stills.make(s["image_prompt"], png, fmt)
                visuals.kenburns(png, out, secs, fmt)
            else:
                raise LookupError
        except Exception as e:
            if kind == "soundbite":
                fail(f"Could not cut the soundbite for scene {i}: {e}")
            if not isinstance(e, LookupError):
                log(f"  {kind} failed ({e}) - using a text card instead")
            kind = s["visual"] = "card"
            text = s["card_text"] or " ".join(s["narration"].split()[:10])
            visuals.card_clip(text, out, secs, fmt, kicker=script.get("title") if i == 1 else None, brand=kit)
        counts[kind] += 1
    write_json(os.path.join(project, "script.json"), script)
    record_metric(project, "visuals", seconds=round(time.time() - t0, 1), gpu_used_after_mb=gpu_used_mb(),
                  torch_peak_mb=stills.peak_mb() if stills else 0, **counts)
    log(f"Visuals done: {counts}")


# ------------------------------------------------------------------ stage: render
def stage_render(project, cfg, force):
    import brand
    import subs

    script = read_json(os.path.join(project, "script.json"))
    if not script:
        fail("No script.json.")
    kit = brand.load(project)
    sdir = ensure_dir(os.path.join(project, "scenes"))
    W, H = FORMATS[cfg["format"]]
    enc = ["-r", "30", "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p",
           "-c:a", "aac", "-ar", "48000", "-ac", "2"]
    clips, words, offset = [], [], 0.0
    for i, s in enumerate(script["scenes"], 1):
        vis = os.path.join(project, "visuals", f"scene_{i:02}.mp4")
        out = os.path.join(sdir, f"scene_{i:02}.mp4")
        if not os.path.exists(vis):
            fail(f"Missing {vis} - run the visuals stage first.")
        wav = os.path.join(project, "voice", f"scene_{i:02}.wav")
        inputs = [vis] if s["visual"] == "soundbite" else [vis, wav]
        fresh = (not force and os.path.exists(out) and all(os.path.exists(p) for p in inputs)
                 and os.path.getmtime(out) >= max(os.path.getmtime(p) for p in inputs))
        if fresh:
            pass
        elif s["visual"] == "soundbite":
            secs = duration(vis)
            fades = f"loudnorm=I=-16:TP=-1.5,afade=t=in:d=0.03,afade=t=out:st={max(0, secs - 0.08):.3f}:d=0.08"
            run(FF + ["-i", vis, "-filter_complex", f"[0:v]scale={W}:{H},setsar=1[v];[0:a]{fades}[a]",
                      "-map", "[v]", "-map", "[a]", "-t", f"{secs:.3f}", *enc, out])
        else:
            if not os.path.exists(wav):
                fail(f"Missing {wav} - run the voice stage first.")
            secs = duration(wav)
            fades = f"loudnorm=I=-16:TP=-1.5,afade=t=in:d=0.02,afade=t=out:st={max(0, secs - 0.04):.3f}:d=0.04"
            # hold the last frame if the picture is shorter than the voice line, then cut to the voice
            run(FF + ["-i", vis, "-i", wav, "-filter_complex",
                      f"[0:v]scale={W}:{H},setsar=1,tpad=stop_mode=clone:stop_duration=2[v];[1:a]{fades}[a]",
                      "-map", "[v]", "-map", "[a]", "-t", f"{secs:.3f}", *enc, out])
        real = duration(out)
        if s["visual"] == "soundbite":
            exact = s["source"].get("words")
            if exact:  # word timing measured from the recording
                words += [(w, offset + a, offset + min(b, real)) for a, b, w in exact if a < real]
            else:
                for a, b, text in s["source"]["segs"]:
                    words += subs.word_times(text, offset + a, offset + min(b, real))
        else:
            words += subs.word_times(s["narration"], offset + 0.05, offset + max(0.3, real - 0.2))
        offset += real
        clips.append(out)

    final = os.path.join(project, "final.mp4")
    cmd = [sys.executable, "-u", os.path.join(os.path.dirname(os.path.abspath(__file__)), "assemble.py"),
           "--clips", *clips, "--format", cfg["format"], "--out", final]
    covered = 0.0
    if cfg.get("captions", True):
        ass = os.path.join(project, "captions.ass")
        covered = subs.build_ass(words, W, H, ass, font=brand.caption_font(kit),
                                 highlight=brand.ass_colour(kit["caption_highlight"]),
                                 uppercase=bool(kit["caption_uppercase"]))
        cmd += ["--ass", ass]
    if kit["logo"] and os.path.exists(kit["logo"]):
        cmd += ["--logo", kit["logo"], "--logo-position", kit["logo_position"]]
    music = cfg.get("music") or kit.get("music")
    if music and os.path.exists(music):
        cmd += ["--music", music]
    run(cmd)
    got = duration(final)
    ok = abs(got - offset) < 1.5
    record_metric(project, "render", final_seconds=round(got, 2), expected_seconds=round(offset, 2),
                  duration_ok=ok, caption_seconds=round(covered, 2))
    log(f"{'OK' if ok else 'WARNING: length mismatch'} - final video {got:.1f}s (scenes total {offset:.1f}s)")
    log(f"FINAL: {final}")


# ------------------------------------------------------------------ stage: qa
def stage_qa(project, cfg, force):
    cmd = [sys.executable, "-u", os.path.join(os.path.dirname(os.path.abspath(__file__)), "qa.py"),
           "--project", project]
    if not cfg.get("qa_listen", True):
        cmd.append("--no-listen")
    if subprocess.run(cmd).returncode != 0:
        fail("The quality gate found a hard failure - see qa.json in the project folder.")


RUN = {"outline": stage_outline, "script": stage_script, "voice": stage_voice,
       "visuals": stage_visuals, "render": stage_render, "qa": stage_qa}


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
    ap.add_argument("--framing", choices=["auto", "stack", "side", "wide", "single", "single-left", "single-right", "speaker"],
                    help="How episode footage is framed (a scene's own 'layout' overrides this)")
    ap.add_argument("--stills", choices=["on", "off"])
    ap.add_argument("--captions", choices=["on", "off"])
    ap.add_argument("--soundbites", choices=["on", "off"])
    ap.add_argument("--qa-listen", choices=["on", "off"], dest="qa_listen")
    ap.add_argument("--voice-check", choices=["on", "off"], dest="voice_check")
    ap.add_argument("--lipsync", choices=["on", "off"], help="Re-sync a single host's lips to the narration (MuseTalk)")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()

    project = ensure_dir(os.path.abspath(a.project))
    cfg = {"seconds": 45, "format": "9:16", "model": "gemma3:4b", "language": "English",
           "device": "cuda", "stills": False, "captions": True, "framing": "auto"}
    cfg.update(load(project))
    if a.prompt_file:
        cfg["prompt"] = read_text(a.prompt_file).strip()
    for key in ("prompt", "seconds", "format", "model", "voice", "voice_text", "language", "library", "music", "device",
                "framing"):
        if getattr(a, key) is not None:
            cfg[key] = getattr(a, key)
    for key in ("stills", "captions", "soundbites", "qa_listen", "voice_check", "lipsync"):
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

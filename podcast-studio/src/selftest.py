"""Check this PC end to end and write logs/selftest.json.

  python selftest.py --root <PodcastStudio folder>            quick: tools, imports, GPU, render
  python selftest.py --root <...> --full [--voice ref.wav]    also: local LLM, speech-to-text, voice clone, VRAM
"""
import argparse
import importlib
import os
import shutil
import subprocess
import sys
import tempfile
import time

from common import FF, duration, gpu_used_mb, log, read_text, write_json

results = []


def check(name, fn, required=True):
    t0 = time.time()
    try:
        detail = fn()
        status = "pass"
    except Exception as e:  # noqa: BLE001 - report everything
        detail, status = f"{type(e).__name__}: {e}", ("FAIL" if required else "warn")
    results.append({"check": name, "status": status, "detail": str(detail or ""), "seconds": round(time.time() - t0, 1)})
    log(f"  [{status:4}] {name}: {detail or ''}")
    return status == "pass"


def tool(name):
    def fn():
        path = shutil.which(name)
        if not path:
            raise FileNotFoundError(f"{name} is not on PATH")
        return path
    return fn


def module(name):
    def fn():
        return getattr(importlib.import_module(name), "__version__", "ok")
    return fn


def torch_gpu():
    import torch
    if not torch.cuda.is_available():
        raise RuntimeError(f"torch {torch.__version__} sees no CUDA GPU (voice and stills will be slow on CPU)")
    p = torch.cuda.get_device_properties(0)
    return f"{p.name}, {p.total_memory / 2 ** 30:.1f} GB, torch {torch.__version__}"


def ollama_ready(model):
    def fn():
        import llm
        llm.ensure_server()
        have = llm.models()
        missing = [m for m in (model, llm.EMBED_MODEL) if not any(h.split(":")[0] == m.split(":")[0] for h in have)]
        if missing:
            raise RuntimeError(f"missing models: {missing} (have {have}). Run: ollama pull <name>")
        return ", ".join(have)
    return fn


def render_test(tmp):
    def fn():
        import visuals
        clips = []
        for i, text in enumerate(["Podcast Studio self-test", "Render path works"], 1):
            vis = os.path.join(tmp, f"v{i}.mp4")
            wav = os.path.join(tmp, f"a{i}.wav")
            out = os.path.join(tmp, f"s{i}.mp4")
            visuals.card_clip(text, vis, 2.0, "9:16")
            subprocess.run(FF + ["-f", "lavfi", "-i", "sine=f=330:d=2", wav], check=True)
            subprocess.run(FF + ["-i", vis, "-i", wav, "-map", "0:v", "-map", "1:a", "-c:v", "libx264",
                                 "-preset", "veryfast", "-c:a", "aac", "-shortest", out], check=True)
            clips.append(out)
        final = os.path.join(tmp, "final.mp4")
        here = os.path.dirname(os.path.abspath(__file__))
        subprocess.run([sys.executable, os.path.join(here, "assemble.py"), "--clips", *clips,
                        "--format", "9:16", "--out", final], check=True, capture_output=True)
        d = duration(final)
        if not 3.5 < d < 4.6:
            raise RuntimeError(f"expected ~4s, got {d:.2f}s")
        return f"{d:.1f}s 1080x1920 video rendered"
    return fn


def llm_test(model):
    def fn():
        import llm
        before = gpu_used_mb()
        out = llm.chat("Reply with JSON only.", 'Return {"ok": true, "hook": "<a 6 word video hook about coffee>"}',
                       model, as_json=True)
        if "hook" not in out:
            raise RuntimeError(f"unexpected reply: {out}")
        return f"{out['hook']!r} (GPU in use before: {before} MiB)"
    return fn


def voice_test(ref, tmp):
    def fn():
        from tts import Voice
        txt = os.path.splitext(ref)[0] + ".txt"
        ref_text = read_text(txt).strip() if os.path.exists(txt) else None
        v = Voice(ref, ref_text)
        out = os.path.join(tmp, "voice.wav")
        v.speak("This is a short test of the cloned voice.", out)
        return f"{duration(out):.1f}s audio, {v.dtype}, peak VRAM {v.peak_mb()} MiB -> {out}"
    return fn


def whisper_test(wav):
    def fn():
        from common import transcribe
        segs = transcribe(wav)
        return f"heard: {' '.join(t for _, _, t in segs)[:80]!r}; GPU in use after: {gpu_used_mb()} MiB"
    return fn


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--model", default="gemma3:4b")
    ap.add_argument("--full", action="store_true")
    ap.add_argument("--voice", help="Reference WAV for the voice clone test (full mode)")
    a = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="pstudio_test_")
    log("Tools")
    for t in ("ffmpeg", "ffprobe", "ollama"):
        check(t, tool(t))
    for t in ("yt-dlp", "nvidia-smi", "node"):
        check(t, tool(t), required=False)
    log("Python packages")
    for m in ("torch", "faster_whisper", "qwen_tts", "PIL", "soundfile"):
        check(m, module(m))
    for m in ("diffusers", "fal_client"):
        check(m, module(m), required=False)
    check("GPU", torch_gpu, required=False)
    log("Local language model")
    check("ollama models", ollama_ready(a.model))
    log("Render")
    check("card + assemble", render_test(tmp))

    if a.full:
        log("Full checks (loads models)")
        check("LLM JSON reply", llm_test(a.model))
        voice = a.voice
        if not voice:
            vdir = os.path.join(a.root, "workspace", "voice")
            wavs = [os.path.join(vdir, f) for f in os.listdir(vdir)] if os.path.isdir(vdir) else []
            voice = next((w for w in wavs if w.lower().endswith(".wav")), None)
        if voice:
            if check("voice clone", voice_test(voice, tmp)):
                check("speech-to-text", whisper_test(os.path.join(tmp, "voice.wav")))
        else:
            results.append({"check": "voice clone", "status": "skip", "detail": "no reference WAV in workspace\\voice yet"})
            log("  [skip] voice clone: make a sample in the Voice clone tab, then re-run")

    failed = [r for r in results if r["status"] == "FAIL"]
    report = os.path.join(a.root, "logs", "selftest.json")
    os.makedirs(os.path.dirname(report), exist_ok=True)
    write_json(report, {"when": time.strftime("%Y-%m-%d %H:%M:%S"), "passed": not failed, "results": results})
    log(f"\n{'SELF-TEST PASSED' if not failed else 'SELF-TEST FAILED: ' + ', '.join(r['check'] for r in failed)}")
    log(f"Report: {report}")
    shutil.rmtree(tmp, ignore_errors=True) if not a.full else log(f"Test files kept in {tmp}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

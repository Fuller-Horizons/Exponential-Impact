"""Shared helpers for Podcast Studio scripts."""
import os
import subprocess
import sys


def log(msg):
    print(msg, flush=True)


def run(cmd, **kw):
    log("> " + " ".join(str(c) for c in cmd))
    subprocess.run([str(c) for c in cmd], check=True, **kw)


def transcribe(path, model_size="small", language=None):
    """Transcribe with faster-whisper. Tries the GPU first, falls back to CPU int8."""
    from faster_whisper import WhisperModel

    attempts = [("cuda", "int8_float16"), ("cpu", "int8")]
    last = None
    for device, compute in attempts:
        try:
            log(f"Transcribing on {device} ({compute}) with whisper-{model_size}...")
            model = WhisperModel(model_size, device=device, compute_type=compute)
            segments, info = model.transcribe(path, language=language, vad_filter=True)
            segs = [(s.start, s.end, s.text.strip()) for s in segments]
            log(f"Detected language: {info.language}")
            return segs
        except Exception as e:  # missing CUDA DLLs, OOM, etc.
            last = e
            log(f"  {device} failed: {e}")
    raise RuntimeError(f"Transcription failed: {last}")


def srt_time(t):
    h, rem = divmod(t, 3600)
    m, s = divmod(rem, 60)
    ms = int(round((s - int(s)) * 1000))
    return f"{int(h):02}:{int(m):02}:{int(s):02},{ms:03}"


def write_srt(segs, path, max_words=7):
    """Write SRT, splitting long segments into short caption chunks."""
    idx = 1
    with open(path, "w", encoding="utf-8") as f:
        for start, end, text in segs:
            words = text.split()
            if not words:
                continue
            chunks = [words[i:i + max_words] for i in range(0, len(words), max_words)]
            dur = (end - start) / len(chunks)
            for j, chunk in enumerate(chunks):
                a, b = start + j * dur, start + (j + 1) * dur
                f.write(f"{idx}\n{srt_time(a)} --> {srt_time(b)}\n{' '.join(chunk)}\n\n")
                idx += 1


def ensure_dir(p):
    os.makedirs(p, exist_ok=True)
    return p


def fail(msg):
    log("ERROR: " + msg)
    sys.exit(1)

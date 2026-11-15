"""Shared helpers for Podcast Studio scripts."""
import importlib.util
import json
import os
import subprocess
import sys

FORMATS = {"16:9": (1920, 1080), "9:16": (1080, 1920), "1:1": (1080, 1080)}
FF = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error"]


def log(msg):
    print(msg, flush=True)


def run(cmd, **kw):
    log("> " + " ".join(str(c) for c in cmd))
    subprocess.run([str(c) for c in cmd], check=True, **kw)


def fail(msg):
    log("ERROR: " + msg)
    sys.exit(1)


def ensure_dir(p):
    os.makedirs(p, exist_ok=True)
    return p


def read_text(path):
    """Read text written by PowerShell or Python (tolerates a UTF-8 BOM)."""
    with open(path, encoding="utf-8-sig") as f:
        return f.read()


def write_text(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def read_json(path, default=None):
    if not os.path.exists(path):
        return default
    return json.loads(read_text(path))


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "default=nw=1:nk=1", path], capture_output=True, text=True)
    try:
        return float(out.stdout.strip())
    except ValueError:
        return 0.0


def video_size(path):
    """(width, height) of the first video stream, or (0, 0)."""
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=width,height", "-of", "csv=p=0:s=x", path], capture_output=True, text=True)
    try:
        w, h = out.stdout.strip().split("x")[:2]
        return int(w), int(h)
    except ValueError:
        return 0, 0


def gpu_used_mb():
    """GPU memory in use right now (MiB) from nvidia-smi, or None."""
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=10)
        return int(out.stdout.strip().splitlines()[0])
    except Exception:
        return None


def record_metric(project_dir, stage, **values):
    """Append measurements (VRAM, seconds...) to <project>/metrics.json."""
    path = os.path.join(project_dir, "metrics.json")
    data = read_json(path, {})
    data.setdefault(stage, {}).update(values)
    write_json(path, data)


def _expose_torch_cuda_dlls():
    """faster-whisper (ctranslate2) needs cuBLAS/cuDNN DLLs; the PyTorch wheel ships them."""
    if os.name != "nt":
        return
    spec = importlib.util.find_spec("torch")
    if not spec or not spec.origin:
        return
    lib = os.path.join(os.path.dirname(spec.origin), "lib")
    if os.path.isdir(lib):
        os.environ["PATH"] = lib + os.pathsep + os.environ.get("PATH", "")
        try:
            os.add_dll_directory(lib)
        except OSError:
            pass


_whisper = {}


def studio_root():
    """The PodcastStudio folder (parent of the app folder), or PSTUDIO_ROOT when set."""
    return os.environ.get("PSTUDIO_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _faster_whisper(path, model_size, language, device, words):
    """Run faster-whisper. Returns [{"start", "end", "text", "words": [[start, end, word], ...]}]."""
    _expose_torch_cuda_dlls()
    from faster_whisper import WhisperModel

    attempts = (("cuda", "int8_float16"), ("cuda", "int8"), ("cpu", "int8"))
    if device == "cpu":
        attempts = attempts[2:]
    last = None
    for dev, compute in attempts:
        key = (model_size, dev, compute)
        try:
            if key not in _whisper:
                log(f"Loading whisper-{model_size} on {dev} ({compute})...")
                _whisper[key] = WhisperModel(model_size, device=dev, compute_type=compute)
            segments, info = _whisper[key].transcribe(path, language=language, vad_filter=True,
                                                      word_timestamps=bool(words))
            out = []
            for s in segments:
                seg = {"start": s.start, "end": s.end, "text": s.text.strip(), "words": []}
                for w in (getattr(s, "words", None) or []) if words else []:
                    if w.word.strip():
                        seg["words"].append([round(w.start, 2), round(w.end, 2), w.word.strip()])
                out.append(seg)
            return out
        except Exception as e:  # missing CUDA DLLs, OOM, etc.
            _whisper.pop(key, None)
            last = e
            log(f"  {dev}/{compute} failed: {e}")
    raise RuntimeError(f"Transcription failed: {last}")


def whisperx_exe():
    """Path to the optional WhisperX program (its own environment), or None."""
    cand = [os.environ.get("PSTUDIO_WHISPERX"),
            os.path.join(studio_root(), "venv-whisperx", "Scripts", "whisperx.exe"),
            os.path.join(studio_root(), "venv-whisperx", "bin", "whisperx")]
    return next((c for c in cand if c and os.path.exists(c)), None)


def _whisperx(exe, path, model_size, language):
    """Run WhisperX (forced word alignment; speaker labels when HF_TOKEN is set). Same shape as _faster_whisper."""
    import tempfile

    tmp = tempfile.mkdtemp(prefix="pstudio_wx_")
    cmd = [exe, path, "--model", model_size, "--output_dir", tmp, "--output_format", "json",
           "--compute_type", "int8", "--batch_size", "4"]
    if language:
        cmd += ["--language", language]
    token = os.environ.get("HF_TOKEN")
    if token:
        cmd += ["--diarize", "--hf_token", token, "--min_speakers", "1", "--max_speakers", "4"]
    log("Transcribing with WhisperX" + (" (with speaker labels)" if token else "") + "...")
    done = subprocess.run(cmd, capture_output=True, text=True)
    files = [f for f in os.listdir(tmp) if f.endswith(".json")]
    if done.returncode != 0 or not files:
        raise RuntimeError((done.stderr or done.stdout or "no output")[-400:])
    data = read_json(os.path.join(tmp, files[0]))
    out = []
    for s in data.get("segments", []):
        seg = {"start": float(s["start"]), "end": float(s["end"]), "text": str(s.get("text", "")).strip(), "words": []}
        if s.get("speaker"):
            seg["speaker"] = s["speaker"]
        for w in s.get("words", []):
            if "start" in w and "end" in w and str(w.get("word", "")).strip():
                seg["words"].append([round(float(w["start"]), 2), round(float(w["end"]), 2), str(w["word"]).strip()])
        out.append(seg)
    import shutil
    shutil.rmtree(tmp, ignore_errors=True)
    return out


def transcribe_words(path, model_size="small", language=None, device=None):
    """Transcribe with word-level timing: [{"start", "end", "text", "words": [[start, end, word]], "speaker"?}].

    Uses WhisperX when its optional environment is installed (more exact word timing, and who-said-what
    when HF_TOKEN is set); otherwise faster-whisper's built-in word timestamps.
    """
    exe = whisperx_exe()
    if exe and device != "cpu":
        try:
            return _whisperx(exe, path, model_size, language)
        except Exception as e:  # noqa: BLE001
            log(f"  WhisperX failed ({e}); using the built-in transcriber")
    return _faster_whisper(path, model_size, language, device, words=True)


def transcribe(path, model_size="small", language=None, device=None):
    """Transcribe with faster-whisper. Tries the GPU first, falls back to CPU int8.

    `device="cpu"` skips the GPU (used while another model is holding the VRAM).
    Returns [(start, end, text)].
    """
    return [(s["start"], s["end"], s["text"]) for s in _faster_whisper(path, model_size, language, device, False)]


def _plain_words(text):
    import re
    return re.findall(r"[a-z0-9']+", text.lower())


def speech_match(wav, text, device=None):
    """Share of the script's words that speech-to-text hears in `wav` (0-1). Catches garbled speech."""
    want = _plain_words(text)
    heard = set(_plain_words(" ".join(t for _, _, t in transcribe(wav, device=device))))
    return sum(1 for w in want if w in heard) / (len(want) or 1)


def srt_time(t):
    h, rem = divmod(t, 3600)
    m, s = divmod(rem, 60)
    ms = int(round((s - int(s)) * 1000))
    if ms == 1000:
        s, ms = s + 1, 0
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

"""Shared helpers for Podcast Studio scripts."""
import importlib.util
import json
import os
import shutil
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


def settings():
    """workspace/settings.json: user choices such as {"model": ..., "encoder": "auto|cpu|nvenc", "proxies": true}."""
    data = read_json(os.path.join(studio_root(), "workspace", "settings.json"), {}) or {}
    return data if isinstance(data, dict) else {}


# ------------------------------------------------------------------ video encoding
# Every clip this app writes is tagged, so later steps know they can join clips without re-encoding them.
ENC_VERSION = "1"
X264 = ["-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p"]
NVENC_TRIES = (["-c:v", "h264_nvenc", "-preset", "p4", "-rc", "vbr", "-b:v", "0", "-pix_fmt", "yuv420p"],
               ["-c:v", "h264_nvenc", "-preset", "fast", "-rc", "vbr", "-b:v", "0", "-pix_fmt", "yuv420p"])
_encoder = {}


def _nvenc_args():
    """NVENC settings that work on this PC, or None. Tested once and remembered in logs/encoder.json."""
    cache = os.path.join(studio_root(), "logs", "encoder.json")
    ffmpeg = shutil.which("ffmpeg") or "ffmpeg"
    known = read_json(cache, {}) or {}
    if known.get("ffmpeg") == ffmpeg and "nvenc" in known:
        return known["nvenc"]
    found = None
    try:
        listing = subprocess.run([ffmpeg, "-hide_banner", "-encoders"], capture_output=True, text=True, timeout=20).stdout
        if "h264_nvenc" in listing:
            for args in NVENC_TRIES:
                test = subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                                       "color=c=black:s=320x240:r=30:d=0.5", *args, "-cq", "23", "-f", "null", "-"],
                                      capture_output=True, text=True, timeout=60)
                if test.returncode == 0:
                    found = args
                    break
    except (OSError, subprocess.TimeoutExpired):
        found = None
    try:
        os.makedirs(os.path.dirname(cache), exist_ok=True)
        write_json(cache, {"ffmpeg": ffmpeg, "nvenc": found})
    except OSError:
        pass
    return found


def encoder():
    """("x264" | "nvenc", base args). NVENC moves video encoding from the CPU to the graphics card's encoder chip.

    Choose with workspace/settings.json "encoder": "auto" (default), "cpu" or "nvenc", or PSTUDIO_ENCODER.
    """
    choice = (os.environ.get("PSTUDIO_ENCODER") or settings().get("encoder") or "auto").lower()
    if choice not in _encoder:
        nv = _nvenc_args() if choice in ("auto", "nvenc") else None
        if choice == "nvenc" and not nv:
            log("  NVENC was asked for but does not work here - using the CPU encoder")
        _encoder[choice] = ("nvenc", nv) if nv else ("x264", X264)
    return _encoder[choice]


def venc(quality=20):
    """Video encoder arguments for one output at `quality` (CRF-like: lower is better), plus this app's tag."""
    kind, args = encoder()
    q = ["-cq", str(quality + 1)] if kind == "nvenc" else ["-crf", str(quality)]
    return list(args) + q + ["-metadata", f"comment=pstudio-enc={kind}-{ENC_VERSION}"]


def enc_tag():
    return f"pstudio-enc={encoder()[0]}-{ENC_VERSION}"


def probe(path):
    """Key facts about a media file for deciding whether it can be joined without re-encoding."""
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                          "stream=codec_type,codec_name,profile,width,height,pix_fmt,r_frame_rate,sample_rate,channels"
                          ":format=duration:format_tags=comment", "-of", "json", path], capture_output=True, text=True)
    try:
        data = json.loads(out.stdout or "{}")
    except json.JSONDecodeError:
        data = {}
    info = {"tag": (data.get("format", {}).get("tags", {}) or {}).get("comment", ""),
            "duration": float(data.get("format", {}).get("duration") or 0)}
    for st in data.get("streams", []):
        kind = st.get("codec_type")
        if kind == "video" and "video" not in info:
            info["video"] = (st.get("codec_name"), st.get("profile"), st.get("width"), st.get("height"),
                             st.get("pix_fmt"), st.get("r_frame_rate"))
        elif kind == "audio" and "audio" not in info:
            info["audio"] = (st.get("codec_name"), st.get("sample_rate"), st.get("channels"))
    return info


def joinable(paths, width, height, fps="30/1"):
    """True when every clip was written by this app's current encoder at this size and frame rate, with AAC
    48 kHz stereo sound, so they can be joined by copying (no re-encode)."""
    tag = enc_tag()
    first = None
    for p in paths:
        info = probe(p)
        v, a = info.get("video"), info.get("audio")
        if info["tag"] != tag or not v or not a or v[2:4] != (width, height) or v[4] != "yuv420p" or v[5] != fps:
            return False
        if a != ("aac", "48000", 2):
            return False
        if first is None:
            first = v
        elif v != first:
            return False
    return bool(paths)


def free_gpu():
    """Unload any language model Ollama is holding so the graphics card's memory is free for the next model."""
    try:
        import llm
        llm.unload_all()
    except Exception:  # noqa: BLE001 - Ollama not installed or not running: nothing to free
        pass


# ------------------------------------------------------------------ transcription
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


def _transcribe_piece(path, model_size, language, device):
    exe = whisperx_exe()
    if exe and device != "cpu":
        try:
            return _whisperx(exe, path, model_size, language)
        except Exception as e:  # noqa: BLE001
            log(f"  WhisperX failed ({e}); using the built-in transcriber")
    return _faster_whisper(path, model_size, language, device, words=True)


def chunk_seconds():
    return float(os.environ.get("PSTUDIO_CHUNK_SECONDS") or 600)


def _clock(t):
    return f"{int(t // 60)}:{int(t % 60):02}"


def transcribe_words(path, model_size="small", language=None, device=None, cache=None):
    """Transcribe with word-level timing: [{"start", "end", "text", "words": [[start, end, word]], "speaker"?}].

    Uses WhisperX when its optional environment is installed (more exact word timing, and who-said-what
    when HF_TOKEN is set); otherwise faster-whisper's built-in word timestamps.

    Long recordings are done in 10-minute pieces from a small 16 kHz copy of the sound. Each piece starts where
    the last finished sentence ended, so no word is cut in half. With `cache` (a JSON path) finished pieces are
    saved, and an interrupted run carries on where it stopped.
    """
    import tempfile

    total, step, overlap = duration(path), chunk_seconds(), 30.0
    if total <= step + overlap:
        return _transcribe_piece(path, model_size, language, device)
    state = read_json(cache, None) if cache else None
    if not (isinstance(state, dict) and state.get("source") == os.path.abspath(path) and state.get("total") == round(total, 2)):
        state = {"source": os.path.abspath(path), "total": round(total, 2), "next": 0.0, "segments": []}
    elif state["next"] > 0:
        log(f"  resuming the transcript at {_clock(state['next'])}")
    tmp = tempfile.mkdtemp(prefix="pstudio_tx_")
    try:
        sound = os.path.join(tmp, "sound.wav")       # decode the recording once: 16 kHz mono is ~2 MB a minute
        subprocess.run(FF + ["-i", path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", sound], check=True)
        t = state["next"]
        while t < total - 0.5:
            length = min(step + overlap, total - t)
            last = t + length >= total - 0.5
            piece = os.path.join(tmp, "piece.wav")
            subprocess.run(FF + ["-ss", f"{t:.3f}", "-t", f"{length:.3f}", "-i", sound, "-c:a", "pcm_s16le", piece],
                           check=True)
            segs = _transcribe_piece(piece, model_size, language, device)
            keep = [s for s in segs if last or s["start"] < step]
            for s in keep:
                s["start"], s["end"] = round(s["start"] + t, 2), round(s["end"] + t, 2)
                s["words"] = [[round(a + t, 2), round(b + t, 2), w] for a, b, w in s.get("words") or []]
            state["segments"] += keep
            nxt = keep[-1]["end"] if keep and not last else t + step
            t = total if last else max(nxt, t + 1.0)
            state["next"] = round(t, 2)
            if cache:
                write_json(cache, state)
            log(f"  transcribed {_clock(min(t, total))} of {_clock(total)}")
        return state["segments"]
    finally:
        import shutil as _shutil
        _shutil.rmtree(tmp, ignore_errors=True)


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

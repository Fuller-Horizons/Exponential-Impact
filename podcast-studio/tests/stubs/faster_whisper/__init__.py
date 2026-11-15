"""Test stand-in for faster-whisper: returns a sidecar transcript if present, else fixed topic lines."""
import os
import subprocess

TOPICS = ["budgeting for a small business owner", "hiring your first employee is hard",
          "marketing with short video clips", "why cash flow matters most of all"]


class _Word:
    def __init__(self, start, end, word):
        self.start, self.end, self.word = start, end, word


class _Seg:
    def __init__(self, start, end, text, words=False):
        self.start, self.end, self.text = start, end, text
        parts = text.split()
        step = (end - start) / max(1, len(parts))
        self.words = [_Word(start + i * step, start + (i + 1) * step, " " + w) for i, w in enumerate(parts)] if words else None


class _Info:
    language = "en"


class WhisperModel:
    def __init__(self, *args, **kw):
        if kw.get("device") == "cuda":
            raise RuntimeError("no GPU in tests")

    def transcribe(self, path, word_timestamps=False, **kw):
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of",
                              "default=nw=1:nk=1", path], capture_output=True, text=True)
        total = float(out.stdout.strip() or 0)
        if os.path.exists(path + ".txt"):
            return [_Seg(0.0, total, open(path + ".txt", encoding="utf-8").read(), word_timestamps)], _Info()
        n = max(1, int(total // 5))
        return [_Seg(i * 5.0, min(total, i * 5.0 + 5), TOPICS[i % len(TOPICS)], word_timestamps) for i in range(n)], _Info()

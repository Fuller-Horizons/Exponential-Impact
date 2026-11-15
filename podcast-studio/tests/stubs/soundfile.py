"""Test stand-in for soundfile: 16-bit WAV writer that also saves what was 'spoken' next to the file."""
import wave

import numpy as np

import _teststate


def write(path, data, sr):
    pcm = (np.clip(np.asarray(data), -1, 1) * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())
    if _teststate.spoken:
        with open(path + ".txt", "w", encoding="utf-8") as f:
            f.write(" ".join(_teststate.spoken))
        _teststate.spoken.clear()

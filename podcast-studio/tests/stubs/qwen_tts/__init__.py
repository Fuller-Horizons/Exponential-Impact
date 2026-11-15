"""Test stand-in for Qwen3-TTS: a tone whose length matches the word count."""
import os

import numpy as np

import _teststate

_seen = set()


class Qwen3TTSModel:
    @classmethod
    def from_pretrained(cls, name, **kw):
        return cls()

    def create_voice_clone_prompt(self, **kw):
        return {"prompt": True}

    def generate_voice_clone(self, text, **kw):
        garble = os.environ.get("PSTUDIO_TEST_GARBLE") and text not in _seen
        _seen.add(text)
        _teststate.spoken.append("zzz qqq" if garble else text)  # first take of each line is nonsense
        sr = 24000
        t = np.arange(int(sr * max(0.6, len(text.split()) / 2.5))) / sr
        return [0.3 * np.sin(2 * np.pi * 220 * t).astype(np.float32)], sr

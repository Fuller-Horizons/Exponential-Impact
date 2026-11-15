"""Test stand-in for Qwen3-TTS: a tone whose length matches the word count."""
import numpy as np

import _teststate


class Qwen3TTSModel:
    @classmethod
    def from_pretrained(cls, name, **kw):
        return cls()

    def create_voice_clone_prompt(self, **kw):
        return {"prompt": True}

    def generate_voice_clone(self, text, **kw):
        _teststate.spoken.append(text)
        sr = 24000
        t = np.arange(int(sr * max(0.6, len(text.split()) / 2.5))) / sr
        return [0.3 * np.sin(2 * np.pi * 220 * t).astype(np.float32)], sr

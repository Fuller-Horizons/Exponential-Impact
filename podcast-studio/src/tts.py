"""Voice-cloned narration with Qwen3-TTS 0.6B (fits a 4 GB GPU in fp16)."""
import argparse
import os
import re

from common import fail, log, read_text

MODEL = "Qwen/Qwen3-TTS-12Hz-0.6B-Base"


def chunk_text(text, limit=280):
    """Split on paragraphs, then sentences, keeping chunks under `limit` chars."""
    chunks = []
    for para in [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]:
        cur = ""
        for sent in re.split(r"(?<=[.!?])\s+", para):
            if cur and len(cur) + len(sent) + 1 > limit:
                chunks.append(cur)
                cur = sent
            else:
                cur = (cur + " " + sent).strip()
        if cur:
            chunks.append(cur)
    return chunks


class Voice:
    """Loads the model once and speaks many texts in one cloned voice."""

    def __init__(self, ref_audio, ref_text=None, model=MODEL, device="cuda", language="English"):
        import torch

        self.torch = torch
        self.model_id, self.language = model, language
        self.ref_audio, self.ref_text = ref_audio, (ref_text or None)
        self.device = device if (device == "cpu" or torch.cuda.is_available()) else "cpu"
        if self.device != device:
            log("CUDA not available - using CPU (slow).")
        self._load(torch.float16 if self.device == "cuda" else torch.float32)

    def _load(self, dtype):
        from qwen_tts import Qwen3TTSModel

        log(f"Loading {self.model_id} on {self.device} ({dtype})...")
        self.dtype = dtype
        self.model = Qwen3TTSModel.from_pretrained(
            self.model_id, device_map="cuda:0" if self.device == "cuda" else "cpu", dtype=dtype)
        self.prompt = self.model.create_voice_clone_prompt(
            ref_audio=self.ref_audio, ref_text=self.ref_text, x_vector_only_mode=self.ref_text is None)

    def _generate(self, text):
        import numpy as np

        wavs, sr = self.model.generate_voice_clone(text=text, language=self.language,
                                                   voice_clone_prompt=self.prompt)
        return np.asarray(wavs[0], dtype=np.float32), sr

    def speak(self, text, out_wav, pause=0.25):
        """Synthesize `text` to `out_wav`. Falls back to fp32 if fp16 yields silence/NaN (some GTX cards)."""
        import numpy as np
        import soundfile as sf

        pieces, sr = [], 24000
        for chunk in chunk_text(text):
            wav, sr = self._generate(chunk)
            bad = (not np.isfinite(wav).all()) or float(np.abs(wav).max(initial=0)) < 1e-4
            if bad and self.dtype == self.torch.float16:
                log("  fp16 produced invalid audio - reloading in fp32")
                del self.model
                self.torch.cuda.empty_cache()
                self._load(self.torch.float32)
                wav, sr = self._generate(chunk)
            pieces += [np.nan_to_num(wav), np.zeros(int(sr * pause), dtype=np.float32)]
            if self.device == "cuda":
                self.torch.cuda.empty_cache()
        os.makedirs(os.path.dirname(os.path.abspath(out_wav)), exist_ok=True)
        sf.write(out_wav, np.concatenate(pieces), sr)
        return out_wav

    def peak_mb(self):
        t = self.torch
        return int(t.cuda.max_memory_allocated() / 2 ** 20) if t.cuda.is_available() else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", required=True, help="Text file with the narration")
    ap.add_argument("--ref-audio", required=True)
    ap.add_argument("--ref-text", help="Text file with the reference transcript (better quality)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--language", default="English")
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--device", default="cuda", choices=["cuda", "cpu"])
    a = ap.parse_args()

    text = read_text(a.script).strip()
    if not text:
        fail("Script is empty")
    ref_text = None
    if a.ref_text and os.path.exists(a.ref_text):
        ref_text = read_text(a.ref_text).strip() or None

    voice = Voice(a.ref_audio, ref_text, a.model, a.device, a.language)
    voice.speak(text, a.out)
    log(f"Saved voiceover: {a.out}  (peak VRAM {voice.peak_mb()} MiB)")


if __name__ == "__main__":
    main()

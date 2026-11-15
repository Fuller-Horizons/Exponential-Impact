"""Voice-cloned narration with Qwen3-TTS 0.6B (fits a 4 GB GPU in fp16)."""
import argparse
import os
import re

import numpy as np

from common import fail, log


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", required=True, help="Text file with the narration")
    ap.add_argument("--ref-audio", required=True)
    ap.add_argument("--ref-text", help="Text file with the reference transcript (better quality)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--language", default="English")
    ap.add_argument("--model", default="Qwen/Qwen3-TTS-12Hz-0.6B-Base")
    ap.add_argument("--device", default="cuda", choices=["cuda", "cpu"])
    ap.add_argument("--pause", type=float, default=0.25, help="Seconds of silence between chunks")
    a = ap.parse_args()

    import soundfile as sf
    import torch
    from qwen_tts import Qwen3TTSModel

    with open(a.script, encoding="utf-8") as f:
        text = f.read().strip()
    if not text:
        fail("Script is empty")
    ref_text = None
    if a.ref_text and os.path.exists(a.ref_text):
        with open(a.ref_text, encoding="utf-8") as f:
            ref_text = f.read().strip() or None

    device = a.device
    if device == "cuda" and not torch.cuda.is_available():
        log("CUDA not available - falling back to CPU (slow).")
        device = "cpu"
    dtype = torch.float16 if device == "cuda" else torch.float32
    log(f"Loading {a.model} on {device} ({dtype})...")
    model = Qwen3TTSModel.from_pretrained(
        a.model, device_map="cuda:0" if device == "cuda" else "cpu", dtype=dtype)

    prompt = model.create_voice_clone_prompt(
        ref_audio=a.ref_audio, ref_text=ref_text, x_vector_only_mode=ref_text is None)

    chunks = chunk_text(text)
    pieces, sr = [], None
    for i, chunk in enumerate(chunks, 1):
        log(f"[{i}/{len(chunks)}] {chunk[:70]}...")
        wavs, sr = model.generate_voice_clone(text=chunk, language=a.language,
                                              voice_clone_prompt=prompt)
        pieces.append(np.asarray(wavs[0], dtype=np.float32))
        pieces.append(np.zeros(int(sr * a.pause), dtype=np.float32))
        if device == "cuda":
            torch.cuda.empty_cache()

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    sf.write(a.out, np.concatenate(pieces), sr)
    log(f"Saved voiceover: {a.out}")


if __name__ == "__main__":
    main()

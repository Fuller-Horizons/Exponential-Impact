"""Local visuals: text cards (Pillow), pan-and-zoom on stills (ffmpeg), AI stills (SD 1.5), footage cuts."""
import argparse
import os
import textwrap

from common import FF, FORMATS, duration, log, run

FONTS = [r"C:\Windows\Fonts\segoeuib.ttf", r"C:\Windows\Fonts\arialbd.ttf",
         "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
         "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf"]
SD_MODEL = "stable-diffusion-v1-5/stable-diffusion-v1-5"


def _font(size):
    from PIL import ImageFont
    for path in FONTS:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def card_image(text, out_png, fmt="9:16", kicker=None, accent=(255, 196, 0)):
    """Render a title/quote card as a PNG: dark gradient, accent bar, centred wrapped text."""
    from PIL import Image, ImageDraw

    W, H = FORMATS[fmt]
    img = Image.new("RGB", (W, H))
    px = img.load()
    for y in range(H):  # vertical gradient
        t = y / H
        row = (int(14 + 18 * t), int(16 + 14 * t), int(28 + 30 * t))
        for x in range(W):
            px[x, y] = row
    draw = ImageDraw.Draw(img)

    text = " ".join(text.split())
    size = int(min(W, H) * (0.10 if len(text) < 40 else 0.075 if len(text) < 90 else 0.058))
    while True:
        font = _font(size)
        per_line = max(8, int(W * 0.84 / (size * 0.56)))
        lines = textwrap.wrap(text, per_line) or [""]
        line_h = int(size * 1.25)
        if line_h * len(lines) <= H * 0.6 or size <= 24:
            break
        size = int(size * 0.9)

    block_h = line_h * len(lines)
    y = (H - block_h) // 2
    bar_w, bar_h = int(W * 0.12), max(6, int(size * 0.14))
    draw.rectangle([(W - bar_w) // 2, y - bar_h * 4, (W + bar_w) // 2, y - bar_h * 3], fill=accent)
    if kicker:
        kf = _font(int(size * 0.45))
        kw = draw.textlength(kicker.upper(), font=kf)
        draw.text(((W - kw) // 2, y - bar_h * 4 - int(size * 0.8)), kicker.upper(), font=kf, fill=accent)
    for line in lines:
        w = draw.textlength(line, font=font)
        draw.text(((W - w) // 2 + 3, y + 3), line, font=font, fill=(0, 0, 0))
        draw.text(((W - w) // 2, y), line, font=font, fill=(255, 255, 255))
        y += line_h
    img.save(out_png)
    return out_png


def kenburns(image, out_mp4, seconds, fmt="9:16", zoom=0.10):
    """Turn a still into a clip with a slow zoom and a short fade-in (CPU)."""
    W, H = FORMATS[fmt]
    frames = max(2, int(round(seconds * 30)))
    step = zoom / frames
    vf = (f"scale={W * 2}:{H * 2}:force_original_aspect_ratio=increase,crop={W * 2}:{H * 2},"
          f"zoompan=z='min(1+{step:.7f}*on,{1 + zoom})':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'"
          f":d={frames}:s={W}x{H}:fps=30,fade=t=in:st=0:d=0.3,format=yuv420p")
    run(FF + ["-i", image, "-vf", vf, "-frames:v", frames, "-c:v", "libx264", "-preset", "veryfast",
              "-crf", "20", "-an", out_mp4])
    return out_mp4


def card_clip(text, out_mp4, seconds, fmt="9:16", kicker=None):
    png = os.path.splitext(out_mp4)[0] + ".png"
    card_image(text, png, fmt, kicker)
    return kenburns(png, out_mp4, seconds, fmt, zoom=0.05)


def footage_clip(src, start, out_mp4, seconds, fmt="9:16"):
    """Cut `seconds` of real footage from `src` at `start`, cropped to fill the frame, muted."""
    W, H = FORMATS[fmt]
    total = duration(src)
    start = max(0.0, min(float(start), max(0.0, total - seconds)))
    vf = f"scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H},fps=30,format=yuv420p,setsar=1"
    run(FF + ["-ss", f"{start:.2f}", "-t", f"{seconds:.2f}", "-i", src, "-vf", vf, "-an",
              "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", out_mp4])
    if duration(out_mp4) < seconds - 0.5:  # source too short: freeze the last frame
        padded = out_mp4 + ".pad.mp4"
        run(FF + ["-i", out_mp4, "-vf", f"tpad=stop_mode=clone:stop_duration={seconds}", "-t", f"{seconds:.2f}",
                  "-an", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", padded])
        os.replace(padded, out_mp4)
    return out_mp4


class StillMaker:
    """Stable Diffusion 1.5 on a 4 GB GPU: fp16 + CPU offload + attention slicing.

    Some GTX 16xx cards return black images in fp16; those are detected and retried in fp32.
    """

    def __init__(self, model=SD_MODEL):
        self.model = model
        self.pipe = None
        self.dtype = None

    def _load(self, fp32=False):
        import torch
        from diffusers import StableDiffusionPipeline

        cuda = torch.cuda.is_available()
        self.dtype = torch.float32 if (fp32 or not cuda) else torch.float16
        log(f"Loading {self.model} ({self.dtype}, {'cuda' if cuda else 'cpu'})...")
        pipe = StableDiffusionPipeline.from_pretrained(self.model, torch_dtype=self.dtype, safety_checker=None)
        pipe.enable_attention_slicing()
        if cuda:
            (pipe.enable_sequential_cpu_offload if fp32 else pipe.enable_model_cpu_offload)()
        self.pipe = pipe

    def make(self, prompt, out_png, fmt="9:16", steps=22):
        import numpy as np
        import torch

        w, h = {"9:16": (448, 768), "16:9": (768, 448), "1:1": (512, 512)}[fmt]
        full = prompt + ", cinematic lighting, high detail, professional photograph"
        negative = "text, watermark, logo, blurry, deformed, low quality, extra fingers"
        for attempt in (False, True):
            if self.pipe is None or attempt:
                self._load(fp32=attempt)
            image = self.pipe(full, negative_prompt=negative, width=w, height=h,
                              num_inference_steps=steps, guidance_scale=7.0).images[0]
            if np.asarray(image).mean() > 3 or self.dtype == torch.float32:
                image.save(out_png)
                return out_png
            log("  black image in fp16 - retrying in fp32 (slower)")
        return out_png

    def peak_mb(self):
        import torch
        return int(torch.cuda.max_memory_allocated() / 2 ** 20) if torch.cuda.is_available() else 0


def main():
    ap = argparse.ArgumentParser(description="Make one visual clip")
    ap.add_argument("kind", choices=["card", "still"])
    ap.add_argument("text", help="Card text or image prompt")
    ap.add_argument("--out", required=True)
    ap.add_argument("--seconds", type=float, default=4)
    ap.add_argument("--format", default="9:16", choices=list(FORMATS))
    a = ap.parse_args()
    if a.kind == "card":
        card_clip(a.text, a.out, a.seconds, a.format)
    else:
        png = os.path.splitext(a.out)[0] + ".png"
        StillMaker().make(a.text, png, a.format)
        kenburns(png, a.out, a.seconds, a.format)
    log(f"Saved {a.out}")


if __name__ == "__main__":
    main()

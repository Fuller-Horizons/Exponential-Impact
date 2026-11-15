"""Local visuals: text cards (Pillow), pan-and-zoom on stills (ffmpeg), AI stills (SD 1.5), footage cuts."""
import argparse
import os
import textwrap

from common import FF, FORMATS, duration, log, run

FONTS = [r"C:\Windows\Fonts\segoeuib.ttf", r"C:\Windows\Fonts\arialbd.ttf",
         "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
         "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf"]
SD_MODEL = "stable-diffusion-v1-5/stable-diffusion-v1-5"


def _font(size, preferred=()):
    from PIL import ImageFont
    for path in list(preferred) + FONTS:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def card_image(text, out_png, fmt="9:16", kicker=None, brand=None):
    """Render a title/quote card as a PNG in the brand colours: gradient, accent bar, centred wrapped text."""
    from PIL import Image, ImageDraw

    import brand as brandkit

    kit = brand or brandkit.load()
    accent, ink, base = brandkit.rgb(kit["accent"]), brandkit.rgb(kit["text"]), brandkit.rgb(kit["background"], (32, 34, 62))
    fonts = brandkit.font_files(kit)
    W, H = FORMATS[fmt]
    column = Image.new("RGB", (1, H))
    for y in range(H):  # darker at the top, the brand background colour at the bottom
        t = 0.45 + 0.55 * y / H
        column.putpixel((0, y), tuple(int(c * t) for c in base))
    img = column.resize((W, H))
    draw = ImageDraw.Draw(img)

    text = " ".join(text.split())
    size = int(min(W, H) * (0.10 if len(text) < 40 else 0.075 if len(text) < 90 else 0.058))
    while True:
        font = _font(size, fonts)
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
        kf = _font(int(size * 0.45), fonts)
        kw = draw.textlength(kicker.upper(), font=kf)
        draw.text(((W - kw) // 2, y - bar_h * 4 - int(size * 0.8)), kicker.upper(), font=kf, fill=accent)
    for line in lines:
        w = draw.textlength(line, font=font)
        draw.text(((W - w) // 2 + 3, y + 3), line, font=font, fill=(0, 0, 0))
        draw.text(((W - w) // 2, y), line, font=font, fill=ink)
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


def card_clip(text, out_mp4, seconds, fmt="9:16", kicker=None, brand=None):
    png = os.path.splitext(out_mp4)[0] + ".png"
    card_image(text, png, fmt, kicker, brand)
    return kenburns(png, out_mp4, seconds, fmt, zoom=0.05)


def detect_faces(src, start, seconds, samples=6):
    """Faces in a few sampled frames: [[(centre_x, centre_y, width) as 0-1 fractions, ...] per frame].

    Runs on the CPU with OpenCV's bundled detector. Returns [] if OpenCV is unavailable.
    """
    try:
        import cv2
    except ImportError:
        return []
    cascade = cv2.CascadeClassifier(os.path.join(cv2.data.haarcascades, "haarcascade_frontalface_default.xml"))
    cap = cv2.VideoCapture(src)
    if cascade.empty() or not cap.isOpened():
        return []
    frames = []
    for i in range(samples):
        cap.set(cv2.CAP_PROP_POS_MSEC, (start + seconds * (i + 0.5) / samples) * 1000)
        ok, frame = cap.read()
        if not ok:
            continue
        h, w = frame.shape[:2]
        scale = 640.0 / w if w > 640 else 1.0
        gray = cv2.cvtColor(cv2.resize(frame, (int(w * scale), int(h * scale))), cv2.COLOR_BGR2GRAY)
        found = cascade.detectMultiScale(gray, scaleFactor=1.1, minNeighbors=5,
                                         minSize=(int(gray.shape[0] * 0.08),) * 2)
        gh, gw = gray.shape[:2]
        frames.append([((x + fw / 2) / gw, (y + fh / 2) / gh, fw / gw) for x, y, fw, fh in found])
    cap.release()
    return frames


def _median(values):
    values = sorted(values)
    return values[len(values) // 2]


FRAMINGS = ("auto", "stack", "side", "wide", "single", "single-left", "single-right")
ASSUMED_HOSTS = ((0.27, 0.40), (0.73, 0.40))  # where two hosts usually sit when their faces cannot be found


def find_hosts(frames):
    """(left, right, biggest): median face positions of two hosts side by side, and of the largest face.

    left/right are None unless two well-separated, similar-sized faces show up in most frames.
    """
    with_faces = [f for f in frames if f]
    pairs = []
    for f in with_faces:
        if len(f) < 2:
            continue
        a, b = sorted(f, key=lambda face: -face[2])[:2]
        if abs(a[0] - b[0]) >= 0.25 and b[2] >= 0.5 * a[2]:
            pairs.append(sorted((a, b)))
    left = right = biggest = None
    if len(pairs) >= 2 and len(pairs) >= 0.6 * len(with_faces):
        left = (_median([p[0][0] for p in pairs]), _median([p[0][1] for p in pairs]))
        right = (_median([p[1][0] for p in pairs]), _median([p[1][1] for p in pairs]))
    if len(with_faces) >= 2:
        big = [max(f, key=lambda face: face[2]) for f in with_faces]
        biggest = (_median([b[0] for b in big]), _median([b[1] for b in big]))
    return left, right, biggest


def plan_layout(frames, vertical=True, choice="auto"):
    """Decide how to frame footage.

    choice        result
    auto          stack when two hosts are found in a vertical video, else single, else centre
    stack         ("stack", left, right)   one host above the other
    side          ("side", left, right)    split screen, hosts next to each other
    wide          ("wide", left, right)    both hosts in one frame (left/right may be None)
    single        ("single", centre)       the larger face; ("center",) when no face is found
    single-left   ("single", left)         the host on the left
    single-right  ("single", right)        the host on the right
    When a two-host choice is asked for and two faces cannot be found, typical seat positions are assumed.
    """
    left, right, biggest = find_hosts(frames)
    if choice == "auto":
        if vertical and left:
            return ("stack", left, right)
        return ("single", biggest) if biggest else ("center",)
    if choice == "single":
        return ("single", biggest) if biggest else ("center",)
    if choice == "wide":
        return ("wide", left, right)
    if not left:
        left, right = ASSUMED_HOSTS
    if choice == "single-left":
        return ("single", left)
    if choice == "single-right":
        return ("single", right)
    return (choice, left, right)


def crop_offsets(src_w, src_h, W, H, center=None, zoom=1.0):
    """Scale-to-cover size and crop origin that keep `center` (0-1 fractions) in frame."""
    f = max(W / src_w, H / src_h) * zoom
    sw, sh = int(round(src_w * f / 2)) * 2, int(round(src_h * f / 2)) * 2
    cx, cy = center or (0.5, 0.5)
    if center:
        cy = min(0.5, cy + 0.1) if zoom == 1.0 else cy + 0.04  # leave headroom, keep room for captions
    x = int(min(max(cx * sw - W / 2, 0), max(sw - W, 0)))
    y = int(min(max(cy * sh - H / 2, 0), max(sh - H, 0)))
    return sw, sh, x, y


def _even(n):
    return max(2, int(n) // 2 * 2)


def _pane(src_w, src_h, pw, ph, face, show, source, name):
    """One host's box: zoomed so it shows about `show` of the original frame's width."""
    zoom = max(1.0, (pw / (show * src_w)) / max(pw / src_w, ph / src_h))
    sw, sh, x, y = crop_offsets(src_w, src_h, pw, ph, face, zoom)
    return f"[{source}]scale={sw}:{sh},crop={pw}:{ph}:{x}:{y}[{name}]"


def _backdrop(src_w, src_h, W, H, source):
    """A blurred, darkened full-frame copy to sit behind a picture that does not fill the frame."""
    sw, sh, x, y = crop_offsets(src_w, src_h, W, H)
    return f"[{source}]scale={sw}:{sh},crop={W}:{H}:{x}:{y},boxblur=24:2,eq=brightness=-0.12[bg]"


def footage_filter(src_w, src_h, W, H, layout):
    """ffmpeg filter graph ([0:v] -> [v]) for a layout from plan_layout."""
    tail = "fps=30,format=yuv420p,setsar=1[v]"
    kind = layout[0]
    if kind == "stack":
        half = H // 2
        return ("[0:v]split=2[top0][bottom0];"
                + _pane(src_w, src_h, W, half, layout[1], 0.55, "top0", "top") + ";"
                + _pane(src_w, src_h, W, half, layout[2], 0.55, "bottom0", "bottom")
                + f";[top][bottom]vstack,{tail}")
    if kind == "side":
        pw = W // 2
        ph = _even(H * 0.6) if H > W else H        # in a tall video the pair sits in a band, not two thin strips
        panes = (_pane(src_w, src_h, pw, ph, layout[1], 0.45, "l0", "l") + ";"
                 + _pane(src_w, src_h, pw, ph, layout[2], 0.45, "r0", "r"))
        if ph == H:
            return f"[0:v]split=2[l0][r0];{panes};[l][r]hstack,{tail}"
        return (f"[0:v]split=3[bg0][l0][r0];{_backdrop(src_w, src_h, W, H, 'bg0')};{panes};[l][r]hstack[fg];"
                f"[bg][fg]overlay=0:{int((H - ph) * 0.38)},{tail}")
    if kind == "wide":
        left, right = (layout[1], layout[2]) if len(layout) > 2 else (None, None)
        x0, x1 = (max(0.0, left[0] - 0.24), min(1.0, right[0] + 0.24)) if left else (0.0, 1.0)
        cw, cx = _even((x1 - x0) * src_w), int(x0 * src_w)
        h2 = _even(W * src_h / cw)
        if h2 < H:  # the two-shot is wider than the frame: show all of it over a blurred backdrop
            return (f"[0:v]split=2[bg0][fg0];{_backdrop(src_w, src_h, W, H, 'bg0')};"
                    f"[fg0]crop={cw}:{src_h}:{cx}:0,scale={W}:{h2}[fg];"
                    f"[bg][fg]overlay=0:{int((H - h2) * 0.38)},{tail}")
        layout = ("single", ((x0 + x1) / 2, (left[1] + right[1]) / 2 if left else 0.4))
    sw, sh, x, y = crop_offsets(src_w, src_h, W, H, layout[1] if layout[0] == "single" else None)
    return f"[0:v]scale={sw}:{sh},crop={W}:{H}:{x}:{y},{tail}"


def footage_clip(src, start, out_mp4, seconds, fmt="9:16", audio=False, layout=None, choice="auto"):
    """Cut `seconds` of real footage at `start`, framed by `choice` (see plan_layout). Muted unless `audio`.

    Returns the framing used: stack, side, wide, single or center.
    """
    from common import video_size

    W, H = FORMATS[fmt]
    total = duration(src)
    start = max(0.0, min(float(start), max(0.0, total - seconds)))
    src_w, src_h = video_size(src)
    if not src_w:
        raise RuntimeError(f"cannot read video size of {src}")
    if layout is None:
        frames = detect_faces(src, start, seconds)
        layout = plan_layout(frames, vertical=H > W, choice=choice if choice in FRAMINGS else "auto")
        if choice in ("stack", "side", "single-left", "single-right") and not find_hosts(frames)[0]:
            log("  two hosts not found in this clip - using typical seat positions")
    log(f"  framing: {layout[0]}")
    sound = ["-map", "0:a?", "-c:a", "aac", "-ar", "48000", "-ac", "2"] if audio else ["-an"]
    run(FF + ["-ss", f"{start:.2f}", "-t", f"{seconds:.2f}", "-i", src,
              "-filter_complex", footage_filter(src_w, src_h, W, H, layout), "-map", "[v]", *sound,
              "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", out_mp4])
    if not audio and duration(out_mp4) < seconds - 0.5:  # source too short: freeze the last frame
        padded = out_mp4 + ".pad.mp4"
        run(FF + ["-i", out_mp4, "-vf", f"tpad=stop_mode=clone:stop_duration={seconds}", "-t", f"{seconds:.2f}",
                  "-an", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", padded])
        os.replace(padded, out_mp4)
    return layout[0]


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

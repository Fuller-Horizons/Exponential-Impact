"""Who is talking? Active-speaker detection with LR-ASD (MIT licence, about 0.8 M parameters; runs on the CPU).

For a clip with two hosts in fixed seats it scores each host's face against the sound, 25 times a second,
and returns a timeline of who is speaking so the picture can cut to them.

  python speaker.py <video> --start 12 --seconds 8        prints the timeline
"""
import argparse
import os
import subprocess
import sys
import tempfile
import wave

from common import FF, log, studio_root

FPS = 25          # the model was trained on 25 fps face crops
WIDTH = 640       # frames are analysed at this width


def repo_dir():
    return os.environ.get("PSTUDIO_LRASD") or os.path.join(studio_root(), "repos", "LR-ASD")


def available():
    return os.path.exists(os.path.join(repo_dir(), "weight", "pretrain_AVA.model"))


class Detector:
    """Loads LR-ASD once; `scores(faces, mfcc)` gives one speaking score per video frame (above 0 = speaking)."""

    def __init__(self, device="cpu"):
        import torch

        repo = repo_dir()
        if not available():
            raise RuntimeError(f"LR-ASD is not installed at {repo}")
        if repo not in sys.path:
            sys.path.insert(0, repo)
        from model.Model import ASD_Model  # noqa: E402 - from the LR-ASD repository

        self.torch, self.device = torch, device
        self.model = ASD_Model().to(device).eval()
        self.fc = torch.nn.Linear(128, 2).to(device).eval()
        state = torch.load(os.path.join(repo, "weight", "pretrain_AVA.model"), map_location=device)
        clean = {k.replace("module.", ""): v for k, v in state.items()}
        self.model.load_state_dict({k[len("model."):]: v for k, v in clean.items() if k.startswith("model.")})
        self.fc.load_state_dict({k[len("lossAV.FC."):]: v for k, v in clean.items() if k.startswith("lossAV.FC.")})

    def scores(self, faces, mfcc):
        """faces: (frames, 112, 112) grey uint8 at 25 fps; mfcc: (frames * 4, 13). Returns a float array."""
        import numpy as np

        torch = self.torch
        length = min((mfcc.shape[0] - mfcc.shape[0] % 4) / 100, faces.shape[0] / FPS)
        mfcc, faces = mfcc[:int(round(length * 100))], faces[:int(round(length * FPS))]
        if len(faces) < FPS // 2:
            return np.zeros(len(faces))
        runs = []
        for seconds in (1, 2, 3, 4, 6):          # several window sizes, averaged, as in the reference script
            out = []
            with torch.no_grad():
                for i in range(int(np.ceil(length / seconds))):
                    a = torch.FloatTensor(mfcc[i * seconds * 100:(i + 1) * seconds * 100]).unsqueeze(0).to(self.device)
                    v = torch.FloatTensor(faces[i * seconds * FPS:(i + 1) * seconds * FPS]).unsqueeze(0).to(self.device)
                    if v.shape[1] == 0 or a.shape[1] < 4:
                        continue
                    emb = self.model.forward_audio_visual_backend(self.model.forward_audio_frontend(a),
                                                                  self.model.forward_visual_frontend(v))
                    out.extend(self.fc(emb.squeeze(1))[:, 1].reshape(-1).cpu().numpy())
            runs.append(np.asarray(out[:len(faces)] + [0.0] * max(0, len(faces) - len(out))))
        return np.mean(runs, axis=0)


def read_frames(src, start, seconds):
    """Grey frames at 25 fps, WIDTH wide: array (frames, height, WIDTH)."""
    import numpy as np

    from common import video_size
    w, h = video_size(src)
    if not w:
        raise RuntimeError(f"cannot read {src}")
    height = int(round(h * WIDTH / w / 2)) * 2
    raw = subprocess.run(FF[:1] + ["-v", "error", "-ss", f"{start:.2f}", "-t", f"{seconds:.2f}", "-i", src,
                                   "-vf", f"fps={FPS},scale={WIDTH}:{height},format=gray", "-f", "rawvideo", "-"],
                         capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.uint8)[:len(raw) // (WIDTH * height) * WIDTH * height].reshape(-1, height, WIDTH)


def mfcc(signal, rate=16000, numcep=13, nfilt=26, nfft=512, winlen=0.025, winstep=0.010, preemph=0.97, lifter=22):
    """13 MFCCs every 10 ms - the same numbers as python_speech_features.mfcc with its defaults.

    Written out here (numpy only) because that package no longer builds on every Python.
    """
    import numpy as np

    signal = np.asarray(signal, dtype=np.float64)
    signal = np.append(signal[:1], signal[1:] - preemph * signal[:-1])
    flen, fstep = int(round(winlen * rate)), int(round(winstep * rate))
    count = 1 if len(signal) <= flen else 1 + int(np.ceil((len(signal) - flen) / fstep))
    padded = np.concatenate([signal, np.zeros((count - 1) * fstep + flen - len(signal))])
    idx = np.arange(flen)[None, :] + (np.arange(count) * fstep)[:, None]
    power = np.abs(np.fft.rfft(padded[idx], nfft)) ** 2 / nfft
    energy = power.sum(axis=1)
    energy[energy == 0] = np.finfo(float).eps
    mel = np.linspace(0, 2595 * np.log10(1 + (rate / 2) / 700.0), nfilt + 2)
    bins = np.floor((nfft + 1) * (700 * (10 ** (mel / 2595.0) - 1)) / rate)
    bank = np.zeros((nfilt, nfft // 2 + 1))
    for j in range(nfilt):
        lo, mid, hi = int(bins[j]), int(bins[j + 1]), int(bins[j + 2])
        for i in range(lo, mid):
            bank[j, i] = (i - bins[j]) / (bins[j + 1] - bins[j])
        for i in range(mid, hi):
            bank[j, i] = (bins[j + 2] - i) / (bins[j + 2] - bins[j + 1])
    feat = power @ bank.T
    feat[feat == 0] = np.finfo(float).eps
    feat = np.log(feat)
    n = np.arange(nfilt)
    basis = np.cos(np.pi * (n[None, :] + 0.5) * np.arange(numcep)[:, None] / nfilt) * np.sqrt(2.0 / nfilt)
    basis[0] *= np.sqrt(0.5)                               # orthonormal DCT-II
    feat = feat @ basis.T
    feat *= 1 + (lifter / 2.0) * np.sin(np.pi * np.arange(numcep) / lifter)
    feat[:, 0] = np.log(energy)
    return feat


def read_mfcc(src, start, seconds):
    import numpy as np

    tmp = os.path.join(tempfile.mkdtemp(prefix="pstudio_asd_"), "a.wav")
    subprocess.run(FF + ["-ss", f"{start:.2f}", "-t", f"{seconds:.2f}", "-i", src, "-vn", "-ac", "1", "-ar", "16000",
                         "-c:a", "pcm_s16le", tmp], check=True)
    with wave.open(tmp, "rb") as w:
        audio = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    os.remove(tmp)
    return mfcc(audio)


def face_crops(frames, box):
    """Cut one host's face out of every frame the way the model expects. box = (centre_x, centre_y, width) as 0-1."""
    import cv2
    import numpy as np

    n, h, w = frames.shape
    half = max(8.0, box[2] * w / 2)                      # half the face box, in pixels
    pad = int(half * 1.8)                                # crop scale 0.40, as in the reference script
    mx, my = box[0] * w + pad, box[1] * h + pad
    y0, y1 = int(my - half), int(my + half * 1.8)
    x0, x1 = int(mx - half * 1.4), int(mx + half * 1.4)
    out = np.empty((n, 112, 112), dtype=np.uint8)
    for i in range(n):
        padded = np.pad(frames[i], pad, mode="constant", constant_values=110)
        out[i] = cv2.resize(padded[y0:y1, x0:x1], (224, 224))[56:168, 56:168]
    return out


def smooth_timeline(score_sets, seconds, hold=1.2, margin=0.3):
    """Turn per-host score arrays into [(start, end, who)] with who = index of the speaker or "both".

    A host is "speaking" when their score is above 0; when both or neither are, the wide shot ("both") is used.
    Shots shorter than `hold` seconds are merged into their neighbour so the picture does not flicker.
    """
    import numpy as np

    n = min(len(s) for s in score_sets)
    if n == 0:
        return [(0.0, seconds, "both")]
    kernel = np.ones(13) / 13                             # about half a second
    smooth = [np.convolve(s[:n], kernel, mode="same") for s in score_sets]
    labels = []
    for i in range(n):
        vals = [s[i] for s in smooth]
        top = int(np.argmax(vals))
        others = max(v for k, v in enumerate(vals) if k != top) if len(vals) > 1 else -9
        labels.append(top if vals[top] > 0 and vals[top] - others > margin else "both")
    runs = []
    for i, lab in enumerate(labels):
        if runs and runs[-1][2] == lab:
            runs[-1][1] = i + 1
        else:
            runs.append([i, i + 1, lab])
    changed = True
    while changed and len(runs) > 1:                      # absorb short shots
        changed = False
        for k, (a, b, lab) in enumerate(runs):
            if (b - a) / FPS < hold:
                # a short "both" between two speakers is a hand-over: give it to the speaker who is starting
                forward = k + 1 < len(runs) and (k == 0 or lab == "both")
                into = k + 1 if forward else k - 1
                runs[into][0], runs[into][1] = min(runs[into][0], a), max(runs[into][1], b)
                del runs[k]
                changed = True
                break
        merged = []
        for r in runs:
            if merged and merged[-1][2] == r[2]:
                merged[-1][1] = r[1]
            else:
                merged.append(r)
        runs = merged
    out = [(a / FPS, b / FPS, lab) for a, b, lab in runs]
    out[0] = (0.0, out[0][1], out[0][2])
    out[-1] = (out[-1][0], seconds, out[-1][2])
    return out


_detector = None


def timeline(src, start, seconds, boxes):
    """[(start, end, who)] for a clip, relative to its start. boxes = one (cx, cy, width) per host, left to right."""
    global _detector
    if _detector is None:
        _detector = Detector()
    frames = read_frames(src, start, seconds)
    mfcc = read_mfcc(src, start, seconds)
    scores = [_detector.scores(face_crops(frames, box), mfcc) for box in boxes]
    return smooth_timeline(scores, seconds)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--start", type=float, default=0)
    ap.add_argument("--seconds", type=float, default=10)
    a = ap.parse_args()
    import visuals
    boxes = visuals.find_host_boxes(visuals.detect_faces(a.video, a.start, a.seconds, samples=10))
    if not boxes:
        log("No faces found.")
        return
    for t0, t1, who in timeline(a.video, a.start, a.seconds, boxes):
        log(f"{t0:6.2f} - {t1:6.2f}  {'both / nobody' if who == 'both' else 'host ' + str(who + 1)}")


if __name__ == "__main__":
    main()

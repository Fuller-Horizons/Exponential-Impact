"""Import a Riverside session recorded as separate tracks (one video per person) as an indexed episode.

  python multitrack.py import --folder <Riverside download folder> --name my-episode [--episodes DIR --lib DIR]

Riverside records every participant on their own track. This builds one episode video with the people side by
side (two people) or in a 2x2 grid (three or four), mixes their sound, and works out who is speaking from each
person's own audio. That timing is exact, unlike guessing from lips in a shared frame, and the app's
"Active speaker" framing and Highlights use it automatically. Works from downloaded files; no Riverside account
connection or API is needed.
"""
import argparse
import glob
import os
import re
import subprocess
import tempfile
import wave

from common import FF, duration, ensure_dir, fail, log, venc, video_size, write_json

VIDEO_EXT = (".mp4", ".mov", ".mkv", ".webm", ".m4v")
FPS = 25


def speaker_name(path):
    """'Jonathan_Smith-raw-2026-11-15.mp4' -> 'Jonathan Smith' (drops dates, ids and Riverside suffixes)."""
    stem = os.path.splitext(os.path.basename(path))[0]
    skip = {"raw", "video", "camera", "cam", "track", "riverside", "audio", "hq"}
    kept = []
    for tok in re.split(r"[-_ .]+", stem):
        if re.fullmatch(r"\d{4}|\d{8}|\d{4}\d{2}\d{2}.*", tok):      # a date: the name has ended
            break
        if tok.lower() in skip or re.fullmatch(r"(?=.*\d)[0-9a-f]{6,}", tok, flags=re.I):
            continue
        if tok:
            kept.append(tok)
    return " ".join(kept) or os.path.basename(path)


def find_tracks(folder):
    files = sorted(f for f in glob.glob(os.path.join(folder, "*")) if f.lower().endswith(VIDEO_EXT)
                   and video_size(f)[0] > 0)
    if len(files) < 2:
        fail(f"Found {len(files)} video track(s) in {folder}. Download the session's separate tracks "
             "(one video per person) into one folder.")
    if len(files) > 4:
        fail("This import handles two to four people. Move extra tracks out of the folder.")
    return files


def tile_layout(n):
    """(tile width, tile height, [(x, y) per track]) on a 1920x1080 canvas."""
    if n == 2:
        return 960, 1080, [(0, 0), (960, 0)]
    return 960, 540, [(0, 0), (960, 0), (0, 540), (960, 540)][:n]


def boxes(n):
    """Where each person's face sits on the canvas (centre x, centre y, width) for the framing code."""
    tw, th, spots = tile_layout(n)
    return [((x + tw / 2) / 1920, (y + th * 0.42) / 1080, tw * 0.35 / 1920) for x, y in spots]


def track_levels(path, total):
    """Loudness of one track every 1/25 s, in dB."""
    import numpy as np
    tmp = os.path.join(tempfile.mkdtemp(prefix="pstudio_mt_"), "a.wav")
    subprocess.run(FF + ["-i", path, "-vn", "-ac", "1", "-ar", "16000", "-t", f"{total:.3f}", "-c:a", "pcm_s16le", tmp],
                   check=True)
    with wave.open(tmp, "rb") as w:
        audio = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32)
    os.remove(tmp)
    hop = 16000 // FPS
    frames = len(audio) // hop
    if frames == 0:
        return np.zeros(int(total * FPS)) - 90
    rms = np.sqrt((audio[:frames * hop].reshape(frames, hop) ** 2).mean(axis=1) + 1e-9)
    return 20 * np.log10(rms / 32768 + 1e-9)


def speaking_scores(levels):
    """Per-track scores for speaker.smooth_timeline: above 0 = this person is talking.

    Each track's own quiet level is its 20th percentile; speech is 12 dB or more above it. Microphones also pick
    up the other people a little, so a track only counts when it is the loudest relative to its own floor.
    """
    import numpy as np
    n = min(len(lv) for lv in levels)
    rel = [lv[:n] - np.percentile(lv[:n], 20) for lv in levels]
    return [(r - 12.0) / 6.0 for r in rel]


def import_session(folder, name, episodes, lib=None):
    import numpy as np
    import speaker

    if not re.match(r"^[\w\- ]+$", name):
        fail("Use letters, digits, spaces and dashes for the episode name.")
    tracks = find_tracks(folder)
    names = [speaker_name(t) for t in tracks]
    total = max(duration(t) for t in tracks)
    tw, th, spots = tile_layout(len(tracks))
    log(f"{len(tracks)} people: {', '.join(names)} ({total / 60:.1f} minutes)")
    out = os.path.join(ensure_dir(episodes), f"{name}.mp4")
    inputs, parts = [], []
    for i, t in enumerate(tracks):
        inputs += ["-i", t]
        parts.append(f"[{i}:v]scale={tw}:{th}:force_original_aspect_ratio=increase,crop={tw}:{th},setsar=1,fps=30,"
                     f"tpad=stop_mode=clone:stop_duration={total:.3f}[v{i}]")
    layout = "|".join(f"{x}_{y}" for x, y in spots)
    graph = ";".join(parts) + ";" + "".join(f"[v{i}]" for i in range(len(tracks)))
    graph += f"xstack=inputs={len(tracks)}:layout={layout}:fill=black,format=yuv420p[v];"
    graph += "".join(f"[{i}:a]" for i in range(len(tracks)))
    graph += f"amix=inputs={len(tracks)}:duration=longest:normalize=0,alimiter=limit=0.95[a]"
    log("Building the episode video (one time; about as long as the session on a 4-core PC)...")
    subprocess.run(FF + inputs + ["-filter_complex", graph, "-map", "[v]", "-map", "[a]", "-t", f"{total:.3f}",
                                  *venc(20), "-g", "30", "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2",
                                  out + ".part.mp4"], check=True)
    os.replace(out + ".part.mp4", out)
    log("Working out who speaks when, from each person's own track...")
    levels = [track_levels(t, total) for t in tracks]
    shots = speaker.smooth_timeline(speaking_scores(levels), total)
    talk = {names[w]: round(sum(b - a for a, b, who in shots if who == w), 1) for w in range(len(tracks))}
    write_json(out + ".speakers.json", {"speakers": names, "boxes": [list(map(float, b)) for b in boxes(len(tracks))],
                                        "timeline": [[round(a, 2), round(b, 2), w] for a, b, w in shots],
                                        "source": [os.path.abspath(t) for t in tracks]})
    log("Talking time: " + ", ".join(f"{k} {v / 60:.1f} min" for k, v in talk.items()))
    if lib:
        import library
        library.index(os.path.dirname(out), lib)
    log(f"EPISODE: {out}")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["import"])
    ap.add_argument("--folder", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--episodes", required=True)
    ap.add_argument("--lib")
    a = ap.parse_args()
    import_session(os.path.abspath(a.folder), a.name.strip(), os.path.abspath(a.episodes), a.lib)


if __name__ == "__main__":
    main()

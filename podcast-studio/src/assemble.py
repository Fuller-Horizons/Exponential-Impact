"""Stitch clips, lay voiceover + music, burn captions, export MP4 (CPU / ffmpeg only)."""
import argparse
import os
import shutil
import subprocess
import tempfile

from common import fail, log, run, transcribe, write_srt

FORMATS = {"16:9": (1920, 1080), "9:16": (1080, 1920), "1:1": (1080, 1080)}


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "default=nw=1:nk=1", path], capture_output=True, text=True)
    try:
        return float(out.stdout.strip())
    except ValueError:
        return 0.0


def has_audio(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries",
                          "stream=index", "-of", "csv=p=0", path], capture_output=True, text=True)
    return bool(out.stdout.strip())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clips", nargs="+", required=True)
    ap.add_argument("--voice", help="Voiceover WAV; replaces clip audio")
    ap.add_argument("--music", help="Background music")
    ap.add_argument("--music-volume", type=float, default=0.12)
    ap.add_argument("--format", default="9:16", choices=list(FORMATS))
    ap.add_argument("--captions", action="store_true")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    for c in a.clips:
        if not os.path.exists(c):
            fail(f"Missing clip: {c}")
    W, H = FORMATS[a.format]
    tmp = tempfile.mkdtemp(prefix="pstudio_")
    try:
        # 1. normalise every clip (size, fps, audio) so concat is safe
        norm = []
        for i, c in enumerate(a.clips):
            o = os.path.join(tmp, f"n{i:03}.mp4")
            vf = (f"scale={W}:{H}:force_original_aspect_ratio=decrease,"
                  f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:color=black,fps=30,format=yuv420p,setsar=1")
            cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", c]
            if not has_audio(c):
                cmd += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-shortest"]
            cmd += ["-vf", vf, "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                    "-c:a", "aac", "-ar", "48000", "-ac", "2", o]
            log(f"Normalising {os.path.basename(c)}")
            run(cmd)
            norm.append(o)

        lst = os.path.join(tmp, "list.txt")
        with open(lst, "w", encoding="utf-8") as f:
            for n in norm:
                f.write(f"file '{n.replace(os.sep, '/')}'\n")
        joined = os.path.join(tmp, "joined.mp4")
        run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "concat", "-safe", "0",
             "-i", lst, "-c", "copy", joined])

        # 2. audio: voiceover (looping video if voice is longer) + optional music bed
        stage = joined
        if a.voice or a.music:
            mixed = os.path.join(tmp, "mixed.mp4")
            cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error"]
            if a.voice and duration(a.voice) > duration(joined):
                cmd += ["-stream_loop", "-1"]
            cmd += ["-i", joined]
            filt, maps, n = [], [], 1
            base = "[0:a]"
            if a.voice:
                cmd += ["-i", a.voice]
                base = f"[{n}:a]"
                n += 1
            if a.music:
                cmd += ["-stream_loop", "-1", "-i", a.music]
                filt.append(f"[{n}:a]volume={a.music_volume}[m]")
                filt.append(f"{base}[m]amix=inputs=2:duration=first:dropout_transition=0[aout]")
                maps = ["-map", "0:v", "-map", "[aout]"]
            else:
                maps = ["-map", "0:v", "-map", base.strip("[]")]
            if filt:
                cmd += ["-filter_complex", ";".join(filt)]
            cmd += maps + ["-c:v", "copy", "-c:a", "aac"]
            if a.voice:
                cmd += ["-shortest"]
            run(cmd + [mixed])
            stage = mixed

        # 3. captions burned in (run ffmpeg from tmp so the subtitles path needs no escaping)
        if a.captions:
            segs = transcribe(a.voice or stage)
            write_srt(segs, os.path.join(tmp, "subs.srt"))
            shutil.copy(os.path.join(tmp, "subs.srt"), os.path.splitext(a.out)[0] + ".srt")
            size = 16 if H > W else 12
            style = (f"FontName=Arial,FontSize={size},Bold=1,PrimaryColour=&H00FFFFFF,"
                     f"OutlineColour=&H00000000,Outline=3,Shadow=0,Alignment=2,MarginV={int(H * 0.08)}")
            capt = os.path.join(tmp, "capt.mp4")
            run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", os.path.basename(stage),
                 "-vf", f"subtitles=subs.srt:force_style='{style}'", "-c:v", "libx264",
                 "-preset", "veryfast", "-crf", "20", "-c:a", "copy", "capt.mp4"], cwd=tmp)
            stage = capt

        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        shutil.copy(stage, a.out)
        log(f"Rendered: {a.out}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()

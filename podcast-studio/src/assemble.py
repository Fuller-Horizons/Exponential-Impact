"""Stitch clips, lay voiceover + music (ducked under speech), burn captions, normalise loudness, export MP4."""
import argparse
import os
import shutil
import subprocess
import tempfile

from common import FF, FORMATS, duration, fail, log, run, transcribe, write_srt

LOUDNESS = "loudnorm=I=-14:TP=-1.5:LRA=11"


def has_audio(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries",
                          "stream=index", "-of", "csv=p=0", path], capture_output=True, text=True)
    return bool(out.stdout.strip())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clips", nargs="+", required=True)
    ap.add_argument("--voice", help="Voiceover WAV; replaces clip audio")
    ap.add_argument("--music", help="Background music (looped, lowered while someone speaks)")
    ap.add_argument("--music-volume", type=float, default=0.25)
    ap.add_argument("--format", default="9:16", choices=list(FORMATS))
    ap.add_argument("--captions", action="store_true", help="Transcribe and burn in plain captions")
    ap.add_argument("--ass", help="Burn in this prepared ASS caption file instead of transcribing")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    for c in a.clips + [p for p in (a.voice, a.music, a.ass) if p]:
        if not os.path.exists(c):
            fail(f"Missing file: {c}")
    W, H = FORMATS[a.format]
    tmp = tempfile.mkdtemp(prefix="pstudio_")
    try:
        # 1. normalise every clip (size, fps, audio) so concat is safe
        norm = []
        for i, c in enumerate(a.clips):
            o = os.path.join(tmp, f"n{i:03}.mp4")
            vf = (f"scale={W}:{H}:force_original_aspect_ratio=decrease,"
                  f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:color=black,fps=30,format=yuv420p,setsar=1")
            cmd = FF + ["-i", c]
            if not has_audio(c):
                cmd += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-shortest"]
            cmd += ["-vf", vf, "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
                    "-c:a", "aac", "-ar", "48000", "-ac", "2", o]
            log(f"Normalising {os.path.basename(c)}")
            run(cmd)
            norm.append(o)
        with open(os.path.join(tmp, "list.txt"), "w", encoding="utf-8") as f:
            for n in norm:
                f.write(f"file '{os.path.basename(n)}'\n")
        run(FF + ["-f", "concat", "-safe", "0", "-i", "list.txt", "-c", "copy", "joined.mp4"], cwd=tmp)
        joined = os.path.join(tmp, "joined.mp4")

        # 2. captions file (ffmpeg runs inside tmp so the filter needs no Windows path escaping)
        vfilter = None
        if a.ass:
            shutil.copy(a.ass, os.path.join(tmp, "subs.ass"))
            vfilter = "ass=subs.ass"
        elif a.captions:
            write_srt(transcribe(a.voice or joined), os.path.join(tmp, "subs.srt"))
            shutil.copy(os.path.join(tmp, "subs.srt"), os.path.splitext(a.out)[0] + ".srt")
            # libass lays SRT out on a 288-line canvas, so size and margin are in those units
            style = (f"FontName=Arial,FontSize={16 if H > W else 12},Bold=1,PrimaryColour=&H00FFFFFF,"
                     f"OutlineColour=&H00000000,Outline=3,Shadow=0,Alignment=2,MarginV={28 if H > W else 20}")
            vfilter = f"subtitles=subs.srt:force_style='{style}'"

        # 3. one final pass: captions + voice/music mix + loudness
        cmd = list(FF)
        if a.voice and duration(a.voice) > duration(joined):
            cmd += ["-stream_loop", "-1"]  # loop the picture under a longer voiceover
        cmd += ["-i", "joined.mp4"]
        speech, n = "[0:a]", 1
        if a.voice:
            cmd += ["-i", os.path.abspath(a.voice)]
            speech, n = f"[{n}:a]", n + 1
        graph = []
        if a.music:
            cmd += ["-stream_loop", "-1", "-i", os.path.abspath(a.music)]
            graph += [f"{speech}aresample=48000,asplit=2[sp][key]",
                      f"[{n}:a]aresample=48000,volume={a.music_volume}[mu]",
                      "[mu][key]sidechaincompress=threshold=0.03:ratio=10:attack=15:release=350[duck]",
                      f"[sp][duck]amix=inputs=2:duration=first:dropout_transition=0:normalize=0,{LOUDNESS}[aout]"]
        else:
            graph.append(f"{speech}{LOUDNESS}[aout]")
        if vfilter:
            graph.append(f"[0:v]{vfilter}[vout]")
            cmd += ["-filter_complex", ";".join(graph), "-map", "[vout]", "-map", "[aout]",
                    "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p"]
        else:
            cmd += ["-filter_complex", ";".join(graph), "-map", "0:v", "-map", "[aout]", "-c:v", "copy"]
        cmd += ["-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2"]
        if a.voice:
            cmd += ["-shortest"]
        else:
            cmd += ["-t", f"{duration(joined):.3f}"]
        cmd += ["-movflags", "+faststart", "final.mp4"]
        run(cmd, cwd=tmp)

        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        shutil.copy(os.path.join(tmp, "final.mp4"), a.out)
        log(f"Rendered: {a.out}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()

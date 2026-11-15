"""Quality gate for a finished project. Writes <project>/qa.json and exits 1 on a hard failure.

  python qa.py --project <dir> [--no-listen]
"""
import argparse
import os
import re
import subprocess
import sys

from common import FORMATS, duration, log, read_json, video_size, write_json

checks = []


def add(name, status, detail):
    checks.append({"check": name, "status": status, "detail": detail})
    log(f"  [{status:4}] {name}: {detail}")


def ffmpeg_report(path, *filters):
    out = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, *filters, "-f", "null", "-"],
                         capture_output=True, text=True)
    return out.stderr


def listen(project, script):
    """Transcribe each voice line and compare it with the script (catches garbled speech)."""
    from common import speech_match
    bad, scores = [], []
    for i, s in enumerate(script["scenes"], 1):
        wav = os.path.join(project, "voice", f"scene_{i:02}.wav")
        if s["visual"] == "soundbite" or not os.path.exists(wav):
            continue
        score = speech_match(wav, s["narration"])
        scores.append(score)
        if score < 0.6:
            bad.append(f"scene {i} ({score:.0%})")
    if not scores:
        return add("voice matches script", "skip", "no voice lines")
    avg = sum(scores) / len(scores)
    add("voice matches script", "warn" if bad else "pass",
        f"average {avg:.0%} of script words heard" + (f"; re-make in the Scenes tab: {', '.join(bad)}" if bad else ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True)
    ap.add_argument("--no-listen", action="store_true", help="Skip the speech-to-text check of the voice")
    a = ap.parse_args()
    project = os.path.abspath(a.project)
    cfg = read_json(os.path.join(project, "project.json"), {})
    script = read_json(os.path.join(project, "script.json"), {"scenes": []})
    metrics = read_json(os.path.join(project, "metrics.json"), {})
    final = os.path.join(project, "final.mp4")
    if not os.path.exists(final):
        add("final video exists", "FAIL", "final.mp4 is missing")
    else:
        d = duration(final)
        expected = metrics.get("render", {}).get("expected_seconds", d)
        add("length matches scenes", "pass" if abs(d - expected) < 1.5 else "FAIL", f"{d:.1f}s (scenes total {expected:.1f}s)")
        target = float(cfg.get("seconds", d))
        off = abs(d - target) / target if target else 0
        add("length near target", "pass" if off <= 0.25 else "warn", f"{d:.0f}s vs {target:.0f}s asked ({off:.0%} off)")
        want = FORMATS.get(cfg.get("format", "9:16"))
        got = video_size(final)
        add("resolution", "pass" if got == want else "FAIL", f"{got[0]}x{got[1]}")

        rep = ffmpeg_report(final, "-vf", "blackdetect=d=0.5:pix_th=0.10", "-af",
                            "silencedetect=noise=-45dB:d=1.5,ebur128")
        if "Stream #0" not in rep or "Audio:" not in rep:
            add("has audio", "FAIL", "no audio stream")
        else:
            m = re.findall(r"I:\s+(-?[\d.]+) LUFS", rep)
            if m:
                lufs = float(m[-1])
                add("loudness", "pass" if -17 <= lufs <= -11 else "warn", f"{lufs:.1f} LUFS (target -14)")
            black = [float(x) for x in re.findall(r"black_duration:([\d.]+)", rep)]
            add("no black frames", "pass" if not black else "warn",
                "none" if not black else f"{len(black)} stretch(es), {sum(black):.1f}s")
            silent = [float(x) for x in re.findall(r"silence_duration: ([\d.]+)", rep)]
            add("no long silences", "pass" if not silent else "warn",
                "none" if not silent else f"{len(silent)} gap(s), longest {max(silent):.1f}s")
        cov = metrics.get("render", {}).get("caption_seconds")
        if cov is not None and d:
            add("caption coverage", "pass" if cov / d >= 0.8 else "warn", f"{cov / d:.0%} of the video")

    kinds = [s["visual"] for s in script["scenes"]]
    if kinds:
        top = max(kinds.count(k) for k in set(kinds)) / len(kinds)
        add("visual variety", "pass" if (top < 0.8 or len(kinds) < 4) else "warn",
            ", ".join(f"{k} x{kinds.count(k)}" for k in sorted(set(kinds))))
    if not a.no_listen and script["scenes"]:
        try:
            listen(project, script)
        except Exception as e:  # noqa: BLE001
            add("voice matches script", "skip", f"speech-to-text unavailable ({e})")

    failed = [c for c in checks if c["status"] == "FAIL"]
    warned = [c for c in checks if c["status"] == "warn"]
    verdict = "FAIL" if failed else ("PASS WITH WARNINGS" if warned else "PASS")
    write_json(os.path.join(project, "qa.json"), {"verdict": verdict, "checks": checks})
    log(f"QUALITY GATE: {verdict}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

"""Compare the local language models on this app's real job (writing a script and shot list) and pick the best.

  python modelbench.py --workspace <workspace> [--save] [--try phi4-mini gemma3:4b ...]

Each installed chat model writes the same two scripts. Scoring (0-100): a usable script 50, length close to the
target 30, speed 20. With --save the winner becomes the default model (workspace/settings.json).
"""
import argparse
import os
import subprocess
import time

from common import log, read_json, write_json

OUTLINES = [
    (40, "TITLE: The meeting that should have been an email\nHOOK: Half your meetings are costing you a full day a week.\n"
         "BEATS:\n1. Most meetings have no decision to make\n2. Count the people times the minutes\n"
         "3. One rule: no agenda, no meeting\n4. What to send instead\nCTA: Try it for one week and tell us what happened."),
    (30, "TITLE: Price it higher\nHOOK: You are not too expensive. You are too vague.\n"
         "BEATS:\n1. Buyers pay for certainty\n2. Say exactly what happens and when\n3. Raise the price after you add proof\n"
         "CTA: Follow for more plain talk about running a business."),
]
CANDIDATES = ["phi4-mini", "gemma3:4b", "qwen3:4b", "llama3.2:3b"]


def trial(model, target, outline, kinds):
    """One script attempt. Returns (points 0-100, seconds, note)."""
    import llm
    import pipeline

    system, user = pipeline.script_request(outline, target, kinds)
    t0 = time.time()
    try:
        raw = llm.chat(system, user, model, schema=pipeline.scene_schema(kinds), temperature=0.6, keep_alive="5m")
    except Exception as e:  # noqa: BLE001
        return 0.0, time.time() - t0, f"error: {str(e)[:60]}"
    took = time.time() - t0
    scenes = pipeline.clean_scenes(raw, kinds)
    if len(scenes) < 3:
        return 0.0, took, "unusable script"
    est = pipeline.estimate_seconds(scenes)
    off = abs(est - target) / target
    points = 50 + 30 * max(0.0, 1 - off / 0.5) + 20 * max(0.0, min(1.0, (120 - took) / 100))
    return points, took, f"{len(scenes)} scenes, ~{est:.0f}s for a {target}s target"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--save", action="store_true", help="Make the winner the default model")
    ap.add_argument("--try", nargs="*", default=None, dest="pull",
                    help="Also download and test these models (default: a short list of small models)")
    a = ap.parse_args()

    import llm
    llm.ensure_server()
    for name in (CANDIDATES if a.pull is None else a.pull):
        if not llm._installed(name, llm.models()):
            log(f"Trying to download {name}...")
            try:
                ok = subprocess.run(["ollama", "pull", name], capture_output=True).returncode == 0
            except OSError:
                ok = False
            if not ok:
                log(f"  {name} is not available - skipped")
    models = [m for m in llm.models() if "embed" not in m]
    if not models:
        raise SystemExit("ERROR: no local chat model is installed. Run: ollama pull gemma3:4b")
    kinds = ["footage", "card"]
    rows = []
    for m in models:
        log(f"Testing {m}...")
        trial(m, *OUTLINES[1], kinds)               # warm-up: loading the model should not count against its speed
        runs = [trial(m, target, outline, kinds) for target, outline in OUTLINES]
        llm.unload(m)
        for points, took, note in runs:
            log(f"   {points:5.1f} points in {took:5.1f}s  ({note})")
        rows.append({"model": m, "score": round(sum(r[0] for r in runs) / len(runs), 1),
                     "seconds": round(sum(r[1] for r in runs) / len(runs), 1), "notes": [r[2] for r in runs]})
    rows.sort(key=lambda r: (-r["score"], r["seconds"]))
    log("\nModel                      Score   Avg seconds")
    for r in rows:
        log(f"{r['model']:<26} {r['score']:5.1f}   {r['seconds']:6.1f}")
    best = rows[0]
    write_json(os.path.join(a.workspace, "model-comparison.json"), {"when": time.strftime("%Y-%m-%d %H:%M"), "results": rows})
    if best["score"] <= 0:
        raise SystemExit("ERROR: no model produced a usable script.")
    if a.save:
        path = os.path.join(a.workspace, "settings.json")
        settings = read_json(path, {}) or {}
        settings["model"] = best["model"]
        write_json(path, settings)
        log(f"\nDefault model is now {best['model']}.")
    log(f"BEST MODEL: {best['model']}")


if __name__ == "__main__":
    main()

"""Scene editor backend: change, re-make, add or delete one scene without redoing the rest.

  python scenes.py set    --project P --index 3 --fields-file edit.json
  python scenes.py remake --project P --index 3        (new voice take / next best footage / new still)
  python scenes.py add    --project P --index 3        (insert a card scene after scene 3)
  python scenes.py delete --project P --index 3
Then run pipeline.py --stage all: only the missing pieces are rebuilt.
"""
import argparse
import os

from common import fail, log, read_json, write_json, write_text

KINDS = ("soundbite", "footage", "card", "still")
PARTS = (("voice", ".wav"), ("visuals", ".mp4"), ("visuals", ".png"), ("scenes", ".mp4"))


def _path(project, folder, n, ext):
    return os.path.join(project, folder, f"scene_{n:02}{ext}")


def invalidate(project, n, voice=True):
    for folder, ext in PARTS:
        if folder == "voice" and not voice:
            continue
        for p in (_path(project, folder, n, ext), _path(project, folder, n, ext) + ".txt"):
            if os.path.exists(p):
                os.remove(p)
    final = os.path.join(project, "final.mp4")
    if os.path.exists(final):
        os.remove(final)


def renumber(project, old, new):
    for folder, ext in PARTS:
        for tail in ("", ".txt"):
            a, b = _path(project, folder, old, ext) + tail, _path(project, folder, new, ext) + tail
            if os.path.exists(a):
                os.replace(a, b)


def find_source(project, cfg, scenes, i, skip_current=False):
    """Pick episode footage for scene i that no other scene is using."""
    import pipeline
    from library import Library, pick_soundbite

    s = scenes[i]
    lib = Library(pipeline.library_dir(cfg, project))
    if not len(lib):
        fail("No footage library. Use 'Index footage' in the Create tab first.")
    for j, other in enumerate(scenes):
        if other.get("source") and (j != i or skip_current):
            lib.mark_used(other["source"]["file"], other["source"]["start"])
    hit = lib.search(s["query"])
    if not hit:
        fail("No other matching footage found for those search words.")
    if s["visual"] == "soundbite":
        start, secs, segs = pick_soundbite(hit, s["query"])
        s["source"] = {"file": hit["file"], "start": start, "seconds": secs, "segs": segs}
        s["narration"] = ""
    else:
        s["source"] = {"file": hit["file"], "start": hit["start"]}
    log(f"Scene {i + 1} now uses {os.path.basename(hit['file'])} @ {s['source']['start']}s")


def save(project, script):
    write_json(os.path.join(project, "script.json"), script)
    write_text(os.path.join(project, "script.txt"),
               "\n\n".join(s["narration"] or f"[soundbite: {s['query']}]" for s in script["scenes"]) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["set", "remake", "add", "delete"])
    ap.add_argument("--project", required=True)
    ap.add_argument("--index", type=int, required=True, help="Scene number, starting at 1")
    ap.add_argument("--fields-file", help="JSON with narration, visual, query, card_text, image_prompt")
    a = ap.parse_args()

    project = os.path.abspath(a.project)
    script = read_json(os.path.join(project, "script.json"))
    cfg = read_json(os.path.join(project, "project.json"), {})
    if not script:
        fail("This project has no script yet. Make the video first (Create tab, step 2).")
    scenes, n = script["scenes"], a.index
    if not 1 <= n <= len(scenes):
        fail(f"Scene {n} does not exist (there are {len(scenes)}).")
    s = scenes[n - 1]

    if a.action == "set":
        new = read_json(a.fields_file) or {}
        before = dict(s)
        for key in ("narration", "query", "card_text", "image_prompt"):
            if key in new:
                s[key] = " ".join(str(new[key] or "").split())
        visual = str(new.get("visual") or s["visual"]).lower()
        if visual not in KINDS:
            fail(f"Unknown scene type '{visual}'.")
        s["visual"] = visual
        if visual == "soundbite" and not s["query"]:
            fail("A soundbite needs search words.")
        if visual != "soundbite" and not s["narration"]:
            fail("This scene type needs narration text.")
        if visual in ("soundbite", "footage"):
            if visual != before["visual"] or s["query"] != before["query"] or "source" not in s:
                s["query"] = s["query"] or s["narration"][:200]
                find_source(project, cfg, scenes, n - 1)
            if visual == "soundbite":
                s["narration"] = ""
        else:
            s.pop("source", None)
        voice_changed = s["narration"] != before["narration"] or (visual == "soundbite") != (before["visual"] == "soundbite")
        if s != before:
            invalidate(project, n, voice=voice_changed)
            log(f"Scene {n} updated" + (" (voice will be re-made)" if voice_changed else " (voice kept)"))
        else:
            log(f"Scene {n}: nothing changed")
    elif a.action == "remake":
        if s["visual"] in ("soundbite", "footage"):
            find_source(project, cfg, scenes, n - 1, skip_current=True)
        invalidate(project, n)
        log(f"Scene {n} will be re-made")
    elif a.action == "add":
        for k in range(len(scenes), n, -1):
            renumber(project, k, k + 1)
        scenes.insert(n, {"narration": "New scene.", "visual": "card", "query": "", "card_text": "New scene",
                          "image_prompt": ""})
        invalidate(project, n + 1)
        log(f"Added scene {n + 1}")
    else:
        if len(scenes) <= 2:
            fail("A video needs at least two scenes.")
        invalidate(project, n)
        del scenes[n - 1]
        for k in range(n + 1, len(scenes) + 2):
            renumber(project, k, k - 1)
        log(f"Deleted scene {n}")
    script["edited"] = True
    save(project, script)


if __name__ == "__main__":
    main()

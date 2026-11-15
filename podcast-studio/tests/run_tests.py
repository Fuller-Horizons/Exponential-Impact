"""Podcast Studio tests: unit checks plus a full prompt-to-video run with stand-ins for the AI models.

  python tests/run_tests.py          (needs ffmpeg, numpy, pillow; opencv optional)

The language model, voice model and speech-to-text are replaced by small fakes in tests/stubs, so this
checks the pipeline logic and the real ffmpeg render path - not the quality of the real models.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "src")
sys.path[:0] = [SRC, os.path.join(HERE, "stubs"), HERE]
results = []


TESTS = []


def test(fn):
    TESTS.append(fn)
    return fn


def run_one(fn):
    t0 = time.time()
    try:
        fn()
        results.append((fn.__name__, True, ""))
        print(f"  pass  {fn.__name__} ({time.time() - t0:.1f}s)", flush=True)
    except Exception as e:  # noqa: BLE001
        results.append((fn.__name__, False, f"{type(e).__name__}: {e}"))
        print(f"  FAIL  {fn.__name__}: {type(e).__name__}: {e}", flush=True)


def sh(*cmd, env=None, ok=0):
    out = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, env=env)
    assert out.returncode == ok, f"exit {out.returncode}: {' '.join(map(str, cmd[:4]))}...\n{(out.stdout + out.stderr)[-1500:]}"
    return out.stdout + out.stderr


# ------------------------------------------------------------------ unit tests
@test
def captions_word_timing():
    import subs
    w = subs.word_times("Hello there {big} world", 1.0, 3.0)
    assert [x[0] for x in w] == ["Hello", "there", "big", "world"]
    assert abs(w[0][1] - 1.0) < 1e-6 and abs(w[-1][2] - 3.0) < 1e-6
    assert all(a[2] <= b[1] + 1e-6 for a, b in zip(w, w[1:]))
    assert subs.word_times("", 0, 1) == [] and subs.word_times("x", 2, 2) == []
    lines = subs.group(subs.word_times("one two three four five six. seven eight", 0, 8))
    assert all(len(line) <= 4 for line in lines) and sum(len(line) for line in lines) == 8
    path = os.path.join(tempfile.mkdtemp(), "c.ass")
    covered = subs.build_ass(subs.word_times("one two three four five six", 0, 6), 1080, 1920, path)
    text = open(path, encoding="utf-8").read()
    assert "PlayResY: 1920" in text and "\\k" in text and text.count("Dialogue:") == 2 and abs(covered - 6) < 0.1


@test
def script_cleaning():
    import pipeline
    raw = {"scenes": [{"narration": "A b c", "visual": "CARD"}, {"narration": "", "visual": "card"}, "junk",
                      {"narration": "", "visual": "soundbite", "query": "cash"},
                      {"narration": "x", "visual": "soundbite", "query": "q2"},
                      {"narration": "y y", "visual": "soundbite", "query": "q3"},
                      {"narration": "z", "visual": "hologram"}]}
    kinds = ["soundbite", "footage", "card"]
    scenes = pipeline.clean_scenes(raw, kinds)
    assert [s["visual"] for s in scenes] == ["card", "soundbite", "soundbite", "footage", "footage"], scenes
    assert pipeline.clean_scenes({"scenes": None}, kinds) == [] and pipeline.clean_scenes("no", kinds) == []
    assert all(s["visual"] == "card" for s in pipeline.clean_scenes(raw, ["card"]))
    est = pipeline.estimate_seconds([{"narration": "a " * 25, "visual": "card"}, {"narration": "", "visual": "soundbite"}])
    assert abs(est - 17.0) < 0.01
    schema = pipeline.scene_schema(kinds)
    assert schema["properties"]["scenes"]["items"]["properties"]["visual"]["enum"] == kinds


@test
def soundbite_picking():
    import library
    chunks = library._chunks([(0, 3, "intro words"), (3, 6, "cash flow matters"), (6, 9, "more cash talk"),
                              (9, 30, "a very long ramble"), (30, 33, "next chunk")])
    assert len(chunks) == 3 and len(chunks[0][3]) == 3
    chunk = {"start": 0, "end": 9, "text": "x", "segs": chunks[0][3]}
    start, secs, segs = library.pick_soundbite(chunk, "why cash flow matters")
    assert start == 3 and 4.0 <= secs <= 10.2 and segs[0][2] == "cash flow matters" and segs[0][0] == 0
    start, secs, segs = library.pick_soundbite({"start": 9, "end": 30, "text": "a very long ramble"}, "ramble")
    assert start == 9 and secs <= 10.2 and segs[0][1] <= 10.0


@test
def crop_math():
    import visuals
    assert visuals.crop_offsets(1920, 1080, 1080, 1920, None) == (3414, 1920, 1167, 0)
    assert visuals.crop_offsets(1920, 1080, 1080, 1920, (0.0, 0.5))[2] == 0
    sw, sh, x, y = visuals.crop_offsets(1920, 1080, 1080, 1920, (1.0, 0.5))
    assert x == sw - 1080 and y == 0
    assert visuals.crop_offsets(1080, 1920, 1080, 1920, (0.3, 0.3)) == (1080, 1920, 0, 0)


@test
def text_helpers():
    import common
    import tts
    assert common.srt_time(3661.5) == "01:01:01,500" and common.srt_time(0.9996) == "00:00:01,000"
    chunks = tts.chunk_text("One. Two. " + "word " * 80 + "end. Last one.\n\nNew para.", limit=100)
    assert chunks[0] == "One. Two." and chunks[-1] == "New para." and len(chunks) >= 3


@test
def layout_planning():
    import visuals
    two = [(0.27, 0.40, 0.12), (0.72, 0.42, 0.11)]
    assert visuals.plan_layout([two, two, two[::-1], [two[0]]])[0] == "stack"
    kind, left, right = visuals.plan_layout([two, two, two])
    assert left[0] < right[0] and abs(left[0] - 0.27) < 1e-6
    assert visuals.plan_layout([two, two, two], vertical=False)[0] == "single"
    assert visuals.plan_layout([[(0.3, 0.4, 0.2), (0.35, 0.4, 0.19)]] * 3)[0] == "single"   # too close together
    assert visuals.plan_layout([[(0.3, 0.4, 0.2), (0.8, 0.4, 0.05)]] * 3)[0] == "single"    # second face tiny
    assert visuals.plan_layout([[(0.6, 0.3, 0.2)], [], [(0.62, 0.3, 0.2)]]) == ("single", (0.62, 0.3))
    assert visuals.plan_layout([[], [], [(0.5, 0.5, 0.2)]]) == ("center",) and visuals.plan_layout([]) == ("center",)
    graph = visuals.footage_filter(1920, 1080, 1080, 1920, ("stack", (0.27, 0.4), (0.72, 0.42)))
    assert "vstack" in graph and graph.count("crop=1080:960") == 2


@test
def brand_kit():
    import brand
    import subs
    import visuals
    ws = tempfile.mkdtemp()
    project = os.path.join(ws, "projects", "p")
    os.makedirs(project)
    json.dump({"accent": "#FF0000", "font": "Impact", "caption_highlight": "#00FF00", "junk": 1},
              open(os.path.join(ws, "brand.json"), "w"))
    json.dump({"accent": "#0000FF", "background": ""}, open(os.path.join(project, "brand.json"), "w"))
    kit = brand.load(project)
    assert kit["accent"] == "#0000FF" and kit["font"] == "Impact" and "junk" not in kit
    assert kit["background"] == brand.DEFAULT["background"], "empty values must not override"
    assert brand.rgb("#0F0") == (0, 255, 0) and brand.rgb("nope") == (255, 255, 255)
    assert brand.ass_colour("#FFD700") == "&H0000D7FF" and brand.caption_font(kit) == "Impact"
    from PIL import Image
    png = os.path.join(ws, "card.png")
    visuals.card_image("Brand test", png, "9:16", brand=dict(kit, background="#004000"))
    img = Image.open(png)
    colours = {c for _, c in img.getcolors(maxcolors=1 << 20)}
    assert (0, 0, 255) in colours, "accent bar should use the brand accent"
    r, g, b = img.getpixel((10, 1900))
    assert g > 50 and r < 10 and b < 10, "background should use the brand colour"
    path = os.path.join(ws, "c.ass")
    subs.build_ass(subs.word_times("hello world", 0, 2), 1080, 1920, path, font="Impact", highlight="&H0000FF00",
                   uppercase=True)
    text = open(path, encoding="utf-8").read()
    assert "Style: Cap,Impact," in text and "&H0000FF00" in text and "HELLO" in text


# ------------------------------------------------------------------ end to end
WORK = tempfile.mkdtemp(prefix="pstudio_tests_")
ENV = None
PROJECT = os.path.join(WORK, "ws", "projects", "demo")
LIB = os.path.join(WORK, "ws", "library")
PY = sys.executable


def pipeline_run(*args, ok=0):
    return sh(PY, os.path.join(SRC, "pipeline.py"), "--project", PROJECT, *args, env=ENV, ok=ok)


@test
def e2e_index_and_style_bible():
    eps = os.path.join(WORK, "eps")
    os.makedirs(eps)
    sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=120", "-f", "lavfi",
       "-i", "sine=f=300:d=120", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", os.path.join(eps, "ep1.mp4"))
    sh(PY, os.path.join(SRC, "library.py"), "index", eps, "--lib", LIB, env=ENV)
    index = json.load(open(os.path.join(LIB, "index.json"), encoding="utf-8"))
    assert len(index["chunks"]) == 6 and all("vec" in c and c["segs"] for c in index["chunks"])
    again = sh(PY, os.path.join(SRC, "library.py"), "index", eps, "--lib", LIB, env=ENV)
    assert "already indexed" in again
    bible = os.path.join(WORK, "ws", "style-bible.md")
    sh(PY, os.path.join(SRC, "stylebible.py"), "--lib", LIB, "--out", bible, env=ENV)
    text = open(bible, encoding="utf-8").read()
    assert "## Measured" in text and "speaking words per second" in text and "## Voice and tone" in text


@test
def stacked_two_host_footage():
    import visuals
    out = os.path.join(WORK, "stack.mp4")
    kind = visuals.footage_clip(os.path.join(WORK, "eps", "ep1.mp4"), 3, out, 2.0, "9:16", audio=True,
                                layout=("stack", (0.27, 0.4), (0.72, 0.42)))
    info = sh("ffprobe", "-v", "error", "-show_entries", "stream=codec_type,width,height", "-of", "csv=p=0", out)
    assert kind == "stack" and "video,1080,1920" in info and "audio" in info, info
    assert visuals.footage_clip(os.path.join(WORK, "eps", "ep1.mp4"), 3, out, 1.0, "9:16") == "center"


@test
def e2e_prompt_to_video():
    import fake_ollama
    voice = os.path.join(WORK, "ref.wav")
    sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=f=200:d=5", voice)
    logo = os.path.join(WORK, "logo.png")
    sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=red:s=200x100", "-frames:v", "1", logo)
    json.dump({"accent": "#00C2FF", "logo": logo}, open(os.path.join(WORK, "ws", "brand.json"), "w"))
    out = pipeline_run("--stage", "outline", "--prompt", "cash flow tips", "--seconds", "32", "--voice", voice,
                       "--library", LIB)
    outline = open(os.path.join(PROJECT, "outline.txt"), encoding="utf-8").read()
    hooks = json.load(open(os.path.join(PROJECT, "hooks.json"), encoding="utf-8"))
    assert "TITLE: Cash Flow Wins" in outline and len(hooks) == 3 and f"HOOK: {hooks[0]}" in outline
    ENV["PSTUDIO_TEST_GARBLE"] = "1"   # the fake voice garbles the first take of every line
    try:
        out = pipeline_run("--stage", "all")
    finally:
        del ENV["PSTUDIO_TEST_GARBLE"]
    assert "--logo" in out, "the brand logo should be passed to the final render"
    assert "asking for a rewrite" in out, "the too-short first draft should trigger a rewrite"
    assert fake_ollama.state["schema_seen"], "script request should send a JSON schema"
    script = json.load(open(os.path.join(PROJECT, "script.json"), encoding="utf-8"))
    kinds = [s["visual"] for s in script["scenes"]]
    assert kinds.count("soundbite") == 1 and "footage" in kinds and "card" in kinds, kinds
    bite = next(s for s in script["scenes"] if s["visual"] == "soundbite")
    assert bite["narration"] == "" and bite["source"]["segs"]
    size = sh("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of",
              "csv=p=0", os.path.join(PROJECT, "final.mp4")).strip()
    assert size == "1080,1920", size
    metrics = json.load(open(os.path.join(PROJECT, "metrics.json"), encoding="utf-8"))
    assert metrics["render"]["duration_ok"] and 20 < metrics["render"]["final_seconds"] < 45, metrics["render"]
    assert metrics["voice"]["lines_retried"] and not metrics["voice"]["lines_still_unclear"], metrics["voice"]
    assert metrics["render"]["caption_seconds"] > 0.8 * metrics["render"]["final_seconds"] * 0.9
    assert "\\k" in open(os.path.join(PROJECT, "captions.ass"), encoding="utf-8").read()
    qa = json.load(open(os.path.join(PROJECT, "qa.json"), encoding="utf-8"))
    status = {c["check"]: c["status"] for c in qa["checks"]}
    assert qa["verdict"] != "FAIL", qa
    for name in ("length matches scenes", "resolution", "loudness", "caption coverage", "voice matches script"):
        assert status.get(name) == "pass", (name, qa["checks"])


def scenes_run(action, index, fields=None, ok=0):
    cmd = [PY, os.path.join(SRC, "scenes.py"), action, "--project", PROJECT, "--index", index]
    if fields is not None:
        path = os.path.join(WORK, "edit.json")
        json.dump(fields, open(path, "w"))
        cmd += ["--fields-file", path]
    return sh(*cmd, env=ENV, ok=ok)


@test
def e2e_scene_editor():
    load = lambda: json.load(open(os.path.join(PROJECT, "script.json"), encoding="utf-8"))["scenes"]  # noqa: E731
    part = lambda folder, n, ext: os.path.join(PROJECT, folder, f"scene_{n:02}{ext}")  # noqa: E731
    scenes = load()
    count = len(scenes)
    card = next(i for i, s in enumerate(scenes, 1) if s["visual"] == "card")
    foot = next(i for i, s in enumerate(scenes, 1) if s["visual"] == "footage")
    voice_time = os.path.getmtime(part("voice", card, ".wav"))
    # 1. card text only: the voice line is kept, the picture is dropped
    scenes_run("set", card, {"card_text": "Edited card"})
    assert os.path.getmtime(part("voice", card, ".wav")) == voice_time
    assert not os.path.exists(part("visuals", card, ".mp4")) and not os.path.exists(os.path.join(PROJECT, "final.mp4"))
    # 2. narration change drops the voice line too
    scenes_run("set", card, {"narration": "A brand new opening line about cash."})
    assert not os.path.exists(part("voice", card, ".wav"))
    # 3. re-make a footage scene: it must move to a different moment
    before = scenes[foot - 1]["source"]["start"]
    scenes_run("remake", foot)
    assert load()[foot - 1]["source"]["start"] != before
    # 4. validation
    assert "needs narration" in scenes_run("set", card, {"narration": ""}, ok=1)
    assert "does not exist" in scenes_run("remake", 99, ok=1)
    # 5. add then delete: files are renumbered, not re-made
    last_voice = os.path.getmtime(part("voice", count, ".wav"))
    scenes_run("add", 1)
    assert len(load()) == count + 1 and load()[1]["card_text"] == "New scene"
    assert os.path.getmtime(part("voice", count + 1, ".wav")) == last_voice and not os.path.exists(part("voice", 2, ".wav"))
    scenes_run("delete", 2)
    assert len(load()) == count and os.path.getmtime(part("voice", count, ".wav")) == last_voice
    # 6. rebuild: only the missing pieces are made again
    out = pipeline_run("--stage", "all")
    spoken = out.count("[voice ")
    assert spoken == 2, f"only the edited line and the re-made scene should be spoken again, got {spoken}"
    assert load()[card - 1]["card_text"] == "Edited card" and os.path.exists(os.path.join(PROJECT, "final.mp4"))
    qa = json.load(open(os.path.join(PROJECT, "qa.json"), encoding="utf-8"))
    assert qa["verdict"] != "FAIL", qa


@test
def e2e_resume_and_outline_edit():
    before = os.path.getmtime(os.path.join(PROJECT, "voice", "scene_01.wav"))
    out = pipeline_run("--stage", "all")
    assert "keeping it" in out and "All voice lines exist" in out
    assert os.path.getmtime(os.path.join(PROJECT, "voice", "scene_01.wav")) == before
    with open(os.path.join(PROJECT, "outline.txt"), "a", encoding="utf-8") as f:
        f.write("5. extra beat\n")
    out = pipeline_run("--stage", "script")
    assert "Outline changed" in out and not os.path.exists(os.path.join(PROJECT, "voice"))


@test
def e2e_missing_voice_is_reported():
    bad = os.path.join(WORK, "ws", "projects", "novoice")
    out = sh(PY, os.path.join(SRC, "pipeline.py"), "--project", bad, "--stage", "all", "--prompt", "x",
             "--library", LIB, env=ENV, ok=1)
    assert "No reference voice set" in out


@test
def manual_assemble_with_music_and_plain_captions():
    a, b, music, out = (os.path.join(WORK, n) for n in ("a.mp4", "b.mp4", "music.wav", "manual.mp4"))
    sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=640x360:r=25:d=3", "-f", "lavfi", "-i",
       "sine=f=400:d=3", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", a)
    sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=blue:s=1280x720:r=30:d=2", "-c:v",
       "libx264", "-preset", "ultrafast", b)  # no audio track
    sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=f=100:d=1", music)
    sh(PY, os.path.join(SRC, "assemble.py"), "--clips", a, b, "--music", music, "--captions", "--format", "16:9",
       "--out", out, env=ENV)
    d = float(sh("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", out))
    assert 4.7 < d < 5.4, d
    assert os.path.exists(os.path.splitext(out)[0] + ".srt")


@test
def powershell_static_syntax():
    try:
        import tree_sitter_powershell  # noqa: F401
    except ImportError:
        print("        (skipped: pip install tree-sitter tree-sitter-powershell)")
        return
    root = os.path.dirname(HERE)
    files = [os.path.join(root, "installer.template.ps1")] + [
        os.path.join(SRC, f) for f in sorted(os.listdir(SRC)) if f.endswith(".ps1")]
    sh(PY, os.path.join(HERE, "check_ps.py"), *files)


@test
def powershell_names_lint():
    import lint_ps
    root = os.path.dirname(HERE)
    files = [os.path.join(root, "installer.template.ps1")] + [
        os.path.join(SRC, f) for f in sorted(os.listdir(SRC)) if f.endswith(".ps1")]
    assert sum(lint_ps.lint(f) for f in files) == 0, "undefined variable or command in a PowerShell file"
    # the lint itself must catch a mistyped variable and a mistyped function
    gui = open(os.path.join(SRC, "PodcastStudio.ps1"), encoding="utf-8").read()
    broken = gui.replace("$cOutline.Text = $lines -join", "$cOutlin.Text = $lines -join", 1)
    broken = broken.replace("Load-Scenes $false", "Load-Scene $false", 1)
    assert broken != gui
    path = os.path.join(tempfile.mkdtemp(), "broken.ps1")
    open(path, "w", encoding="utf-8").write(broken)
    assert lint_ps.lint(path) == 2, "lint should report exactly the two planted mistakes"


@test
def app_smoke_test_is_wired():
    gui = open(os.path.join(SRC, "PodcastStudio.ps1"), encoding="utf-8").read()
    runner = open(os.path.join(SRC, "Test-PodcastStudio.ps1"), encoding="utf-8").read()
    assert gui.lstrip().startswith("#") and "param([switch]$SmokeTest)" in gui
    first_code = next(line for line in gui.splitlines() if line.strip() and not line.lstrip().startswith("#"))
    assert first_code.startswith("param("), "param() must be the first statement or PowerShell rejects it"
    assert "-SmokeTest" in runner and "gui-smoke.json" in gui
    assert len([line for line in gui.splitlines() if line.startswith("Check '")]) >= 9


def main():
    global ENV
    if not shutil.which("ffmpeg"):
        print("ffmpeg not found - cannot run the tests")
        return 2
    import fake_ollama
    server, url = fake_ollama.start()
    ENV = dict(os.environ, OLLAMA_HOST_URL=url, PYTHONPATH=os.path.join(HERE, "stubs"), PYTHONIOENCODING="utf-8")
    print("Podcast Studio tests")
    for fn in TESTS:  # order matters: later end-to-end tests reuse the project made by earlier ones
        run_one(fn)
    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} passed")
    server.shutdown()
    if os.environ.get("PSTUDIO_KEEP"):
        print(f"kept test files in {WORK}")
    else:
        shutil.rmtree(WORK, ignore_errors=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

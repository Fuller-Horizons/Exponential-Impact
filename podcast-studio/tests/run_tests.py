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
    sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=60", "-f", "lavfi",
       "-i", "sine=f=300:d=60", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", os.path.join(eps, "ep1.mp4"))
    sh(PY, os.path.join(SRC, "library.py"), "index", eps, "--lib", LIB, env=ENV)
    index = json.load(open(os.path.join(LIB, "index.json"), encoding="utf-8"))
    assert len(index["chunks"]) == 3 and all("vec" in c and c["segs"] for c in index["chunks"])
    again = sh(PY, os.path.join(SRC, "library.py"), "index", eps, "--lib", LIB, env=ENV)
    assert "already indexed" in again
    bible = os.path.join(WORK, "ws", "style-bible.md")
    sh(PY, os.path.join(SRC, "stylebible.py"), "--lib", LIB, "--out", bible, env=ENV)
    text = open(bible, encoding="utf-8").read()
    assert "## Measured" in text and "speaking words per second" in text and "## Voice and tone" in text


@test
def e2e_prompt_to_video():
    import fake_ollama
    voice = os.path.join(WORK, "ref.wav")
    sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=f=200:d=5", voice)
    out = pipeline_run("--stage", "outline", "--prompt", "cash flow tips", "--seconds", "32", "--voice", voice,
                       "--library", LIB)
    assert "TITLE: Cash Flow Wins" in open(os.path.join(PROJECT, "outline.txt"), encoding="utf-8").read()
    out = pipeline_run("--stage", "all")
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
    assert metrics["render"]["caption_seconds"] > 0.8 * metrics["render"]["final_seconds"] * 0.9
    assert "\\k" in open(os.path.join(PROJECT, "captions.ass"), encoding="utf-8").read()
    qa = json.load(open(os.path.join(PROJECT, "qa.json"), encoding="utf-8"))
    status = {c["check"]: c["status"] for c in qa["checks"]}
    assert qa["verdict"] != "FAIL", qa
    for name in ("length matches scenes", "resolution", "loudness", "caption coverage", "voice matches script"):
        assert status.get(name) == "pass", (name, qa["checks"])


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

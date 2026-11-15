"""Podcast Studio tests: unit checks plus a full prompt-to-video run with stand-ins for the AI models.

  python tests/run_tests.py          (needs ffmpeg, numpy, pillow; opencv optional)

The language model, voice model and speech-to-text are replaced by small fakes in tests/stubs, so this
checks the pipeline logic and the real ffmpeg render path - not the quality of the real models.
"""
import glob
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
        import traceback
        where = next((f"line {fr.lineno}" for fr in reversed(traceback.extract_tb(e.__traceback__))
                      if fr.filename == os.path.abspath(__file__)), "")
        results.append((fn.__name__, False, f"{type(e).__name__}: {e} ({where})"))
        print(f"  FAIL  {fn.__name__} at {where}: {type(e).__name__}: {e}", flush=True)


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
    seg = lambda a, b, t: {"start": a, "end": b, "text": t, "words": [[a, b, t.split()[0]]]}  # noqa: E731
    chunks = library._chunks([seg(0, 3, "intro words"), seg(3, 6, "cash flow matters"), seg(6, 9, "more cash talk"),
                              seg(9, 30, "a very long ramble"), seg(30, 33, "next chunk")])
    assert len(chunks[0][4]) == 3, "word timing is carried into each chunk"
    assert len(chunks) == 3 and len(chunks[0][3]) == 3
    chunk = {"start": 0, "end": 9, "text": "x", "segs": chunks[0][3]}
    start, secs, segs, words = library.pick_soundbite(chunk, "why cash flow matters")
    assert start == 3 and 4.0 <= secs <= 10.3 and segs[0][2] == "cash flow matters" and segs[0][0] == 0 and words == []
    start, secs, segs, words = library.pick_soundbite({"start": 9, "end": 30, "text": "a very long ramble"}, "ramble")
    assert start == 9 and secs <= 10.3 and segs[0][1] <= 10.0
    # with word timing the cut starts just before the first word and ends on the last one
    chunk["words"] = [[3.4, 3.8, "cash"], [3.8, 4.3, "flow"], [4.3, 5.2, "matters"], [6.2, 6.9, "more"], [7.0, 7.6, "cash"],
                      [7.7, 8.4, "talk"]]
    start, secs, segs, words = library.pick_soundbite(chunk, "why cash flow matters")
    assert abs(start - 3.28) < 0.01 and abs(secs - (8.4 - 3.28 + 0.2)) < 0.02, (start, secs)
    assert words[0] == [0.12, 0.52, "cash"] and words[-1][2] == "talk"


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
def framing_choices():
    import visuals
    two = [(0.30, 0.40, 0.12), (0.70, 0.42, 0.11)]
    seen, none = [two, two, two], []
    assert visuals.plan_layout(seen, True, "stack")[:2] == ("stack", (0.30, 0.40))
    assert visuals.plan_layout(seen, False, "stack")[0] == "stack", "an explicit choice applies in any shape"
    assert visuals.plan_layout(seen, True, "side") == ("side", (0.30, 0.40), (0.70, 0.42))
    assert visuals.plan_layout(seen, True, "wide") == ("wide", (0.30, 0.40), (0.70, 0.42))
    assert visuals.plan_layout(seen, True, "single-left") == ("single", (0.30, 0.40))
    assert visuals.plan_layout(seen, True, "single-right") == ("single", (0.70, 0.42))
    assert visuals.plan_layout(seen, True, "single")[0] == "single"
    # no faces found: two-host choices fall back to typical seats, single falls back to the centre
    assert visuals.plan_layout(none, True, "side") == ("side",) + visuals.ASSUMED_HOSTS
    assert visuals.plan_layout(none, True, "single-right") == ("single", visuals.ASSUMED_HOSTS[1])
    assert visuals.plan_layout(none, True, "wide") == ("wide", None, None)
    assert visuals.plan_layout(none, True, "single") == ("center",) and visuals.plan_layout(none) == ("center",)
    tall = visuals.footage_filter(1920, 1080, 1080, 1920, ("side",) + visuals.ASSUMED_HOSTS)
    assert "hstack" in tall and "boxblur" in tall and tall.count("crop=540:1152") == 2
    flat = visuals.footage_filter(1920, 1080, 1920, 1080, ("side",) + visuals.ASSUMED_HOSTS)
    assert "hstack" in flat and "boxblur" not in flat and flat.count("crop=960:1080") == 2
    wide = visuals.footage_filter(1920, 1080, 1080, 1920, ("wide", None, None))
    assert "boxblur" in wide and "scale=1080:606" in wide
    assert "boxblur" not in visuals.footage_filter(1920, 1080, 1920, 1080, ("wide", None, None))


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


@test
def speaker_timeline_logic():
    import numpy as np
    import speaker
    a, b = np.full(250, -2.0), np.full(250, -2.0)
    a[:100], b[150:] = 3, 3
    a[200:207], b[200:207] = 4, -1                      # a quarter-second interjection must not cause a cut
    shots = speaker.smooth_timeline([a, b], 10.0)
    assert [s[2] for s in shots] == [0, "both", 1] and shots[0][0] == 0.0 and shots[-1][1] == 10.0, shots
    assert abs(shots[0][1] - 4.0) < 0.2 and abs(shots[1][1] - 6.0) < 0.2
    b2 = np.full(250, -2.0)
    b2[125:] = 3                                        # a one-second gap is a hand-over, given to the next speaker
    assert [(round(s[0]), s[2]) for s in speaker.smooth_timeline([a * 0 - 2 + (np.arange(250) < 100) * 5, b2], 10.0)] == [(0, 0), (4, 1)]
    assert speaker.smooth_timeline([np.array([])], 5.0) == [(0.0, 5.0, "both")]
    tone = (np.sin(np.arange(16000) * 2 * np.pi * 220 / 16000) * 8000).astype(np.int16)
    feats = speaker.mfcc(tone)
    assert feats.shape == (99, 13) and np.isfinite(feats).all()
    assert abs(feats[10, 0] - 17.7688) < 0.01, feats[10, 0]    # log energy of the test tone, matches the reference package
    frames = np.zeros((5, 360, 640), dtype=np.uint8)
    assert speaker.face_crops(frames, (0.78, 0.49, 0.08)).shape == (5, 112, 112)
    assert speaker.face_crops(frames, (0.02, 0.02, 0.3)).shape == (5, 112, 112), "faces at the edge are padded"


@test
def publish_settings():
    import publish
    body = publish.request_body({"title": " My video ", "description": "d", "tags": "a, b ,,c", "privacy": "Unlisted", "publish_at": ""})
    assert body["snippet"]["title"] == "My video" and body["snippet"]["tags"] == ["a", "b", "c"]
    assert body["status"] == {"privacyStatus": "unlisted", "selfDeclaredMadeForKids": False}
    at = publish.schedule_time("2099-12-01 09:30")
    assert at.startswith("2099-1") and at.endswith("Z") and publish.schedule_time("") == ""
    sched = publish.request_body({"title": "t", "privacy": "private", "publish_at": "2099-12-01 09:30"})
    assert sched["status"]["publishAt"] == at
    for bad in ({"title": "", "privacy": "private"}, {"title": "x" * 101, "privacy": "private"},
                {"title": "t", "privacy": "everyone"}, {"title": "t", "privacy": "public", "publish_at": "2099-12-01 09:30"},
                {"title": "t", "privacy": "private", "publish_at": "2001-01-01 09:30"},
                {"title": "t", "privacy": "private", "publish_at": "next tuesday"}):
        try:
            publish.request_body(dict(publish.DEFAULTS, **bad))
        except SystemExit:
            continue
        raise AssertionError(f"should have been refused: {bad}")


@test
def silence_trimming_rules():
    import recording
    words = [[0.9, 1.2, "Hello"], [1.25, 2.5, "test."], [5.0, 6.3, "here"], [7.0, 7.4, "and"], [7.6, 8.0, "more."],
             [9.2, 10.0, "end."]]
    keep = recording.keep_ranges(words, 12.0)
    assert keep[0] == (0.68, 2.644), keep            # 0.22 s lead-in; a 2.5 s pause keeps a 0.24 s breath, 60% before the cut
    assert keep[1] == (4.904, 6.384), keep           # ...40% after it; then a 0.7 s mid-sentence pause keeps 0.14 s
    assert keep[2][0] == 6.944 and keep[-1][1] == 10.34 and len(keep) == 4, keep
    assert recording.keep_ranges([[1.0, 1.2, "a"], [1.6, 2.0, "b"]], 5.0) == [(0.78, 2.34)], "short pauses are left alone"
    assert recording.keep_ranges([], 5.0) == [(0.0, 5.0)]
    moved = recording.retime(words, keep)
    assert len(moved) == len(words) and moved[0][0] == 0.22 and moved[-1][2] == "end."
    assert all(b[0] >= a[1] - 0.01 for a, b in zip(moved, moved[1:])), "re-timed words stay in order"
    assert abs(moved[-1][1] - (sum(b - a for a, b in keep) - 0.34)) < 0.02
    assert recording.make_slug("C:/x/My Take #3 (final).MOV") == "my-take-3-final" and recording.make_slug("???") == "recording"
    kit = recording.kit_transcript([{"text": "Hello test.", "words": [[0.9, 1.2, "Hello"], [1.25, 2.5, "test."]]}], 3.0)
    assert kit == {"text": "Hello test.", "audio_duration_secs": 3.0,
                   "words": [{"text": "Hello", "start": 0.9, "end": 1.2}, {"text": "test.", "start": 1.25, "end": 2.5}]}
    for kind, skill in (("short", "short-form-edit"), ("long", "edit-video")):
        text = recording.prompt("my-take", kind, "/ws")
        assert skill in text and "video-projects/my-take/assets/raw.json" in text and "house-rules.md" in text
        assert "Do not call ElevenLabs" in text


@test
def model_memory_settings():
    import llm
    assert llm.context_size("x" * 400, "y" * 2000) == 4096
    assert llm.context_size("a", "b", reply_tokens=900) == 2048
    assert llm.context_size("x" * 6000, "y" * 6000) == 6144
    assert llm.context_size("x" * 40000, "y" * 40000) == 8192, "never above 8192"


@test
def encoder_choice_and_tags():
    import common
    common._encoder.clear()
    os.environ["PSTUDIO_ENCODER"] = "cpu"
    try:
        assert common.encoder()[0] == "x264"
        args = common.venc(18)
        assert args[args.index("-crf") + 1] == "18" and "libx264" in args and "comment=pstudio-enc=x264-1" in args
        assert common.enc_tag() == "pstudio-enc=x264-1"
    finally:
        del os.environ["PSTUDIO_ENCODER"]
        common._encoder.clear()
    # automatic choice: NVENC only if a real test encode works (there is no NVIDIA card here)
    kind, _ = common.encoder()
    assert kind in ("x264", "nvenc")
    cache = os.path.join(common.studio_root(), "logs", "encoder.json")
    assert os.path.exists(cache) and "nvenc" in json.load(open(cache)), "the test result is remembered"
    common._encoder.clear()


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
    assert len(index["chunks"]) == 6 and all("vec" in c and c["segs"] and c["words"] for c in index["chunks"])
    old = dict(index, chunks=[{k: v for k, v in c.items() if k != "words"} for c in index["chunks"]])
    json.dump(old, open(os.path.join(LIB, "index.json"), "w", encoding="utf-8"))
    assert "upgrading the index with word timing" in sh(PY, os.path.join(SRC, "library.py"), "index", eps, "--lib", LIB, env=ENV)
    index = json.load(open(os.path.join(LIB, "index.json"), encoding="utf-8"))
    assert all(c["words"] for c in index["chunks"])
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
def every_framing_renders():
    import visuals
    src = os.path.join(WORK, "eps", "ep1.mp4")
    expect = {"stack": "stack", "side": "side", "wide": "wide", "single": "center", "single-left": "single",
              "single-right": "single", "auto": "center"}
    for fmt, size in (("9:16", "1080,1920"), ("16:9", "1920,1080"), ("1:1", "1080,1080")):
        for choice, kind in expect.items():
            out = os.path.join(WORK, "framing.mp4")
            got = visuals.footage_clip(src, 2, out, 0.5, fmt, choice=choice)
            dims = sh("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                      "-of", "csv=p=0", out).strip()
            assert got == kind and dims == size, (fmt, choice, got, dims)


@test
def e2e_prompt_to_video():
    import fake_ollama
    voice = os.path.join(WORK, "ref.wav")
    sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=f=200:d=5", voice)
    logo = os.path.join(WORK, "logo.png")
    sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=red:s=200x100", "-frames:v", "1", logo)
    json.dump({"accent": "#00C2FF", "logo": logo}, open(os.path.join(WORK, "ws", "brand.json"), "w"))
    out = pipeline_run("--stage", "outline", "--prompt", "cash flow tips", "--seconds", "32", "--voice", voice,
                       "--library", LIB, "--framing", "side")
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
    framed = [s for s in script["scenes"] if s["visual"] in ("footage", "soundbite")]
    assert framed and all(s["framing"] == "side" and s["framing_choice"] == "side" for s in framed), framed
    bite = next(s for s in script["scenes"] if s["visual"] == "soundbite")
    assert bite["narration"] == "" and bite["source"]["segs"] and bite["source"]["words"], "soundbites carry word timing"
    size = sh("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of",
              "csv=p=0", os.path.join(PROJECT, "final.mp4")).strip()
    assert size == "1080,1920", size
    metrics = json.load(open(os.path.join(PROJECT, "metrics.json"), encoding="utf-8"))
    assert metrics["render"]["duration_ok"] and 20 < metrics["render"]["final_seconds"] < 45, metrics["render"]
    assert metrics["voice"]["lines_retried"] and not metrics["voice"]["lines_still_unclear"], metrics["voice"]
    assert metrics["render"]["scenes_copied"] >= 4, "scene pictures are reused, not re-encoded"
    assert "already match - joining without re-encoding" in out
    import fake_ollama
    assert fake_ollama.state["ctx"] and max(fake_ollama.state["ctx"]) <= 8192 and min(fake_ollama.state["ctx"]) < 8192
    assert "5m" in fake_ollama.state["keep"] and "gemma3:4b" in fake_ollama.state["unloaded"], "models are unloaded after use"
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
    # 3b. per-scene framing overrides the video's framing
    scenes_run("set", foot, {"layout": "single-left"})
    assert "Unknown framing" in scenes_run("set", foot, {"layout": "sideways"}, ok=1)
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
    edited = load()[foot - 1]
    assert edited["layout"] == "single-left" and edited["framing_choice"] == "single-left" and edited["framing"] == "single"
    others = [s for n, s in enumerate(load(), 1) if n != foot and s["visual"] in ("footage", "soundbite")]
    assert all(s["framing_choice"] == "side" for s in others), "other scenes keep the video's framing"
    # 7. changing the video's framing re-frames footage without re-recording any voice
    out = pipeline_run("--stage", "all", "--framing", "wide")
    assert out.count("[voice ") == 0 and all(s["framing"] == "wide" for s in
                                             [x for n, x in enumerate(load(), 1) if n != foot and x.get("source")])
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
def speaker_framing():
    import speaker
    import visuals
    src, out = os.path.join(WORK, "eps", "ep1.mp4"), os.path.join(WORK, "speaker.mp4")
    # no faces in the test footage: asking to follow the speaker falls back to automatic framing
    assert visuals.footage_clip(src, 2, out, 1.0, "9:16", choice="speaker") == "center"
    assert visuals.plan_layout([], True, "speaker") == ("center",)
    # with two hosts found and a speaker timeline, the picture is cut shot by shot and keeps the sound
    two = [(0.27, 0.40, 0.12), (0.73, 0.42, 0.11)]
    real = (visuals.detect_faces, speaker.timeline)
    visuals.detect_faces = lambda *a, **k: [two] * 6
    speaker.timeline = lambda src, start, seconds, boxes: [(0.0, 1.5, 0), (1.5, 2.6, "both"), (2.6, seconds, 1)]
    try:
        for fmt, size in (("9:16", "1080,1920"), ("16:9", "1920,1080")):
            assert visuals.footage_clip(src, 2, out, 4.0, fmt, audio=True, choice="speaker") == "speaker"
            info = sh("ffprobe", "-v", "error", "-show_entries", "stream=codec_type,width,height", "-show_entries",
                      "format=duration", "-of", "csv=p=0", out)
            assert f"video,{size}" in info and "audio" in info and abs(float(info.strip().splitlines()[-1]) - 4.0) < 0.25, info
        speaker.timeline = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("model missing"))
        assert visuals.footage_clip(src, 2, out, 1.0, "9:16", choice="speaker") == "stack", "falls back when the model fails"
    finally:
        visuals.detect_faces, speaker.timeline = real
    boxes = visuals.find_host_boxes([two] * 6)
    assert len(boxes) == 2 and boxes[0][0] < boxes[1][0] and len(boxes[0]) == 3
    # a "face" far below the other is not a second host (seen with real footage and the old face finder)
    assert visuals.find_hosts([[(0.54, 0.39, 0.2), (0.24, 0.83, 0.2)]] * 6)[0] is None
    assert len(visuals.find_host_boxes([[(0.54, 0.39, 0.2), (0.24, 0.83, 0.2)]] * 6)) == 1


@test
def highlights_from_an_episode():
    import highlights
    index = json.load(open(os.path.join(LIB, "index.json"), encoding="utf-8"))
    cands = highlights.passages(index["chunks"], 10, 20)
    assert cands and all(10 <= c["end"] - c["start"] <= 20.01 for c in cands) and all(c["words"] for c in cands)
    picked = highlights.choose([dict(c, score=n) for n, c in enumerate(cands)], 3)
    assert len(picked) == 3 and picked[0]["score"] == len(cands) - 1
    for a in picked:
        for b in picked:
            assert a is b or min(a["end"], b["end"]) - max(a["start"], b["start"]) <= 0.2 * (a["end"] - a["start"]) + 1e-6
    ep, out = os.path.join(WORK, "eps", "ep1.mp4"), os.path.join(WORK, "ws", "highlights")
    log = sh(PY, os.path.join(SRC, "highlights.py"), "--lib", LIB, "--episode", ep, "--out", out, "--count", "2",
             "--min", "10", "--max", "20", env=ENV)
    report = json.load(open(os.path.join(out, "ep1", "highlights.json"), encoding="utf-8"))
    clips = report["clips"]
    assert len(clips) == 2 and clips[0]["score"] == 90 and clips[0]["title"] == "Cash is king", clips
    assert clips[0]["text"].startswith("why cash") and clips[0]["score"] >= clips[1]["score"]
    for c in clips:
        info = sh("ffprobe", "-v", "error", "-show_entries", "stream=codec_type,width,height", "-of", "csv=p=0", c["file"])
        assert "video,1080,1920" in info and "audio" in info and 10 <= c["seconds"] <= 21, (info, c["seconds"])
        ass = open(os.path.splitext(c["file"])[0] + ".ass", encoding="utf-8").read()
        assert "\\k" in ass and ",Title," in ass, "clips have word captions and a headline"
    assert "not in the footage index" in sh(PY, os.path.join(SRC, "highlights.py"), "--lib", LIB, "--episode",
                                            os.path.join(WORK, "ref.wav"), "--out", out, env=ENV, ok=1)


@test
def lip_sync_is_optional():
    import lipsync
    clip, wav = os.path.join(WORK, "lip.mp4"), os.path.join(WORK, "ref.wav")
    sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=320x568:r=30:d=2", "-c:v", "libx264", clip)
    before = os.path.getsize(clip)
    assert not lipsync.available() and lipsync.sync(clip, wav) is False and os.path.getsize(clip) == before
    # a stand-in MuseTalk that just copies the picture proves the wrapper finds and installs the result
    fake = os.path.join(WORK, "FakeMuseTalk", "scripts")
    os.makedirs(fake)
    open(os.path.join(fake, "__init__.py"), "w").close()
    open(os.path.join(fake, "inference.py"), "w").write(
        "import argparse, os, re, shutil\n"
        "p = argparse.ArgumentParser()\n"
        "for a in ('inference_config', 'result_dir', 'unet_model_path', 'unet_config', 'version', 'batch_size', 'ffmpeg_path'):\n"
        "    p.add_argument('--' + a)\n"
        "p.add_argument('--use_float16', action='store_true')\n"
        "a = p.parse_args()\n"
        "cfg = open(a.inference_config).read()\n"
        "video = re.search(r'video_path: \"(.*)\"', cfg).group(1)\n"
        "assert os.path.exists(re.search(r'audio_path: \"(.*)\"', cfg).group(1))\n"
        "os.makedirs(os.path.join(a.result_dir, 'v15'))\n"
        "shutil.copy(video, os.path.join(a.result_dir, 'v15', 'synced.mp4'))\n")
    os.environ.update(PSTUDIO_MUSETALK=os.path.dirname(fake), PSTUDIO_MUSETALK_PYTHON=PY)
    try:
        assert lipsync.available() and lipsync.sync(clip, wav) is True
        fps = sh("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=r_frame_rate", "-of", "csv=p=0", clip)
        import common
        assert fps.strip() == "30/1", "lip-synced clips go back to 30 fps so scenes still join without re-encoding"
        assert common.probe(clip)["tag"] == common.enc_tag(), "the clip was replaced by the lip-synced version"
        # in a real run: only single-person footage scenes are lip-synced, and turning it on re-makes just those
        env = dict(ENV, PSTUDIO_MUSETALK=os.path.dirname(fake), PSTUDIO_MUSETALK_PYTHON=PY)
        out = sh(PY, os.path.join(SRC, "pipeline.py"), "--project", PROJECT, "--stage", "all", "--lipsync", "on",
                 "--framing", "single-left", env=env)
        scenes = json.load(open(os.path.join(PROJECT, "script.json"), encoding="utf-8"))["scenes"]
        footage = [s for s in scenes if s["visual"] == "footage" and not s.get("layout")]
        assert footage and all(s["lipsync"] and s["framing"] == "single" for s in footage), footage
        assert not any(s.get("lipsync") for s in scenes if s["visual"] != "footage"), "soundbites keep their real lips"
        assert "lip-syncing with MuseTalk" in out
        assert json.load(open(os.path.join(PROJECT, "qa.json"), encoding="utf-8"))["verdict"] != "FAIL"
    finally:
        del os.environ["PSTUDIO_MUSETALK"], os.environ["PSTUDIO_MUSETALK_PYTHON"]


@test
def model_comparison_and_publish_pack():
    ws = os.path.join(WORK, "ws")
    out = sh(PY, os.path.join(SRC, "modelbench.py"), "--workspace", ws, "--save", "--try", env=ENV)
    assert "BEST MODEL: gemma3:4b" in out and "nomic" not in out.split("Model ")[-1]
    assert json.load(open(os.path.join(ws, "settings.json")))["model"] == "gemma3:4b"
    table = json.load(open(os.path.join(ws, "model-comparison.json")))["results"]
    assert table[0]["score"] > 50 and len(table[0]["notes"]) == 2
    import publish
    sh(PY, os.path.join(SRC, "publish.py"), "pack", "--project", PROJECT, env=ENV)
    data = publish.load(PROJECT)
    assert data["title"] == "Why cash flow kills good businesses" and data["tags"] == "cash flow, small business"
    assert data["privacy"] == "private" and os.path.exists(os.path.join(PROJECT, "thumbnail.jpg"))

    class Fake:                                     # a stand-in for the YouTube API client
        calls = []

        def videos(self):
            return self

        def insert(self, **kw):
            Fake.calls.append(kw)
            return self

        def next_chunk(self):
            return None, {"id": "abc123"}
    done = publish.upload(PROJECT, Fake(), "MEDIA")
    sent = Fake.calls[0]
    assert sent["part"] == "snippet,status" and sent["media_body"] == "MEDIA"
    assert sent["body"]["status"]["privacyStatus"] == "private" and sent["body"]["snippet"]["tags"] == ["cash flow", "small business"]
    assert done["url"] == "https://youtu.be/abc123" and publish.load(PROJECT)["video_id"] == "abc123"


@test
def recording_prepare_and_quick_trim():
    import recording
    take = os.path.join(WORK, "My Take 1.mov")
    sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=640x360:r=30:d=12", "-f", "lavfi", "-i",
       "sine=f=300:d=12", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", take)
    # a stand-in kit folder (the real kit's scripts are not run by these tests)
    kit = os.path.join(WORK, "kit")
    os.makedirs(kit)
    open(os.path.join(kit, "CLAUDE.md"), "w").write("kit")
    env = dict(ENV, PSTUDIO_KIT=kit)
    out = sh(PY, os.path.join(SRC, "recording.py"), "prepare", "--recording", take, "--workspace", os.path.join(WORK, "ws"), env=env)
    project = os.path.join(kit, "video-projects", "my-take-1")
    assert "RECORDING PROJECT" in out and os.path.exists(os.path.join(project, "assets", "raw.mp4")), out
    data = json.load(open(os.path.join(project, "assets", "raw.json"), encoding="utf-8"))
    assert set(data) == {"text", "audio_duration_secs", "words"} and abs(data["audio_duration_secs"] - 12) < 0.3
    assert data["words"] and set(data["words"][0]) == {"text", "start", "end"} and data["words"][0]["start"] < data["words"][-1]["end"]
    assert "short-form-edit" in open(os.path.join(project, "prompt-short.txt")).read()
    assert "edit-video" in open(os.path.join(project, "prompt-long.txt")).read()
    again = sh(PY, os.path.join(SRC, "recording.py"), "prepare", "--recording", take, "--workspace", os.path.join(WORK, "ws"), env=env)
    assert "Transcribing" not in again, "a prepared recording is not transcribed twice"
    assert "lowercase" in sh(PY, os.path.join(SRC, "recording.py"), "prepare", "--recording", take, "--slug", "Bad Name", env=env, ok=1)
    assert "not installed" in sh(PY, os.path.join(SRC, "recording.py"), "prepare", "--recording", take,
                                 env=dict(ENV, PSTUDIO_KIT=os.path.join(WORK, "nokit")), ok=1)
    # quick trim: speech at 1-2.5 s, 5-6.3 s and 9.2-10 s of a 12 s take
    gapped = [{"text": "x", "words": [[1.0, 2.5, "Hello."], [5.0, 6.3, "there."], [9.2, 10.0, "end."]]}]
    real = recording.transcribe_words
    recording.transcribe_words = lambda *a, **k: gapped
    try:
        tight = os.path.join(WORK, "tight.mp4")
        keep = recording.tighten(take, tight)
    finally:
        recording.transcribe_words = real
    want = sum(b - a for a, b in keep)
    got = float(sh("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", tight))
    assert len(keep) == 3 and 4.0 < want < 5.2 and abs(got - want) < 0.25, (keep, got)
    streams = sh("ffprobe", "-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", tight)
    assert "video" in streams and "audio" in streams
    moved = json.load(open(os.path.join(WORK, "tight.words.json")))
    assert [w[2] for w in moved] == ["Hello.", "there.", "end."] and moved[-1][1] <= got + 0.1


@test
def social_posts_house_rules_and_music():
    import brand
    import pipeline
    ws = os.path.join(WORK, "ws")
    open(os.path.join(ws, "house-rules.md"), "w").write("# House rules\n\n- Never say 'game changer'.\n")
    guide = pipeline.style_bible(PROJECT)
    assert guide.startswith("HOUSE RULES") and "game changer" in guide and "## Voice and tone" in guide
    system, _ = pipeline.script_request("TITLE: x", 30, ["card"], guide)
    assert "game changer" in system, "house rules reach the script writer"
    out = sh(PY, os.path.join(SRC, "repurpose.py"), "--project", PROJECT, env=ENV)
    social = os.path.join(PROJECT, "social")
    assert "SOCIAL POSTS" in out and "runway" in open(os.path.join(social, "linkedin.txt")).read()
    thread = open(os.path.join(social, "x-thread.txt")).read()
    assert thread.startswith("1/3  You run out of cash") and "3/3" in thread, "blank thread posts are dropped"
    slides = sorted(f for f in os.listdir(social) if f.startswith("slide_"))
    assert slides == ["slide_01.png", "slide_02.png", "slide_03.png"], "slides without a headline are dropped"
    from PIL import Image
    assert Image.open(os.path.join(social, "slide_01.png")).size == (1080, 1350)
    assert "Slide 2: Hire late" in open(os.path.join(social, "carousel.txt")).read()
    # a music bed set in the brand kit is used by the render
    music = os.path.join(WORK, "bed.wav")
    sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=f=110:d=3", music)
    kit = json.load(open(os.path.join(ws, "brand.json")))
    json.dump(dict(kit, music=music), open(os.path.join(ws, "brand.json"), "w"))
    assert brand.load(PROJECT)["music"] == music
    assert "--music" in pipeline_run("--stage", "render"), "the brand kit's music bed should reach the render"
    json.dump(kit, open(os.path.join(ws, "brand.json"), "w"))
    os.remove(os.path.join(ws, "house-rules.md"))


@test
def youtube_import_command():
    import ytimport
    cmd = ytimport.command("https://youtu.be/abc", "/eps", 3)
    assert cmd[0] == "yt-dlp" and cmd[-1] == "https://youtu.be/abc" and cmd[cmd.index("--playlist-end") + 1] == "3"
    assert "--download-archive" in cmd and any("height<=1080" in c for c in cmd)
    assert "full YouTube link" in sh(PY, os.path.join(SRC, "ytimport.py"), "--url", "abc", "--dest", WORK, "--lib", LIB, env=ENV, ok=1)
    if not shutil.which("yt-dlp"):
        assert "yt-dlp is not installed" in sh(PY, os.path.join(SRC, "ytimport.py"), "--url", "https://youtu.be/abc", "--dest",
                                               WORK, "--lib", LIB, env=ENV, ok=1)


@test
def chunked_transcription_and_resume():
    import common
    import faster_whisper
    src = os.path.join(WORK, "long.wav")
    sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=f=220:d=75", src)
    cache = os.path.join(WORK, "long.partial.json")
    os.environ["PSTUDIO_CHUNK_SECONDS"] = "20"
    try:
        faster_whisper.CALLS.clear()
        segs = common.transcribe_words(src, cache=cache)
        pieces = len(faster_whisper.CALLS)
        assert pieces >= 3, "a 75 s recording with 20 s pieces is done in several pieces"
        starts = [s["start"] for s in segs]
        assert starts == sorted(starts) and len(set(starts)) == len(starts), "no piece is transcribed twice"
        assert all(b["start"] >= a["end"] - 0.01 for a, b in zip(segs, segs[1:])), "pieces join without overlaps"
        assert segs[0]["start"] < 1 and segs[-1]["end"] > 74, (segs[0], segs[-1])
        assert all(w[0] >= s["start"] - 0.01 and w[1] <= s["end"] + 0.01 for s in segs for w in s["words"])
        state = json.load(open(cache))
        assert state["next"] >= 74.5 and len(state["segments"]) == len(segs)
        # an interrupted run carries on: pretend it stopped after 40 s
        state["segments"] = [s for s in state["segments"] if s["end"] <= 40]
        state["next"] = 40.0
        json.dump(state, open(cache, "w"))
        faster_whisper.CALLS.clear()
        again = common.transcribe_words(src, cache=cache)
        assert len(faster_whisper.CALLS) < pieces, "finished pieces are not redone"
        assert [s["start"] for s in again] == starts, "the resumed transcript matches the full one"
        # short recordings are done in one go, as before
        faster_whisper.CALLS.clear()
        short = os.path.join(WORK, "short.wav")
        sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=f=220:d=12", short)
        common.transcribe_words(short)
        assert len(faster_whisper.CALLS) == 1
    finally:
        del os.environ["PSTUDIO_CHUNK_SECONDS"]


@test
def piece_by_piece_cutting():
    import recording
    src = os.path.join(WORK, "cutme.mp4")
    sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=640x360:r=30:d=20", "-f", "lavfi", "-i",
       "sine=f=300:d=20", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", src)
    out = os.path.join(WORK, "cut.mp4")
    recording.render_pieces(src, [(1.0, 4.5), (6.0, 6.01), (8.0, 12.0), (15.5, 19.0)], out)
    info = sh("ffprobe", "-v", "error", "-show_entries", "stream=codec_type,codec_name:format=duration", "-of", "csv=p=0", out)
    assert "video" in info and "aac,audio" in info, info
    assert abs(float(info.strip().splitlines()[-1]) - 11.0) < 0.15, info
    keep = os.path.join(WORK, "keep.json")
    for data in ([[1, 3], [5, 7]], [{"start": 5, "end": 7}, {"start": 1, "end": 3}], {"keep": [[1, 3], [5, 7]]}):
        json.dump(data, open(keep, "w"))
        assert recording.read_keep(keep) == [(1.0, 3.0), (5.0, 7.0)]
    out2 = os.path.join(WORK, "cut2.mp4")
    log = sh(PY, os.path.join(SRC, "recording.py"), "render", "--video", src, "--keep", keep, "--out", out2, env=ENV)
    assert "RENDERED" in log and abs(float(sh("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of",
                                               "default=nw=1:nk=1", out2)) - 4.0) < 0.15
    json.dump({"keep": []}, open(keep, "w"))
    assert "No kept ranges" in sh(PY, os.path.join(SRC, "recording.py"), "render", "--video", src, "--keep", keep,
                                  "--out", out2, env=ENV, ok=1)
    text = recording.prompt("talk", "long", "/ws")
    assert "recording.py" in text and "render --video" in text and "trim/atrim" in text
    tight = recording.prompt("talk", "short", "/ws", tightened=True)
    assert "silenced.mp4" in tight and "skip the cut-silences render" in tight


@test
def split_long_recording_and_join():
    import recording
    take = os.path.join(WORK, "Long Talk.mp4")
    sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=320x180:r=30:d=330", "-f", "lavfi", "-i",
       "sine=f=300:d=330", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", take)
    kit = os.path.join(WORK, "kit2")
    os.makedirs(kit)
    open(os.path.join(kit, "CLAUDE.md"), "w").write("kit")
    env = dict(ENV, PSTUDIO_KIT=kit)
    out = sh(PY, os.path.join(SRC, "recording.py"), "split", "--recording", take, "--slug", "long-talk", "--minutes", "2",
             "--tighten", "--workspace", os.path.join(WORK, "ws"), env=env)
    parts = sorted(glob.glob(os.path.join(kit, "video-projects", "long-talk-part-*")))
    assert len(parts) == 3 and "PARTS: 3" in out, out
    total = 0.0
    for p in parts:
        raw = os.path.join(p, "assets", "raw.mp4")
        secs = float(sh("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", raw))
        total += secs
        words = json.load(open(os.path.join(p, "assets", "raw.json")))["words"]
        assert words and words[0]["start"] >= 0 and words[-1]["end"] <= secs + 0.1
        assert os.path.exists(os.path.join(p, "assets", "silenced.mp4")) and os.path.exists(os.path.join(p, "assets", "silenced.json"))
        assert "silenced.mp4" in open(os.path.join(p, "prompt-short.txt")).read()
    assert abs(total - 330) < 1.0, total
    assert "not been rendered yet" in sh(PY, os.path.join(SRC, "recording.py"), "join", "--slug", "long-talk", env=env, ok=1)
    for p in parts:                                   # stand in for Claude Code's renders
        shutil.copy(os.path.join(p, "assets", "raw.mp4"), os.path.join(p, "renders", "edit.mp4"))
    out = sh(PY, os.path.join(SRC, "recording.py"), "join", "--slug", "long-talk", env=env)
    joined = os.path.join(kit, "video-projects", "long-talk-joined.mp4")
    assert "JOINED" in out and abs(float(sh("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of",
                                            "default=nw=1:nk=1", joined)) - 330) < 1.5
    assert recording.split_points([[0, 1, "a"]], 100.0, 8) == [(0.0, 100.0)], "short recordings are not split"


@test
def working_copies_of_4k_footage():
    import visuals
    big = os.path.join(WORK, "big.mp4")
    sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=2560x1440:r=30:d=3", "-f", "lavfi", "-i",
       "sine=f=300:d=3", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", big)
    assert visuals.needs_proxy(big) and not visuals.needs_proxy(os.path.join(WORK, "eps", "ep1.mp4"))
    assert visuals.working_copy(big) == big
    proxy = visuals.make_proxy(big)
    size = sh("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", proxy)
    assert size.strip() == "1920,1080" and visuals.working_copy(big) == proxy
    assert visuals.make_proxy(big) == proxy, "made once, then reused"
    assert visuals.make_proxy(os.path.join(WORK, "eps", "ep1.mp4")) is None, "1080p and smaller footage is used as is"
    out = os.path.join(WORK, "fromproxy.mp4")
    assert visuals.footage_clip(big, 0.5, out, 1.0, "9:16") in ("center", "single")
    assert sh("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of",
              "csv=p=0", out).strip() == "1080,1920"


@test
def optional_services_per_project():
    import services
    ws = os.path.join(WORK, "ws")
    proj = os.path.join(ws, "projects", "svc")
    os.makedirs(proj, exist_ok=True)
    open(os.path.join(proj, "prompt.txt"), "w").write("why cash flow matters")
    import connections
    # nothing connected yet: no service can be switched on or used
    assert "is not connected" in sh(PY, os.path.join(SRC, "services.py"), "set", "--project", proj, "--on", "vidiq", env=ENV, ok=1)
    assert "NOT CONNECTED" in services.block(proj)
    conn = connections.load()
    for k in ("higgsfield", "vidiq", "drive"):
        conn["services"][k] = {"connected": True, "detail": "test", "checked": "2026-11-15 10:00"}
    connections.save(conn)
    cfg = services.load(proj)
    assert not any(cfg["services"].values()), "every service starts off"
    rules = services.block(proj)
    assert "Higgsfield: OFF" in rules and "vidIQ: OFF" in rules and "Before every paid call" not in rules
    for kind in services.TASKS:
        try:
            services.task(proj, kind, scene=1, language="spa")
        except SystemExit:
            continue
        raise AssertionError(f"{kind} must refuse while its service is off")
    # defaults, then a project override
    sh(PY, os.path.join(SRC, "services.py"), "set", "--project", proj, "--on", "vidiq", "--cap-vidiq", "30", "--default", env=ENV)
    other = os.path.join(ws, "projects", "other")
    os.makedirs(other, exist_ok=True)
    assert services.load(other)["services"]["vidiq"], "the default applies to new projects"
    sh(PY, os.path.join(SRC, "services.py"), "set", "--project", other, "--off", "vidiq", env=ENV)
    assert not services.load(other)["services"]["vidiq"] and services.load(proj)["services"]["vidiq"]
    rules = services.block(proj)
    assert "vidIQ: allowed, up to 30 credits for this project (0 already used)" in rules and "Before every paid call" in rules
    assert "only connected to Claude" in services.block(proj, "codex")
    path = services.task(proj, "ideas")
    text = open(path).read()
    assert "vidiq_keyword_research" in text and "ideas.md" in text and "why cash flow matters" in text and "up to 30" in text
    # spending is read back from the log and stops new tasks at the cap
    with open(os.path.join(proj, "services-log.md"), "w") as f:
        f.write("- 2026-11-15 vidiq vidiq_outliers: 5 credits - ideas\n- 2026-11-15 vidiq vidiq_score_title: 25 credits - titles\n"
                "- 2026-11-15 drive copy: 0 credits - x\n")
    assert services.spent(proj) == {"higgsfield": 0, "vidiq": 30}
    assert "used 30 of its 30" in sh(PY, os.path.join(SRC, "services.py"), "task", "--project", proj, "--kind", "ideas", env=ENV, ok=1)
    # Higgsfield B-roll for a real project scene, and dubbing
    sh(PY, os.path.join(SRC, "services.py"), "set", "--project", PROJECT, "--on", "higgsfield", "drive", env=ENV)
    broll = open(services.task(PROJECT, "broll", scene=1)).read()
    assert "get_cost" in broll and "generated" in broll and "scenes.py" in broll and "--index 1" in broll
    assert "soundbite" in sh(PY, os.path.join(SRC, "services.py"), "task", "--project", PROJECT, "--kind", "broll", "--scene",
                             str(next(i for i, s in enumerate(json.load(open(os.path.join(PROJECT, "script.json")))["scenes"], 1)
                                      if s["visual"] == "soundbite")), env=ENV, ok=1)
    assert "final.spa.mp4" in open(services.task(PROJECT, "dub", language="spa")).read()
    # a generated clip replaces one scene's picture and keeps its voice
    clip = os.path.join(WORK, "generated.mp4")
    sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=1080x1920:r=30:d=2", "-c:v", "libx264", clip)
    card = next(i for i, s in enumerate(json.load(open(os.path.join(PROJECT, "script.json")))["scenes"], 1) if s["visual"] == "card")
    voice = os.path.join(PROJECT, "voice", f"scene_{card:02}.wav")
    before = os.path.getmtime(voice)
    fields = os.path.join(WORK, "clip.json")
    json.dump({"clip": clip}, open(fields, "w"))
    sh(PY, os.path.join(SRC, "scenes.py"), "set", "--project", PROJECT, "--index", str(card), "--fields-file", fields, env=ENV)
    s = json.load(open(os.path.join(PROJECT, "script.json")))["scenes"][card - 1]
    assert s["visual"] == "footage" and s["generated"] and s["source"]["file"] == clip and os.path.getmtime(voice) == before
    assert "[voice " not in pipeline_run("--stage", "all"), "the voice line is kept"
    # Google Drive: a plain copy into a synced folder
    assert "Choose your Google Drive folder" in sh(PY, os.path.join(SRC, "services.py"), "drive", "--project", PROJECT, env=ENV, ok=1)
    drive = os.path.join(WORK, "GoogleDrive")
    os.makedirs(drive)
    sh(PY, os.path.join(SRC, "services.py"), "set", "--project", PROJECT, "--drive-folder", drive, env=ENV)
    sh(PY, os.path.join(SRC, "services.py"), "drive", "--project", PROJECT, env=ENV)
    copied = os.listdir(os.path.join(drive, "demo"))
    assert "final.mp4" in copied and "social" in copied, copied
    assert services.spent(PROJECT)["higgsfield"] == 0, "Drive copies cost nothing"
    sh(PY, os.path.join(SRC, "services.py"), "set", "--project", PROJECT, "--off", "higgsfield", "drive", env=ENV)
    os.remove(os.path.join(services.workspace(), "settings.json"))     # drop the test's default
    # disconnecting a service turns it off everywhere, even where a project had it on
    sh(PY, os.path.join(SRC, "services.py"), "set", "--project", proj, "--on", "vidiq", env=ENV)
    conn = connections.load()
    conn["services"]["vidiq"]["connected"] = False
    connections.save(conn)
    assert not services.load(proj)["services"]["vidiq"] and services.load(proj, raw=True)["services"]["vidiq"]
    assert "vidIQ: NOT CONNECTED" in services.block(proj)
    assert "is not connected" in sh(PY, os.path.join(SRC, "services.py"), "task", "--project", proj, "--kind", "ideas", env=ENV, ok=1)
    os.remove(connections.path())


@test
def settings_connection_checks():
    import connections
    listing = ("Checking MCP server health...\n\nclaude.ai Higgsfield: https://mcp.example/h - \u2714 Connected\n"
               "claude.ai vidIQ for Claude: https://mcp.example/v - ! Needs authentication\n"
               "claude.ai Gmail: https://mcp.example/g - \u2714 Connected\n")
    found = connections.parse_mcp_list(listing)
    assert found["higgsfield"][0] and not found["vidiq"][0] and "sign-in" in found["vidiq"][1]
    assert not connections.parse_mcp_list("claude.ai vidIQ: https://x - \u2717 Failed to connect")["vidiq"][0]
    assert connections.parse_mcp_list("nothing relevant") == {}
    # folder services: connect, check, disconnect
    drive = os.path.join(WORK, "DriveForDesktop")
    os.makedirs(drive, exist_ok=True)
    sh(PY, os.path.join(SRC, "connections.py"), "folder", "--service", "drive", "--path", drive, env=ENV)
    assert connections.connected("drive") and connections.load()["folders"]["drive"] == os.path.abspath(drive)
    assert "Folder not found" in sh(PY, os.path.join(SRC, "connections.py"), "folder", "--service", "riverside", "--path",
                                    os.path.join(WORK, "nope"), env=ENV, ok=1)
    sh(PY, os.path.join(SRC, "connections.py"), "clear", "--service", "drive", env=ENV)
    assert not connections.connected("drive") and "drive" not in connections.load()["folders"]
    # a full check runs without Claude Code, Codex or YouTube installed and reports each as not connected
    out = sh(PY, os.path.join(SRC, "connections.py"), "check", env=ENV)
    data = connections.load()["services"]
    assert set(data) == set(connections.SERVICES) and "Claude Code" in out
    assert data["ollama"]["connected"], "the test language-model server counts as connected"
    os.remove(connections.path())


@test
def riverside_separate_tracks():
    import multitrack
    import visuals
    folder = os.path.join(WORK, "riverside", "Episode 12")
    os.makedirs(folder)
    # two people recorded on their own tracks: host talks 0-4 s, guest talks 5-9 s
    for name, start in (("Jonathan_Smith-raw-20261115.mp4", 0), ("Guest_Person-raw-20261115.mp4", 5)):
        sh("ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=10", "-f", "lavfi",
           "-i", f"sine=f=330:d=10,volume='between(t,{start},{start + 4})':eval=frame", "-c:v", "libx264", "-preset", "ultrafast",
           "-c:a", "aac", os.path.join(folder, name))
    episodes = os.path.join(WORK, "ws", "rs-episodes")
    out = sh(PY, os.path.join(SRC, "multitrack.py"), "import", "--folder", folder, "--name", "episode-12",
             "--episodes", episodes, env=ENV)
    video = os.path.join(episodes, "episode-12.mp4")
    assert "EPISODE" in out and "Jonathan Smith" in out and "Guest Person" in out
    info = sh("ffprobe", "-v", "error", "-show_entries", "stream=codec_type,width,height", "-of", "csv=p=0", video)
    assert "video,1920,1080" in info and "audio" in info
    side = json.load(open(video + ".speakers.json"))
    names = side["speakers"]
    host, guest = names.index("Jonathan Smith"), names.index("Guest Person")
    tl = [(a, b, w) for a, b, w in side["timeline"]]
    talking = {w: sum(b - a for a, b, x in tl if x == w) for w in (host, guest)}
    assert 3.0 < talking[host] < 5.5 and 3.0 < talking[guest] < 5.5, tl
    assert next(w for a, b, w in tl if a <= 2 < b) == host and next(w for a, b, w in tl if a <= 7 < b) == guest, tl
    # framing uses the recorded timing, not face detection
    clip = os.path.join(WORK, "rs-speaker.mp4")
    assert visuals.footage_clip(video, 0, clip, 9.0, "9:16", audio=True, choice="speaker") == "speaker"
    assert visuals.footage_clip(video, 1, clip, 2.0, "9:16", choice="side") == "side"
    assert visuals.sidecar_shots(side, 1.0, 2.0)[0][2] == host
    assert "Found 1 video track" in sh(PY, os.path.join(SRC, "multitrack.py"), "import", "--folder",
                                       os.path.join(WORK, "eps"), "--name", "x", "--episodes", episodes, env=ENV, ok=1)
    assert multitrack.speaker_name("zaka_creative_video_a1b2c3d4e5.mov") == "zaka creative"


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
    # keep logs, caches and working copies inside the test folder, not the repository
    os.environ.update(PSTUDIO_ROOT=WORK, PSTUDIO_PROXIES=os.path.join(WORK, "proxies"), OLLAMA_HOST_URL=url,
                      PSTUDIO_YUNET=os.path.join(os.path.dirname(HERE), "models", "face_detection_yunet_2023mar.onnx"))
    ENV = dict(os.environ, PYTHONPATH=os.path.join(HERE, "stubs"), PYTHONIOENCODING="utf-8")
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

"""Embed src/* into installer.template.ps1 -> Setup-PodcastStudio.ps1 (single self-contained file)."""
import pathlib
import subprocess
import sys

here = pathlib.Path(__file__).parent

if "--no-test" not in sys.argv:  # never ship an installer whose tests fail
    code = subprocess.run([sys.executable, str(here / "tests" / "run_tests.py")]).returncode
    if code == 2:
        print("WARNING: tests skipped (ffmpeg missing)")
    elif code:
        raise SystemExit("Tests failed - installer not built. (--no-test to override)")

order = ["PodcastStudio.ps1", "Test-PodcastStudio.ps1", "common.py", "llm.py", "library.py", "visuals.py",
         "subs.py", "brand.py", "speaker.py", "lipsync.py", "tts.py", "pipeline.py", "scenes.py", "highlights.py",
         "assemble.py", "qa.py", "stylebible.py", "modelbench.py", "publish.py", "captions.py",
         "extract_voice.py", "fal_generate.py", "selftest.py", "CLAUDE.md"]
missing = {p.name for p in (here / "src").iterdir() if p.is_file()} - set(order)
assert not missing, f"not embedded: {missing}"
blocks = []
for name in order:
    text = (here / "src" / name).read_text(encoding="utf-8").replace("\r\n", "\n")
    for i, line in enumerate(text.split("\n"), 1):
        if line.startswith("'@"):
            raise SystemExit(f"{name}:{i} starts with '@ - would break the here-string")
    blocks.append(f"$files['{name}'] = @'\n{text.rstrip()}\n'@")

# small binary files (the face-detector model) travel inside the installer as base64
import base64
import textwrap

binaries = []
for rel in ["models/face_detection_yunet_2023mar.onnx"]:
    data = base64.b64encode((here / rel).read_bytes()).decode("ascii")
    binaries.append(f"$binaries['{rel.replace('/', chr(92))}'] = @'\n" + "\n".join(textwrap.wrap(data, 120)) + "\n'@")

tpl = (here / "installer.template.ps1").read_text(encoding="utf-8")
assert tpl.count("#__FILES__") == 1 and tpl.count("#__BINARIES__") == 1
out = tpl.replace("#__FILES__", "\n".join(blocks)).replace("#__BINARIES__", "\n".join(binaries))
# Windows PowerShell 5.1 reads BOM-less files as ANSI; write UTF-8 with BOM and CRLF.
(here / "Setup-PodcastStudio.ps1").write_bytes(b"\xef\xbb\xbf" + out.replace("\n", "\r\n").encode("utf-8"))
print("wrote Setup-PodcastStudio.ps1", len(out), "chars")

"""Embed src/* into installer.template.ps1 -> Setup-PodcastStudio.ps1 (single self-contained file)."""
import pathlib

here = pathlib.Path(__file__).parent
order = ["PodcastStudio.ps1", "common.py", "extract_voice.py", "tts.py",
         "fal_generate.py", "captions.py", "assemble.py", "CLAUDE.md"]
blocks = []
for name in order:
    text = (here / "src" / name).read_text(encoding="utf-8").replace("\r\n", "\n")
    for i, line in enumerate(text.split("\n"), 1):
        if line.startswith("'@"):
            raise SystemExit(f"{name}:{i} starts with '@ - would break the here-string")
    blocks.append(f"$files['{name}'] = @'\n{text.rstrip()}\n'@")

tpl = (here / "installer.template.ps1").read_text(encoding="utf-8")
assert tpl.count("#__FILES__") == 1
out = tpl.replace("#__FILES__", "\n".join(blocks))
# Windows PowerShell 5.1 reads BOM-less files as ANSI; write UTF-8 with BOM and CRLF.
(here / "Setup-PodcastStudio.ps1").write_bytes(b"\xef\xbb\xbf" + out.replace("\n", "\r\n").encode("utf-8"))
print("wrote Setup-PodcastStudio.ps1", len(out), "chars")

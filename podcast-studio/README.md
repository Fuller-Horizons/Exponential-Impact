# Podcast Studio

Local Windows pipeline: analyze podcast videos → clone the host's voice → generate clips on fal.ai → assemble with captions.
Built for a 4 GB NVIDIA GPU + 16 GB RAM: voice cloning (Qwen3-TTS 0.6B) and transcription run locally; Wan / LatentSync run on fal.ai.

## Install (one command)
Download `Setup-PodcastStudio.ps1`, then in a normal PowerShell window:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\Setup-PodcastStudio.ps1"
```

Options: `-Root D:\PodcastStudio`, `-SkipModels`, `-SkipClaude`, `-CpuOnly`. Re-running updates everything.

## GUI tabs
1. **Analyze** – frames + captions (claude-video `watch`), faster-whisper transcripts, "Ask Claude: build style bible".
2. **Voice clone** – cut a 8–15 s sample from a URL/file, then speak any script in that voice.
3. **Cloud video (fal.ai)** – any fal endpoint: LatentSync lip-sync (video + audio) or Wan image-to-video (image + prompt).
4. **Assemble** – ordered clips + voiceover + music → 9:16 / 16:9 / 1:1 MP4 with burned-in captions, or hand off to HyperFrames via Claude Code.

## Development
Edit files in `src/` and the installer template, then run `python build.py` to regenerate `Setup-PodcastStudio.ps1`.

# Podcast Studio

Windows app that turns a prompt into a short video in your podcast's style, running entirely on your PC
(4 GB NVIDIA GPU, 16 GB RAM).

## Install (one command)
Download `Setup-PodcastStudio.ps1`, then in a normal PowerShell window:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\Setup-PodcastStudio.ps1"
```

Options: `-Root D:\PodcastStudio`, `-Model gemma3:4b`, `-WithStills`, `-SkipModels`, `-SkipClaude`, `-CpuOnly`, `-Upgrade`.
The installer ends with a self-test and writes `logs\selftest.json`.

## Create tab: prompt to video
1. **Index footage** once: point it at the folder of episode videos.
2. Type the topic, press **Draft outline**. A local language model (Ollama) writes it.
3. Edit the outline, press **Approve + make video**. Stages: script and shot list, cloned voice per scene,
   a visual per scene (matching episode footage, text card, or optional AI still), then render with captions.
4. If a stage fails, press step 2 again: finished work is kept. Editing the outline rebuilds everything after it.

Each video lives in `workspace\projects\<name>\`; `metrics.json` records timings and peak VRAM.

## Other tabs
Analyze (frames, transcripts), Voice clone (make the reference sample), Assemble (manual edit), and an
optional fal.ai tab for cloud clips. Claude Code buttons are optional extras.

## Pinned versions
Upstream repos are checked out at fixed commits and Python packages are pinned; the first install writes
`requirements.lock` and re-runs reuse it. `-Upgrade` moves to the latest.

## Development
Edit files in `src/` or `installer.template.ps1`, then run `python build.py` to regenerate the installer.

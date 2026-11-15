# Podcast Studio

Windows app that turns a prompt into a short video in your podcast's style, running entirely on your PC
(4 GB NVIDIA GPU, 16 GB RAM).

## Install (one command)
Download `Setup-PodcastStudio.ps1`, then in a normal PowerShell window:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\Setup-PodcastStudio.ps1"
```

Options: `-Root D:\PodcastStudio`, `-Model gemma3:4b`, `-WithStills`, `-SkipModels`, `-SkipClaude`, `-CpuOnly`, `-Upgrade`,
and `-CheckOnly` to inspect the PC and network without installing. Every run saves `logs\install-<time>.log`.
The installer ends with a self-test and writes `logs\selftest.json`. The self-test also opens the app
invisibly, builds every tab and dialog, exercises the main buttons' logic and a background job, and writes
`logs\gui-smoke.json` (`Test-PodcastStudio.ps1 -NoGui` skips this).

## Create tab: prompt to video
1. **Index footage** once: point it at the folder of episode videos.
2. Type the topic, press **Draft outline**. A local language model (Ollama) writes it.
3. Edit the outline, press **Approve + make video**. Stages: script and shot list, cloned voice per scene,
   a visual per scene, render, then a quality gate. Scene types: a real soundbite from an episode (own sound,
   up to two per video), silent episode footage cropped around the speaker's face, a text card, or an optional
   AI still. Captions highlight word by word; audio is normalised and music is lowered under speech.
4. If a stage fails, press step 2 again: finished work is kept. Editing the outline rebuilds everything after it.

**Framing** sets how episode footage is shown: Auto, Stacked (one host above the other), Side by side (split
screen), Both in frame (the whole two-shot), One person (the larger face), Left person or Right person. The
Scenes tab can override it for a single scene.

The outline step offers three hooks to pick from. **Brand kit...** sets the show's colours, font and logo once
(`workspace\brand.json`). Garbled voice lines are detected and re-made automatically, up to twice.

## Scenes tab: fix one scene
Load the project's scenes, change a scene's type, narration, search words or card text, and press **Save scene**.
**Apply changes + re-make video** rebuilds only what changed. **Re-make this scene** gives a new voice take and,
for footage or soundbites, the next best matching moment. Scenes can be added or deleted.

Each video lives in `workspace\projects\<name>\`; `metrics.json` records timings and peak VRAM, and
`qa.json` holds the quality report. **Build style bible (local)** in the Analyze tab writes
`workspace\style-bible.md` from the indexed episodes; the outline and script steps read it.

## Highlights tab: clips straight from an episode
Choose an indexed episode. The local model rates passages of the transcript, and the best ones are cut into
finished clips with the hosts' own sound, word captions and a headline. **Active speaker** framing cuts to
whoever is talking, using the LR-ASD model on the CPU.

## Publish tab
**Write title + description (local)** drafts them from the script. **Upload to YouTube** sends the finished
video with your own Google sign-in, private by default, optionally scheduled. Nothing leaves the PC until you
press Upload and confirm. It needs a one-time OAuth "Desktop app" sign-in file from Google Cloud Console.

## Optional extras
- `-WithWhisperX`: more exact word timing, and who-said-what labels when the `HF_TOKEN` environment variable is set.
- `-WithLipSync`: MuseTalk re-syncs a single host's lips to the narration (tick **Lip-sync**). Slow on a 4 GB card.
- **Compare local models** (Analyze tab) tests each installed model on two scripts and makes the best the default.

## Other tabs
Analyze (frames, transcripts), Voice clone (make the reference sample), Assemble (manual edit), and an
optional fal.ai tab for cloud clips. Claude Code buttons are optional extras.

## Pinned versions
Upstream repos are checked out at fixed commits and Python packages are pinned; the first install writes
`requirements.lock` and re-runs reuse it. `-Upgrade` moves to the latest.

## Development
Edit files in `src/` or `installer.template.ps1`, then run `python build.py`. It runs `tests/run_tests.py`
(unit tests plus a full prompt-to-video run with stand-ins for the AI models, and a static PowerShell
syntax check) and only then regenerates the installer.

# Podcast Studio

Windows app that turns a prompt into a short video in your podcast's style, running entirely on your PC
(4 GB NVIDIA GPU, 16 GB RAM).

## Install (one file)
Download **`Install-PodcastStudio.cmd`** and double-click it. If Windows shows "Windows protected your PC", press
**More info > Run anyway** (the file is not code-signed). It unpacks the PowerShell installer to `%TEMP%`, runs it with
`-ExecutionPolicy Bypass` for that run only, and waits for a key press at the end. It is plain text: open it in
Notepad to read exactly what it does. Options can be added from a command prompt: `Install-PodcastStudio.cmd -WithCodex`.

The same installer as a PowerShell file, for those who prefer it:

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

## Edit recording tab: the hybrid part
Record yourself, then:
1. **Prepare** copies the recording into the [Herk Edit Kit](https://github.com/nateherkai/herk-edit-kit)
   (MIT, by Nate Herk) and transcribes it on this PC, word by word, in the kit's format.
2. **Edit with Claude Code** opens Claude Code in the kit with a prompt you can read and change. Claude then
   cuts silences and mistakes, plans the story, and builds captions and motion graphics with the kit's skills.

Claude Code is a cloud model and uses your Claude subscription: the transcript and editing decisions go to
Claude, the video files stay on this PC. **Quick trim (no AI)** removes dead air locally and needs no model.

**House rules** (`workspace\house-rules.md`) are lasting corrections. Add one from the Scenes tab or by telling
Claude Code a note during an edit; every later script, edit and social post follows them.

## Highlights tab: clips straight from an episode
Choose an indexed episode. The local model rates passages of the transcript, and the best ones are cut into
finished clips with the hosts' own sound, word captions and a headline. **Active speaker** framing cuts to
whoever is talking, using the LR-ASD model on the CPU.

## Publish tab
**Write title + description (local)** drafts them from the script. **Upload to YouTube** sends the finished
video with your own Google sign-in, private by default, optionally scheduled. Nothing leaves the PC until you
press Upload and confirm. It needs a one-time OAuth "Desktop app" sign-in file from Google Cloud Console.

**Write social posts (local)** drafts a LinkedIn post, an X thread and 4:5 carousel slides into the project's
`social` folder. **Polish with Claude Code** sharpens them. They are drafts: nothing is posted for you.

## Optional extras
- `-WithWhisperX`: more exact word timing, and who-said-what labels when a Hugging Face token is saved (setup wizard).
- `-WithLipSync`: MuseTalk re-syncs a single host's lips to the narration (tick **Lip-sync**). Slow on a 4 GB card.
- **Download + index (YouTube)** (Analyze tab) downloads your own videos into `workspace\episodes` and indexes them.
- A **music bed** set in the Brand kit plays under every video, lowered while someone speaks.
- **Compare local models** (Analyze tab) tests each installed model on two scripts and makes the best the default.

## Other tabs
Analyze (frames, transcripts), Voice clone (make the reference sample), Assemble (manual edit), and an
optional fal.ai tab for cloud clips. Claude Code buttons are optional extras.

## Profiles: one per show or persona
The **Profile** list at the top of the window switches everything that defines a show at once: brand kit
(colours, font, logo, music bed), style bible, house rules, voice samples, footage library, projects,
YouTube sign-in, which services are on by default, and the settings new videos start with.
- **New...** makes a profile, empty or as a copy of the current one's setup.
- **Save as profile defaults** stores the Create tab's length, shape, framing, model, soundbites, stills,
  lip-sync, voice sample and episode folder; every new video in that profile starts from them.
- **Export...** / **Import...** move a profile's setup (not its footage, videos or sign-ins) as one .zip.
- **Archive...** sets a profile aside; its folder is moved to `profiles\_archived`, never deleted.
Connections in the Settings tab are shared by every profile, except YouTube, which each profile signs in to.
The original `workspace` folder is the first profile, "Main"; new profiles live in `profiles\<name>`.

**Simple mode** (top right) shows only Create, Edit recording, Highlights and Publish.

## Setup wizard (first start)
The first time the app opens, a wizard walks through each optional connection: Claude Code, Higgsfield and vidIQ
(through claude.ai), Codex, YouTube upload, the Google Drive and Riverside folders, the fal.ai key and Hugging Face
token, and a first profile. Every step can be skipped. Open it again with **Settings > Setup wizard...**.

## Keys and sign-ins are encrypted on this PC
- The fal.ai key, the Hugging Face token and each profile's YouTube sign-in file and sign-in are encrypted with
  Windows DPAPI for the current Windows user (`shared\secrets\*.dat`, `<profile>\secrets\*.dat`). Another Windows
  account, or a copy of the files on another PC, cannot decrypt them.
- Keys are typed into a hidden box and handed only to the app's own process; they are not stored in environment
  variables, profile exports or logs. Older plain-text copies (the `FAL_KEY` user variable, `youtube_*.json`) are
  moved into encrypted storage and deleted automatically.
- Claude Code, Codex and claude.ai (Higgsfield, vidIQ) keep their own sign-ins; the app never sees those passwords.
- DPAPI protects against other accounts and stolen files, not against programs running as you.

## Settings tab: connect services once
Each outside service is connected here, once for the whole app: **Connect**, **Disconnect** and **Check all**.
Higgsfield and vidIQ are connected on claude.ai (the button opens that page) and checked through Claude Code;
Codex signs in with your ChatGPT plan; YouTube signs in with your Google account (kept encrypted); Google Drive and Riverside
are folders on this PC. A service that is not connected cannot be ticked for a project or chosen as the
editor, and every agent prompt names it as unavailable.

**Riverside (optional).** Download a session's separate tracks (one video per person) into a folder and press
**Import Riverside session...**. The app builds one episode with the people side by side, mixes their sound,
and works out who speaks when from each person's own audio. That timing is exact, so **Active speaker**
framing and Highlights use it instead of guessing from faces. Each person's track is also a clean source for a
voice sample. No Riverside account connection is needed; its API is limited to the Business plan.

## Optional services (all off unless you switch them on)
The **Services** tab switches outside services on per project, with a credit cap for each paid one. Nothing in
the app needs them; switched-off services are named in every Claude Code prompt as not allowed.
- **Higgsfield** (Claude only): generated B-roll for a scene, dubbing into 18 languages.
- **vidIQ** (Claude only): topic ideas, title scores and a thumbnail, a music bed.
- **Google Drive**: copies finished files into a folder that Google Drive for desktop syncs. No connector needed.
- **Codex** (installer `-WithCodex`): choose it as the editor in the Edit recording tab; it signs in with your
  ChatGPT plan. It cannot use Higgsfield or vidIQ, which are connected to Claude.

Each paid step quotes its cost and waits for a yes, and every paid call is written to the project's
`services-log.md`. Caps are instructions Claude follows, not limits the services themselves enforce.

## Built for a modest PC (i7, 16 GB RAM, 4 GB graphics card)
- **Long recordings are cut piece by piece.** One ffmpeg filter graph with many cuts went past 13 GB on a
  10-minute 1080p test and was killed; one piece at a time stays under 0.5 GB. Claude Code is told to use the
  same method (`recording.py render`).
- **Split long recordings** (Edit recording tab) into parts of about 8 minutes at natural pauses; each part is
  edited and rendered on its own, then **Join edited parts** puts them back together.
- **Transcription runs in 10-minute pieces** and resumes where it stopped if the PC is interrupted.
- **4K footage gets a 1080p working copy** when it is indexed (once). Measured: cutting a 5 s scene 2.7 s -> 1.3 s,
  scanning for faces 5.5 s -> 0.8 s. Turn off with `"proxies": false` in `workspace\settings.json`.
- **Finished scenes are not re-encoded again.** A 50-second video's final render went from about 45 s to about 20 s.
- **NVENC:** if the graphics card's video encoder works, encoding moves off the CPU (tested once, remembered in
  `logs\encoder.json`). Force the CPU with `"encoder": "cpu"` in `workspace\settings.json`.
- **The language model gets only the memory it needs** (a smaller conversation window, an 8-bit cache, flash
  attention) and is unloaded before the voice model or AI stills need the card.

## Pinned versions
Upstream repos are checked out at fixed commits and Python packages are pinned; the first install writes
`requirements.lock` and re-runs reuse it. `-Upgrade` moves to the latest.

## Guide
The step-by-step guide installs with the app: press **Guide** at the bottom of the window, or use the
**Podcast Studio Guide** desktop shortcut. It works offline. Its source is `guide/guide.html` (the same file is
published online); `build.py` turns it into the stand-alone `app\guide.html`.

## Development
Edit files in `src/` or `installer.template.ps1`, then run `python build.py`. It runs `tests/run_tests.py`
(unit tests plus a full prompt-to-video run with stand-ins for the AI models, and a static PowerShell
syntax check) and only then regenerates `Setup-PodcastStudio.ps1` and `Install-PodcastStudio.cmd` (`cmdwrap.py`).

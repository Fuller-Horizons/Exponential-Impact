# Podcast Studio workspace

This folder is one **profile** (a show or persona). Its brand kit, style bible, house rules, voice samples,
library and projects belong to this show only; other profiles live in other folders.

Local pipeline that turns a prompt into a short video in the podcast's style.
Hardware: 4 GB GeForce GPU, 16 GB RAM. The Create flow makes no cloud calls.

## Layout
- `projects/<name>/` - one folder per video: `project.json`, `outline.txt`, `script.json`, `voice/`, `visuals/`, `scenes/`, `captions.ass`, `final.mp4`, `metrics.json`, `qa.json`
- `library/index.json` - searchable transcript index of the episode footage
- `voice/` - reference voice samples (`*.wav` + matching `*.txt` transcript)
- `analysis/` - frames + transcripts from the watch skill and faster-whisper
- `style-bible.md` - the show's distilled style; the outline and script stages read it when present
- `house-rules.md` - lasting corrections. Read it before any script, edit or post and follow every rule. When the user gives a note about an edit, add it here as one short rule.
- `brand.json` - colours, font, logo and optional music bed for cards, captions and the corner logo (a project can hold its own copy)

## Tools (Python = `..\venv\Scripts\python.exe`, scripts in `..\app\`)
- Whole pipeline: `python ..\app\pipeline.py --project projects\x --stage outline --prompt "..."`, edit `outline.txt`, then `--stage all`
- One stage: `--stage script|voice|visuals|render|qa` (add `--force` to redo it)
- Style bible: `python ..\app\stylebible.py --lib library --out style-bible.md`
- Quality gate: `python ..\app\qa.py --project projects\x`
- Prepare a raw recording for the Herk Edit Kit: `python ..\app\recording.py prepare --recording take.mp4 --slug my-take` (kit lives in `..\repos\herk-edit-kit`; edit there with its `short-form-edit` or `edit-video` skill)
- Quick silence trim, no AI: `python ..\app\recording.py tighten --recording take.mp4`
- Social posts from a project: `python ..\app\repurpose.py --project projects\x` (drafts in `projects\x\social`)
- Import your own YouTube videos: `python ..\app\ytimport.py --url <link> --dest episodes --lib library`
- Highlights (clips cut straight from an episode): `python ..\app\highlights.py --lib library --episode <file> --out highlights --count 5 --framing speaker`
- Who is speaking: `python ..\app\speaker.py <video> --start 10 --seconds 8` (LR-ASD, CPU)
- Compare local models and set the default: `python ..\app\modelbench.py --workspace . --save`
- Publish: `python ..\app\publish.py pack --project projects\x`, then `upload` (the YouTube sign-in is kept encrypted in `secrets\`; set it up in Settings)
- Edit one scene: `python ..\app\scenes.py set|remake|add|delete --project projects\x --index N [--fields-file edit.json]`, then `--stage all`
- Index footage: `python ..\app\library.py index <folder> --lib library`
- Voice sample: `python ..\app\extract_voice.py <url|file> --start MM:SS --duration 12 --outdir voice --name host`
- One visual: `python ..\app\visuals.py card "Text" --out clips\c.mp4 --seconds 4`
- Assemble by hand: `python ..\app\assemble.py --clips a.mp4 b.mp4 --voice v.wav --format 9:16 --captions --out output\final.mp4`
- Self-test: `powershell -File ..\app\Test-PodcastStudio.ps1 [-Full] [-NoGui]` (includes the invisible app smoke test: `PodcastStudio.ps1 -SmokeTest`)
- Optional cloud clip (off by default): `python ..\app\fal_generate.py --endpoint <fal id> ...`

## Connections (Settings tab)
- `python ..\app\connections.py check` saves which services are connected in `connections.json`. A service that is not connected must not be used.
- Riverside separate tracks: `python ..\app\multitrack.py import --folder <tracks> --name <episode> --episodes episodes --lib library`
  writes `<episode>.mp4` plus `<episode>.mp4.speakers.json` (who speaks when, from each person's own audio), used by Active speaker framing.

## Outside services (optional, per project)
- Before using Higgsfield, vidIQ or any other outside service, read the project's rules: `python ..\app\services.py block --project <project folder>`.
  A service that is off must not be used. Allowed services have a credit cap: quote each cost, wait for a yes, and log every paid call in the project's `services-log.md`.
- Nothing in this app requires a service. If one fails or is off, use the local way.
- A ready-made clip can replace a scene's picture: `scenes.py set --index N --fields-file f.json` with `{"clip": "<path>"}`.

## Memory (this PC: 16 GB RAM, 4 GB graphics card)
- Never render cuts with one ffmpeg filter graph of many trim/atrim filters: it ran out of memory on a 10-minute
  1080p test. Use `python ..\app\recording.py render --video in.mp4 --keep keep.json --out out.mp4`
  (keep.json = [[start, end], ...] in seconds); it renders one piece at a time.
- Split recordings longer than about 15 minutes: `recording.py split --recording x.mp4 --slug name --minutes 8`,
  edit each part, then `recording.py join --slug name`.
- Only one GPU model at a time: Ollama is unloaded before the voice model, AI stills or lip-sync start.
- `workspace\settings.json`: `"encoder": "auto|cpu|nvenc"`, `"proxies": true|false`, `"model": "<default model>"`.

## Rules
- Never read, print, copy or decrypt files in `secrets\` or `..\shared\secrets\` (encrypted keys and sign-ins). Never ask the user to paste a key into chat.
- Only clone voices of people who have consented.
- Nothing is uploaded anywhere unless `publish.py upload` is run; uploads default to private.
- `script.json` scenes: `narration`, `visual` (soundbite | footage | card | still), `query`, `card_text`, `image_prompt`, `source`.
- A soundbite plays a real episode clip with its own sound (max 2 per video); other scenes use the cloned voice.
- Captions are built from the script and measured timings, not from speech recognition.
- The outline step writes `hooks.json` (three opening lines); the `HOOK:` line in `outline.txt` is the one used.
- New voice lines are listened back to on the CPU and re-made up to twice if garbled (`--voice-check off` to skip).
- Footage framing: `--framing auto|stack|side|wide|single|single-left|single-right|speaker` for the video, or a scene's `layout` to override it. auto = stacked when two hosts are found in a vertical video, else one person.
- `speaker` cuts to whoever is talking (two hosts on screen needed); it falls back to auto if that fails.
- Faces are found with the YuNet model in `..\models`; the footage index stores word-level timing (`words`).
- `--lipsync on` re-syncs a single host's lips to the narration with MuseTalk when it is installed (slow).
- If two faces cannot be found for a two-host framing, typical seat positions (27% and 73% of the width) are assumed.
- Models run one at a time (each stage is its own process) so 4 GB of VRAM is enough.

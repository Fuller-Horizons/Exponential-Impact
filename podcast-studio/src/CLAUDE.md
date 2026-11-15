# Podcast Studio workspace

Local pipeline for turning podcast episodes into new short videos. Hardware: 4 GB GeForce GPU, 16 GB RAM.
Heavy video generation is offloaded to fal.ai (pay per second); everything else runs locally.

## Layout
- `analysis/` - frames + transcripts from the watch skill and faster-whisper
- `voice/` - reference voice samples (`*.wav` + matching `*.txt` transcript)
- `scripts/` - narration scripts
- `clips/` - generated or source clips
- `output/` - finished videos
- `style-bible.md` - the show's distilled style (create it from `analysis/`)

## Tools (Python = `..\venv\Scripts\python.exe`, scripts in `..\app\`)
- Analyze: `python ..\repos\claude-video\skills\watch\scripts\watch.py <url|file> --engine local --detail balanced --out-dir analysis`
- Transcribe: `python ..\app\captions.py <file> --out analysis\<name>`
- Voice sample: `python ..\app\extract_voice.py <url|file> --start MM:SS --duration 12 --outdir voice --name host`
- Voiceover: `python ..\app\tts.py --script scripts\x.txt --ref-audio voice\host.wav --ref-text voice\host.txt --out output\x.wav`
- Cloud clip: `python ..\app\fal_generate.py --endpoint <fal id> --prompt "..." --image frame.png [--video v.mp4 --audio a.wav] --out clips\x.mp4`
- Assemble: `python ..\app\assemble.py --clips a.mp4 b.mp4 --voice output\x.wav --format 9:16 --captions --out output\final.mp4`
- Motion graphics / kinetic captions: use the `/hyperframes` skill (`hyperframes` CLI, Node 22+).

## Rules
- Only clone voices of people who have consented.
- Keep `FAL_KEY` in the user environment, never in files.
- Before generating, read `style-bible.md` and match hooks, pacing, length and caption style.

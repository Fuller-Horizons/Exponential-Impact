"""Optional lip-sync: make one host's mouth match the narration, using MuseTalk (MIT licence) in its own environment.

MuseTalk is installed only with the installer's -WithLipSync switch. On a 4 GB card its authors report about
five minutes for an eight-second clip, so this is slow and off by default.
"""
import os
import shutil
import subprocess
import tempfile

from common import FF, duration, log, studio_root


def repo_dir():
    return os.environ.get("PSTUDIO_MUSETALK") or os.path.join(studio_root(), "repos", "MuseTalk")


def python_exe():
    cand = [os.environ.get("PSTUDIO_MUSETALK_PYTHON"),
            os.path.join(studio_root(), "venv-musetalk", "Scripts", "python.exe"),
            os.path.join(studio_root(), "venv-musetalk", "bin", "python")]
    return next((c for c in cand if c and os.path.exists(c)), None)


def available():
    repo = repo_dir()
    return bool(python_exe()) and os.path.exists(os.path.join(repo, "scripts", "inference.py")) and (
        os.path.exists(os.path.join(repo, "models", "musetalkV15", "unet.pth")) or bool(os.environ.get("PSTUDIO_MUSETALK_PYTHON")))


def sync(video, audio, timeout=3600):
    """Replace `video` with a version whose lips follow `audio`. Returns True if it worked; the original is kept if not."""
    if not available():
        log("  lip-sync is not installed (run the installer with -WithLipSync)")
        return False
    repo, tmp = repo_dir(), tempfile.mkdtemp(prefix="pstudio_lip_")
    try:
        src = os.path.join(tmp, "in.mp4")       # MuseTalk expects 25 fps
        subprocess.run(FF + ["-i", video, "-vf", "fps=25", "-an", "-c:v", "libx264", "-preset", "veryfast",
                             "-crf", "18", src], check=True)
        cfg = os.path.join(tmp, "task.yaml")
        with open(cfg, "w", encoding="utf-8") as f:
            f.write("task_0:\n"
                    f" video_path: \"{src.replace(os.sep, '/')}\"\n"
                    f" audio_path: \"{os.path.abspath(audio).replace(os.sep, '/')}\"\n"
                    " result_name: \"synced.mp4\"\n")
        ffmpeg_dir = os.path.dirname(shutil.which("ffmpeg") or "")
        cmd = [python_exe(), "-m", "scripts.inference", "--inference_config", cfg, "--result_dir", tmp,
               "--unet_model_path", os.path.join("models", "musetalkV15", "unet.pth"),
               "--unet_config", os.path.join("models", "musetalkV15", "musetalk.json"),
               "--version", "v15", "--use_float16", "--batch_size", "4", "--ffmpeg_path", ffmpeg_dir]
        log("  lip-syncing with MuseTalk (slow on a 4 GB card)...")
        done = subprocess.run(cmd, cwd=repo, capture_output=True, text=True, timeout=timeout)
        result = os.path.join(tmp, "v15", "synced.mp4")
        if done.returncode != 0 or not os.path.exists(result) or duration(result) < 0.3:
            log("  lip-sync failed - keeping the original picture: " + (done.stderr or done.stdout or "no output")[-300:].strip())
            return False
        subprocess.run(FF + ["-i", result, "-an", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                             "-pix_fmt", "yuv420p", video + ".sync.mp4"], check=True)
        os.replace(video + ".sync.mp4", video)
        return True
    except Exception as e:  # noqa: BLE001 - lip-sync is a bonus, never a blocker
        log(f"  lip-sync failed - keeping the original picture: {e}")
        return False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

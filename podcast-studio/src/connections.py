"""Which outside services are set up on this PC. Settings tab -> Connect / Disconnect / Check.

  python connections.py check                         check every service and save workspace/connections.json
  python connections.py folder --service drive|riverside --path <folder>   connect a folder-based service
  python connections.py clear  --service drive|riverside|youtube|fal       disconnect one

A service that is not connected cannot be switched on for a project (services.py enforces this) and is
named as unavailable in every agent prompt. Checks are best effort: Claude Code's own connector list is
known to misreport some connectors, so a service can still fail at the moment it is used.
"""
import argparse
import datetime
import os
import shutil
import subprocess

from common import fail, log, read_json, studio_root, write_json

SERVICES = {
    "claude": "Claude Code",
    "higgsfield": "Higgsfield (Claude connector)",
    "vidiq": "vidIQ (Claude connector)",
    "codex": "Codex (ChatGPT)",
    "youtube": "YouTube upload",
    "drive": "Google Drive folder",
    "riverside": "Riverside exports folder",
    "fal": "fal.ai (cloud video)",
    "ollama": "Ollama (local model)",
}
CONNECTOR_PAGE = "https://claude.ai/settings/connectors"


def workspace():
    """The profile in use (YouTube sign-in is per profile, so each show can post to its own channel)."""
    from common import workspace_dir
    return workspace_dir()


def path():
    """Connections are shared by every profile: they belong to your accounts, not to a show."""
    from common import shared_dir
    new = os.path.join(shared_dir(), "connections.json")
    old = os.path.join(studio_root(), "workspace", "connections.json")
    if not os.path.exists(new) and os.path.exists(old):      # carry over a check made before profiles existed
        os.makedirs(shared_dir(), exist_ok=True)
        shutil.copy2(old, new)
    return new


def load():
    data = read_json(path(), {}) or {}
    data.setdefault("services", {})
    data.setdefault("folders", {})
    return data


def save(data):
    p = path()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    write_json(p, data)


def connected(service, data=None):
    data = data or load()
    return bool((data["services"].get(service) or {}).get("connected"))


def _run(cmd, timeout=90):
    exe = shutil.which(cmd[0])
    if not exe:
        return None, ""
    try:
        done = subprocess.run([exe] + cmd[1:], capture_output=True, text=True, timeout=timeout)
        return done.returncode, (done.stdout or "") + (done.stderr or "")
    except (OSError, subprocess.TimeoutExpired) as e:
        return -1, str(e)


def parse_mcp_list(text):
    """Status of the connectors we care about, from `claude mcp list` output.

    Lines look like "claude.ai vidIQ for Claude: https://... - ✔ Connected" or "... - ! Needs authentication"
    or "... - ✗ Failed to connect". Returns {"higgsfield": (connected, detail), "vidiq": (...)} for those found.
    """
    found = {}
    for line in text.splitlines():
        low = line.lower()
        for key in ("higgsfield", "vidiq"):
            if key in low.replace(" ", "") and key not in found:
                if "needs auth" in low:
                    found[key] = (False, "needs sign-in on claude.ai")
                elif "fail" in low or "✗" in line or "error" in low:
                    found[key] = (False, "failed to connect")
                elif "connected" in low or "✓" in line or "✔" in line or "√" in line:
                    found[key] = (True, "connected through your Claude account")
                else:
                    found[key] = (False, "status unknown")
    return found


def check_claude(result):
    code, out = _run(["claude", "--version"], timeout=30)
    if code is None:
        result["claude"] = (False, "not installed")
        result["higgsfield"] = result["vidiq"] = (False, "needs Claude Code")
        return
    code, out = _run(["claude", "mcp", "list"], timeout=120)
    if code != 0:
        result["claude"] = (False, "installed; run claude once to sign in")
        result["higgsfield"] = result["vidiq"] = (False, "needs Claude Code signed in")
        return
    signed_in = "claude.ai" in out.lower()
    result["claude"] = (True, "installed" + (" and signed in" if signed_in else "; sign in to see your connectors"))
    found = parse_mcp_list(out)
    for key in ("higgsfield", "vidiq"):
        result[key] = found.get(key, (False, "not connected on claude.ai"))


def check_codex(result):
    code, out = _run(["codex", "login", "status"], timeout=30)
    if code is None:
        result["codex"] = (False, "not installed (installer -WithCodex)")
    elif code == 0:
        mode = "ChatGPT plan" if "chatgpt" in out.lower() else "signed in"
        result["codex"] = (True, f"signed in ({mode})")
    else:
        result["codex"] = (False, "installed; not signed in")


def check_youtube(result):
    import json

    import secretstore
    secretstore.migrate(workspace())
    client = secretstore.load("youtube_client", workspace())
    token = secretstore.load("youtube_token", workspace())
    if not client:
        result["youtube"] = (False, "no sign-in file yet")
        return
    if not token:
        result["youtube"] = (False, "sign-in file saved; not signed in")
        return
    try:
        from google.auth.transport.requests import Request
        from google.oauth2.credentials import Credentials
        creds = Credentials.from_authorized_user_info(json.loads(token), ["https://www.googleapis.com/auth/youtube.upload"])
        if not creds.valid and creds.refresh_token:
            creds.refresh(Request())
            secretstore.save("youtube_token", creds.to_json(), workspace())
        result["youtube"] = (bool(creds.valid), "signed in (kept encrypted)" if creds.valid else "sign-in expired")
    except ImportError:
        result["youtube"] = (True, "signed in (not re-checked)")
    except Exception as e:  # noqa: BLE001 - revoked or expired token
        result["youtube"] = (False, f"sign-in no longer works ({str(e)[:60]})")


def check_folder(result, key, data):
    folder = data["folders"].get(key, "")
    if not folder:
        result[key] = (False, "no folder chosen")
    elif not os.path.isdir(folder):
        result[key] = (False, f"folder missing: {folder}")
    elif not os.access(folder, os.W_OK):
        result[key] = (False, f"cannot write to {folder}")
    else:
        result[key] = (True, folder)


def check_fal(result):
    import secretstore
    key = secretstore.has("fal") or bool(os.environ.get("FAL_KEY"))
    result["fal"] = (key, "key saved, encrypted (checked when used)" if key else "no key")


def check_ollama(result):
    try:
        import llm
        if not llm.server_up():
            result["ollama"] = (False, "not running (it starts when needed)")
            return
        names = [m for m in llm.models() if "embed" not in m]
        result["ollama"] = (bool(names), ", ".join(names[:3]) or "no chat model downloaded")
    except Exception as e:  # noqa: BLE001
        result["ollama"] = (False, str(e)[:60])


def check(only=None):
    data = load()
    result = {}
    if only in (None, "claude", "higgsfield", "vidiq"):
        check_claude(result)
    if only in (None, "codex"):
        check_codex(result)
    if only in (None, "youtube"):
        check_youtube(result)
    for key in ("drive", "riverside"):
        if only in (None, key):
            check_folder(result, key, data)
    if only in (None, "fal"):
        check_fal(result)
    if only in (None, "ollama"):
        check_ollama(result)
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    for key, (ok, detail) in result.items():
        data["services"][key] = {"connected": ok, "detail": detail, "checked": stamp}
        log(f"  [{'connected' if ok else 'not connected':13}] {SERVICES[key]}: {detail}")
    save(data)
    return data


def set_folder(service, folder):
    if service not in ("drive", "riverside"):
        fail("Only Google Drive and Riverside are connected with a folder.")
    folder = os.path.abspath(folder)
    if not os.path.isdir(folder):
        fail(f"Folder not found: {folder}")
    data = load()
    data["folders"][service] = folder
    save(data)
    check(service)


def clear(service):
    data = load()
    if service in ("drive", "riverside"):
        data["folders"].pop(service, None)
    elif service == "youtube":
        import secretstore
        secretstore.clear("youtube_token", workspace())
        legacy = os.path.join(workspace(), "youtube_token.json")
        if os.path.exists(legacy):
            os.remove(legacy)
    elif service == "fal":
        import secretstore
        secretstore.clear("fal")
    elif service not in SERVICES:
        fail(f"Unknown service '{service}'.")
    data["services"][service] = {"connected": False, "detail": "disconnected in Settings",
                                 "checked": datetime.datetime.now().strftime("%Y-%m-%d %H:%M")}
    save(data)
    log(f"{SERVICES[service]} disconnected.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["check", "folder", "clear"])
    ap.add_argument("--service")
    ap.add_argument("--path")
    a = ap.parse_args()
    if a.action == "check":
        check(a.service)
    elif a.action == "folder":
        if not (a.service and a.path):
            fail("folder needs --service and --path")
        set_folder(a.service, a.path)
    else:
        if not a.service:
            fail("clear needs --service")
        clear(a.service)


if __name__ == "__main__":
    main()

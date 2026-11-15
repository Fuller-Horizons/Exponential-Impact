"""Keys and sign-ins kept encrypted on this PC with Windows DPAPI (current user).

A file holds "dpapi1:<base64>": only the same Windows user on the same PC can decrypt it. The app's own
PowerShell code (Protect-Secret / Unprotect-Secret) writes the same format with the same extra entropy.
Off Windows (tests only) the text is stored as "plain1:<base64>", which is NOT encrypted, and a warning is shown.

  python secretstore.py set --name fal            value read from standard input (never the command line)
  python secretstore.py has --name fal            prints yes / no
  python secretstore.py clear --name fal
  python secretstore.py import-file --name youtube_client --file client_secret.json --delete
  python secretstore.py migrate                    moves old plain-text sign-ins into encrypted files

Shared secrets (every profile): fal, hf.  Per-profile secrets: youtube_client, youtube_token.
"""
import argparse
import base64
import os
import sys

from common import fail, log, shared_dir, workspace_dir

ENTROPY = b"PodcastStudio.v1"
SHARED = ("fal", "hf")
PER_PROFILE = ("youtube_client", "youtube_token", "selftest")   # selftest: the app smoke test checks PowerShell <-> Python
LEGACY = {"youtube_client": "youtube_client_secret.json", "youtube_token": "youtube_token.json"}
_warned = []


def _windows():
    return os.name == "nt"


def _blob(data):
    import ctypes
    from ctypes import wintypes

    class BLOB(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]
    buf = ctypes.create_string_buffer(data, len(data))
    return BLOB(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char))), buf, BLOB


def _dpapi(data, protect):
    import ctypes
    crypt32, kernel32 = ctypes.windll.crypt32, ctypes.windll.kernel32
    src, _keep, BLOB = _blob(data)
    ent, _keep2, _ = _blob(ENTROPY)
    out = BLOB()
    fn = crypt32.CryptProtectData if protect else crypt32.CryptUnprotectData
    ok = fn(ctypes.byref(src), None, ctypes.byref(ent), None, None, 0x1, ctypes.byref(out))  # 0x1 = no UI
    if not ok:
        raise OSError("Windows could not " + ("encrypt" if protect else "decrypt") +
                      " the secret (it was saved by another Windows user or PC).")
    try:
        return ctypes.string_at(out.pbData, out.cbData)
    finally:
        kernel32.LocalFree(out.pbData)


def protect(text):
    data = text.encode("utf-8")
    if _windows():
        return "dpapi1:" + base64.b64encode(_dpapi(data, True)).decode("ascii")
    if not _warned:
        _warned.append(1)
        print("WARNING: not on Windows - secrets are stored without encryption (test use only).", file=sys.stderr)
    return "plain1:" + base64.b64encode(data).decode("ascii")


def unprotect(stored):
    kind, _, body = (stored or "").strip().partition(":")
    raw = base64.b64decode(body)
    if kind == "dpapi1":
        if not _windows():
            raise OSError("This secret was encrypted on Windows and can only be read there.")
        return _dpapi(raw, False).decode("utf-8")
    if kind == "plain1":
        return raw.decode("utf-8")
    raise ValueError("Not a Podcast Studio secret file.")


def path(name, workspace=None):
    if name in SHARED:
        return os.path.join(shared_dir(), "secrets", name + ".dat")
    if name in PER_PROFILE:
        return os.path.join(workspace or workspace_dir(), "secrets", name + ".dat")
    fail(f"Unknown secret '{name}'.")


def save(name, text, workspace=None):
    p = path(name, workspace)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="ascii") as f:
        f.write(protect(text))
    os.replace(tmp, p)
    return p


def load(name, workspace=None):
    """The secret's text, or None when it is not saved (or cannot be decrypted)."""
    p = path(name, workspace)
    if not os.path.exists(p):
        return None
    try:
        with open(p, encoding="ascii") as f:
            stored = f.read()
        text = unprotect(stored)
        if stored.startswith("plain1:") and _windows():      # upgrade a test-format file on Windows
            save(name, text, workspace)
        return text
    except (OSError, ValueError) as e:
        log(f"Could not read the saved {name} secret: {e}")
        return None


def has(name, workspace=None):
    return load(name, workspace) is not None


def clear(name, workspace=None):
    p = path(name, workspace)
    if os.path.exists(p):
        os.remove(p)


def import_file(name, src, delete=False, workspace=None):
    with open(src, encoding="utf-8") as f:
        text = f.read()
    save(name, text, workspace)
    if delete:
        os.remove(src)
    return text


def migrate(workspace=None):
    """Move plain-text sign-ins left by older versions into encrypted files, then delete the plain copies."""
    ws = workspace or workspace_dir()
    moved = []
    for name, legacy in LEGACY.items():
        old = os.path.join(ws, legacy)
        if os.path.exists(old):
            if not has(name, ws):
                import_file(name, old, workspace=ws)
            os.remove(old)
            moved.append(legacy)
    fal = os.environ.get("FAL_KEY")
    if fal and not has("fal"):
        save("fal", fal)
        moved.append("FAL_KEY")
    return moved


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["set", "has", "clear", "import-file", "migrate"])
    ap.add_argument("--name")
    ap.add_argument("--file")
    ap.add_argument("--delete", action="store_true")
    ap.add_argument("--workspace")
    a = ap.parse_args()
    if a.action == "migrate":
        moved = migrate(a.workspace)
        log("Moved into encrypted storage: " + (", ".join(moved) if moved else "nothing to move"))
        return
    if not a.name:
        fail("--name is required")
    if a.action == "set":
        value = sys.stdin.read().strip()
        if not value:
            fail("No value given.")
        save(a.name, value, a.workspace)
        log(f"Saved {a.name} (encrypted).")
    elif a.action == "has":
        print("yes" if has(a.name, a.workspace) else "no")
    elif a.action == "clear":
        clear(a.name, a.workspace)
        log(f"Removed {a.name}.")
    else:
        if not a.file:
            fail("--file is required")
        import_file(a.name, a.file, a.delete, a.workspace)
        log(f"Saved {a.name} (encrypted).")


if __name__ == "__main__":
    main()

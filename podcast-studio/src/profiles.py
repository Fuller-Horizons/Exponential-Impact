"""Profiles: one per show or persona. Each keeps its own brand kit, style bible, house rules, voice sample,
footage library, projects, YouTube sign-in and defaults for new videos. Connections to outside services are
shared by all profiles.

  python profiles.py list
  python profiles.py create --name "Second Show" [--copy-from Main]   new profile (optionally copying a setup)
  python profiles.py switch --name "Second Show"
  python profiles.py export --name Main --out main-profile.zip         the setup only: no footage or videos
  python profiles.py import --file main-profile.zip [--name "Main copy"]
  python profiles.py archive --name "Old Show"                         set aside (moved, never deleted)
"""
import argparse
import datetime
import json
import os
import re
import shutil
import zipfile

from common import fail, log, profiles_file, read_json, studio_root, write_json

SETUP_FILES = ("brand.json", "style-bible.md", "house-rules.md", "settings.json", "profile.json")
SETUP_DIRS = ("voice",)
SUBFOLDERS = ("analysis", "voice", "scripts", "clips", "output", "frames", "projects", "library", "episodes",
              "highlights", "music", "assets")
NEVER_EXPORT = ("youtube_token.json", "youtube_client_secret.json", "secrets")   # sign-ins stay on this PC


def registry():
    reg = read_json(profiles_file(), None)
    if not isinstance(reg, dict) or not reg.get("profiles"):
        legacy = os.path.join(studio_root(), "workspace")
        reg = {"current": "Main", "profiles": {"Main": legacy}}
    return reg


def save_registry(reg):
    os.makedirs(os.path.dirname(profiles_file()), exist_ok=True)
    write_json(profiles_file(), reg)


def folder(name):
    reg = registry()
    if name not in reg["profiles"]:
        fail(f"There is no profile called '{name}'. Profiles: {', '.join(reg['profiles'])}")
    return reg["profiles"][name]


def check_name(name):
    name = " ".join(str(name or "").split())
    if not re.fullmatch(r"[\w][\w \-']{0,39}", name):
        fail("Use 1-40 letters, digits, spaces, dashes or apostrophes for the profile name.")
    if name.lower().startswith("_"):
        fail("Profile names cannot start with an underscore.")
    return name


def _slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "profile"


def _new_folder(name):
    base = os.path.join(studio_root(), "profiles", _slug(name))
    path, n = base, 2
    while os.path.exists(path):
        path, n = f"{base}-{n}", n + 1
    for sub in SUBFOLDERS:
        os.makedirs(os.path.join(path, sub), exist_ok=True)
    app = os.path.dirname(os.path.abspath(__file__))      # the guide for Claude Code inside each profile
    for guide in (os.path.join(app, "CLAUDE.workspace.md"), os.path.join(app, "CLAUDE.md"),
                  os.path.join(studio_root(), "workspace", "CLAUDE.md")):
        if os.path.exists(guide):
            shutil.copy2(guide, os.path.join(path, "CLAUDE.md"))
            break
    return path


def _localise_assets(dest):
    """Copy the brand kit's logo and music into the profile's own assets folder and point brand.json at them,
    so a profile never depends on files that belong to another profile."""
    brand_path = os.path.join(dest, "brand.json")
    brand = read_json(brand_path)
    if not isinstance(brand, dict):
        return
    for key in ("logo", "music", "font_file"):
        src = brand.get(key)
        if src and os.path.exists(src) and os.path.dirname(os.path.abspath(src)) != os.path.join(dest, "assets"):
            target = os.path.join(dest, "assets", os.path.basename(src))
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(src, target)
            brand[key] = target
    write_json(brand_path, brand)


def _copy_setup(src, dest):
    for f in SETUP_FILES:
        if os.path.exists(os.path.join(src, f)):
            shutil.copy2(os.path.join(src, f), os.path.join(dest, f))
    for d in SETUP_DIRS:
        if os.path.isdir(os.path.join(src, d)):
            shutil.copytree(os.path.join(src, d), os.path.join(dest, d), dirs_exist_ok=True)
    _localise_assets(dest)


def _stamp_profile(dest, name):
    meta = read_json(os.path.join(dest, "profile.json"), {}) or {}
    meta["name"] = name
    meta.setdefault("defaults", {})
    meta["created"] = meta.get("created") or datetime.date.today().isoformat()
    write_json(os.path.join(dest, "profile.json"), meta)


def create(name, copy_from=None, switch=True):
    name = check_name(name)
    reg = registry()
    if name in reg["profiles"]:
        fail(f"A profile called '{name}' already exists.")
    dest = _new_folder(name)
    if copy_from:
        _copy_setup(folder(copy_from), dest)
    _stamp_profile(dest, name)
    reg["profiles"][name] = dest
    if switch:
        reg["current"] = name
    save_registry(reg)
    log(f"Created profile '{name}'" + (f" from '{copy_from}'" if copy_from else "") + f": {dest}")
    log(f"PROFILE: {dest}")
    return dest


def switch(name):
    reg = registry()
    if name not in reg["profiles"]:
        fail(f"There is no profile called '{name}'.")
    path = reg["profiles"][name]
    for sub in SUBFOLDERS:
        os.makedirs(os.path.join(path, sub), exist_ok=True)
    reg["current"] = name
    save_registry(reg)
    log(f"PROFILE: {path}")
    return path


def export(name, out):
    """Zip the profile's setup: brand kit (with its logo and music), style bible, house rules, voice samples,
    defaults and settings. Footage, videos and sign-ins are left out."""
    src = folder(name)
    out = os.path.abspath(out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    brand = read_json(os.path.join(src, "brand.json"), {}) or {}
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("podcast-studio-profile.json", json.dumps({"name": name, "exported": datetime.date.today().isoformat(),
                                                             "format": 1}))
        for f in SETUP_FILES:
            if f == "brand.json" and brand:
                packed = dict(brand)
                for key in ("logo", "music", "font_file"):
                    if packed.get(key) and os.path.exists(packed[key]):
                        z.write(packed[key], "assets/" + os.path.basename(packed[key]))
                        packed[key] = "assets/" + os.path.basename(packed[key])
                    elif packed.get(key):
                        packed[key] = ""
                z.writestr("brand.json", json.dumps(packed, indent=2))
            elif os.path.exists(os.path.join(src, f)) and f not in NEVER_EXPORT:
                z.write(os.path.join(src, f), f)
        for d in SETUP_DIRS:
            for root, _, files in os.walk(os.path.join(src, d)):
                for fn in files:
                    full = os.path.join(root, fn)
                    z.write(full, os.path.relpath(full, src).replace(os.sep, "/"))
    log(f"Exported '{name}' to {out} ({os.path.getsize(out) // 1024} KB)")
    log(f"EXPORTED: {out}")
    return out


def import_(path, name=None):
    if not zipfile.is_zipfile(path):
        fail("That file is not a profile export (.zip).")
    with zipfile.ZipFile(path) as z:
        if "podcast-studio-profile.json" not in z.namelist():
            fail("That zip is not a Podcast Studio profile export.")
        meta = json.loads(z.read("podcast-studio-profile.json"))
        name = check_name(name or meta.get("name") or "Imported")
        reg = registry()
        base, n = name, 2
        while name in reg["profiles"]:
            name, n = f"{base} ({n})", n + 1
        dest = _new_folder(name)
        for member in z.namelist():
            target = os.path.abspath(os.path.join(dest, member))
            if not target.startswith(os.path.abspath(dest) + os.sep):     # refuse paths that climb out of the folder
                fail(f"Unsafe path in the export: {member}")
            if member.endswith("/") or member == "podcast-studio-profile.json" or os.path.basename(member) in NEVER_EXPORT:
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with z.open(member) as srcf, open(target, "wb") as dst:
                shutil.copyfileobj(srcf, dst)
    brand_path = os.path.join(dest, "brand.json")
    brand = read_json(brand_path)
    if isinstance(brand, dict):
        for key in ("logo", "music", "font_file"):
            if str(brand.get(key) or "").startswith("assets/"):
                brand[key] = os.path.join(dest, *brand[key].split("/"))
        write_json(brand_path, brand)
    _stamp_profile(dest, name)
    reg["profiles"][name] = dest
    save_registry(reg)
    log(f"Imported profile '{name}': {dest}")
    log(f"PROFILE: {dest}")
    return name


def archive(name):
    """Set a profile aside: it disappears from the list and its folder moves to profiles/_archived. Nothing is deleted."""
    reg = registry()
    if name not in reg["profiles"]:
        fail(f"There is no profile called '{name}'.")
    if reg["current"] == name:
        fail("Switch to another profile before archiving this one.")
    if len(reg["profiles"]) == 1:
        fail("The last profile cannot be archived.")
    path = reg["profiles"].pop(name)
    profiles_root = os.path.join(studio_root(), "profiles")
    if os.path.abspath(path).startswith(os.path.abspath(profiles_root) + os.sep) and os.path.isdir(path):
        dest = os.path.join(profiles_root, "_archived", f"{os.path.basename(path)}-{datetime.datetime.now():%Y%m%d-%H%M%S}")
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.move(path, dest)
        log(f"Archived '{name}' to {dest}")
    else:
        log(f"Removed '{name}' from the list; its folder was left where it is: {path}")
    save_registry(reg)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["list", "create", "switch", "export", "import", "archive"])
    ap.add_argument("--name")
    ap.add_argument("--copy-from")
    ap.add_argument("--out")
    ap.add_argument("--file")
    a = ap.parse_args()
    if a.action == "list":
        reg = registry()
        for n, p in reg["profiles"].items():
            log(f"{'*' if n == reg['current'] else ' '} {n}: {p}")
    elif a.action == "create":
        create(a.name, a.copy_from)
    elif a.action == "switch":
        switch(a.name)
    elif a.action == "export":
        if not (a.name and a.out):
            fail("export needs --name and --out")
        export(a.name, a.out)
    elif a.action == "import":
        if not a.file:
            fail("import needs --file")
        import_(a.file, a.name)
    else:
        archive(a.name)


if __name__ == "__main__":
    main()

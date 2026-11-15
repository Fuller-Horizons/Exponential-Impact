"""Footage library: transcribe your episodes once, then find the moment that matches a line of script.

Index:  python library.py index <folder-with-videos> --lib <workspace>/library
Search: python library.py search "topic words" --lib <workspace>/library
"""
import argparse
import math
import os
import re

from common import ensure_dir, fail, log, read_json, transcribe, write_json

VIDEO_EXT = (".mp4", ".mov", ".mkv", ".webm", ".m4v")
WINDOW = 20.0  # seconds of speech per searchable chunk


def _chunks(segs):
    out, cur = [], None
    for start, end, text in segs:
        if cur is None:
            cur = [start, end, text]
        elif end - cur[0] <= WINDOW:
            cur[1], cur[2] = end, cur[2] + " " + text
        else:
            out.append(tuple(cur))
            cur = [start, end, text]
    if cur:
        out.append(tuple(cur))
    return out


def index(folder, lib, whisper="small", use_embeddings=True):
    ensure_dir(lib)
    path = os.path.join(lib, "index.json")
    data = read_json(path, {"files": {}, "chunks": []})
    videos = []
    for root, _, names in os.walk(folder):
        videos += [os.path.join(root, n) for n in names if n.lower().endswith(VIDEO_EXT)]
    if not videos:
        fail(f"No videos found in {folder}")
    for n, video in enumerate(sorted(videos), 1):
        stamp = f"{os.path.getsize(video)}-{int(os.path.getmtime(video))}"
        if data["files"].get(video) == stamp:
            log(f"[{n}/{len(videos)}] already indexed: {os.path.basename(video)}")
            continue
        log(f"[{n}/{len(videos)}] indexing {os.path.basename(video)}")
        data["chunks"] = [c for c in data["chunks"] if c["file"] != video]
        for start, end, text in _chunks(transcribe(video, whisper)):
            data["chunks"].append({"file": video, "start": round(start, 2), "end": round(end, 2), "text": text})
        data["files"][video] = stamp
        write_json(path, data)  # save after every file so a long run can resume

    if use_embeddings:
        todo = [c for c in data["chunks"] if "vec" not in c]
        if todo:
            try:
                import llm
                log(f"Embedding {len(todo)} chunks with {llm.EMBED_MODEL}...")
                for c, v in zip(todo, llm.embed([c["text"] for c in todo])):
                    c["vec"] = [round(x, 5) for x in v]
                write_json(path, data)
            except Exception as e:
                log(f"Embeddings unavailable ({e}); keyword search will be used.")
    log(f"Library ready: {len(data['files'])} videos, {len(data['chunks'])} chunks -> {path}")


def _words(text):
    return [w for w in re.findall(r"[a-z0-9']+", text.lower()) if len(w) > 2]


def _cos(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na, nb = math.sqrt(sum(x * x for x in a)), math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


class Library:
    def __init__(self, lib):
        self.data = read_json(os.path.join(lib, "index.json"), {"files": {}, "chunks": []})
        self.chunks = [c for c in self.data["chunks"] if os.path.exists(c["file"])]
        self.used = set()

    def __len__(self):
        return len(self.chunks)

    def search(self, query, avoid_reuse=True):
        """Best matching chunk for `query`, or None. Meaning search first, keyword overlap as fallback."""
        if not self.chunks:
            return None
        scores = None
        if all("vec" in c for c in self.chunks):
            try:
                import llm
                q = llm.embed([query])[0]
                scores = [_cos(q, c["vec"]) for c in self.chunks]
            except Exception as e:
                log(f"  embedding search failed ({e}); using keywords")
        if scores is None:
            qw = set(_words(query))
            scores = [len(qw & set(_words(c["text"]))) / (len(qw) or 1) for c in self.chunks]
        order = sorted(range(len(scores)), key=lambda i: -scores[i])
        for i in order:
            key = (self.chunks[i]["file"], self.chunks[i]["start"])
            if avoid_reuse and key in self.used:
                continue
            self.used.add(key)
            return dict(self.chunks[i], score=round(scores[i], 3))
        return None


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("index")
    i.add_argument("folder")
    i.add_argument("--lib", required=True)
    i.add_argument("--whisper", default="small")
    i.add_argument("--no-embeddings", action="store_true")
    s = sub.add_parser("search")
    s.add_argument("query")
    s.add_argument("--lib", required=True)
    a = ap.parse_args()
    if a.cmd == "index":
        index(a.folder, a.lib, a.whisper, not a.no_embeddings)
    else:
        hit = Library(a.lib).search(a.query)
        log(str(hit and {k: v for k, v in hit.items() if k != "vec"}))


if __name__ == "__main__":
    main()

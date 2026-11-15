"""Footage library: transcribe your episodes once, then find the moment that matches a line of script.

Index:  python library.py index <folder-with-videos> --lib <workspace>/library
Search: python library.py search "topic words" --lib <workspace>/library
"""
import argparse
import hashlib
import math
import os
import re

from common import ensure_dir, fail, log, read_json, transcribe_words, write_json

VIDEO_EXT = (".mp4", ".mov", ".mkv", ".webm", ".m4v")
WINDOW = 20.0  # seconds of speech per searchable chunk


def _chunks(segs):
    """Group transcript segments into ~20 s chunks: (start, end, text, [[start, end, text]], [[start, end, word]])."""
    out, cur = [], None
    for seg in segs:
        start, end, text = seg["start"], seg["end"], seg["text"]
        row = [round(start, 2), round(end, 2), text]
        if cur is None:
            cur = [start, end, text, [row], list(seg.get("words") or [])]
        elif end - cur[0] <= WINDOW:
            cur[1], cur[2] = end, cur[2] + " " + text
            cur[3].append(row)
            cur[4] += seg.get("words") or []
        else:
            out.append(tuple(cur))
            cur = [start, end, text, [row], list(seg.get("words") or [])]
    if cur:
        out.append(tuple(cur))
    return out


def pick_soundbite(chunk, query, min_s=4.0, max_s=10.0):
    """Choose a 4-10 s spoken passage inside a chunk.

    Returns (start, seconds, [(rel_start, rel_end, text)], [[rel_start, rel_end, word]]).
    With word timing in the index the cut starts on the first word and ends on the last.
    """
    segs = chunk.get("segs") or [[chunk["start"], chunk["end"], chunk["text"]]]
    qw = set(_words(query))
    best = max(range(len(segs)), key=lambda i: (len(qw & set(_words(segs[i][2]))), -i))
    start, end, picked = segs[best][0], segs[best][1], [segs[best]]
    for seg in segs[best + 1:]:
        if end - start >= min_s or seg[1] - start > max_s:
            break
        picked.append(seg)
        end = seg[1]
    end = min(end, start + max_s)
    words = [w for w in chunk.get("words") or [] if w[0] >= start - 0.05 and w[1] <= end + 0.05]
    if words:
        start, end = max(0.0, words[0][0] - 0.12), words[-1][1]
    rel = [(max(0.0, a - start), min(b, end) - start, t) for a, b, t in picked if a < end]
    rel_words = [[round(max(0.0, a - start), 2), round(b - start, 2), w] for a, b, w in words]
    return round(start, 2), round(end - start + 0.2, 2), rel, rel_words


def index(folder, lib, whisper="small", use_embeddings=True, proxies=None):
    """Transcribe every video in `folder` into the searchable index. Long episodes are done in 10-minute pieces
    and an interrupted run resumes. Footage larger than 1080p also gets a 1080p working copy (see visuals.make_proxy),
    unless workspace/settings.json says "proxies": false."""
    from common import free_gpu, settings
    if proxies is None:
        proxies = settings().get("proxies", True) is not False
    free_gpu()
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
        mine = [c for c in data["chunks"] if c["file"] == video]
        if data["files"].get(video) == stamp and mine and all("words" in c for c in mine):
            log(f"[{n}/{len(videos)}] already indexed: {os.path.basename(video)}")
            continue
        if data["files"].get(video) == stamp:
            log(f"[{n}/{len(videos)}] upgrading the index with word timing: {os.path.basename(video)}")
        log(f"[{n}/{len(videos)}] indexing {os.path.basename(video)}")
        data["chunks"] = [c for c in data["chunks"] if c["file"] != video]
        partial = os.path.join(lib, "partial", hashlib.sha1(f"{video}|{stamp}".encode("utf-8")).hexdigest()[:16] + ".json")
        os.makedirs(os.path.dirname(partial), exist_ok=True)
        for start, end, text, segs, words in _chunks(transcribe_words(video, whisper, cache=partial)):
            data["chunks"].append({"file": video, "start": round(start, 2), "end": round(end, 2),
                                   "text": text, "segs": segs, "words": words})
        data["files"][video] = stamp
        write_json(path, data)  # save after every file so a long run can resume
        if os.path.exists(partial):
            os.remove(partial)
    if proxies:
        import visuals
        for video in sorted(videos):
            try:
                visuals.make_proxy(video)
            except Exception as e:  # noqa: BLE001 - a missing working copy only makes later cuts slower
                log(f"  could not make a working copy of {os.path.basename(video)}: {e}")

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

    def mark_used(self, file, start):
        """Exclude the chunk that contains this moment from later searches."""
        for c in self.chunks:
            if c["file"] == file and c["start"] - 0.01 <= start < max(c["end"], c["start"] + 0.02):
                self.used.add((c["file"], c["start"]))

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
    i.add_argument("--no-proxies", action="store_true", help="Do not make 1080p working copies of 4K footage")
    s = sub.add_parser("search")
    s.add_argument("query")
    s.add_argument("--lib", required=True)
    a = ap.parse_args()
    if a.cmd == "index":
        index(a.folder, a.lib, a.whisper, not a.no_embeddings, proxies=False if a.no_proxies else None)
    else:
        hit = Library(a.lib).search(a.query)
        log(str(hit and {k: v for k, v in hit.items() if k != "vec"}))


if __name__ == "__main__":
    main()

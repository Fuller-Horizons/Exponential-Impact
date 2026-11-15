"""Local language model + embeddings through Ollama (http://127.0.0.1:11434). No cloud calls."""
import json
import os
import subprocess
import time
import urllib.error
import urllib.request

from common import log

HOST = os.environ.get("OLLAMA_HOST_URL", "http://127.0.0.1:11434")
DEFAULT_MODEL = "gemma3:4b"
EMBED_MODEL = "nomic-embed-text"


def _post(path, payload, timeout=900):
    req = urllib.request.Request(HOST + path, data=json.dumps(payload).encode("utf-8"),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def _get(path, timeout=5):
    with urllib.request.urlopen(HOST + path, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def server_up():
    try:
        _get("/api/version")
        return True
    except Exception:
        return False


def ensure_server():
    """Start `ollama serve` in the background if it is not answering."""
    if server_up():
        return
    log("Starting Ollama...")
    flags = 0x00000008 | 0x08000000 if os.name == "nt" else 0  # DETACHED_PROCESS | CREATE_NO_WINDOW
    try:
        subprocess.Popen(["ollama", "serve"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         creationflags=flags)
    except FileNotFoundError:
        raise RuntimeError("Ollama is not installed. Re-run Setup-PodcastStudio.ps1.")
    for _ in range(40):
        time.sleep(0.5)
        if server_up():
            return
    raise RuntimeError("Ollama did not start. Run 'ollama serve' in a terminal to see why.")


def models():
    try:
        return [m["name"] for m in _get("/api/tags").get("models", [])]
    except Exception:
        return []


def ensure_model(name):
    have = models()
    if name in have or (":" not in name and name + ":latest" in have):
        return
    log(f"Downloading model {name} (one time)...")
    subprocess.run(["ollama", "pull", name], check=True)


def chat(system, user, model=DEFAULT_MODEL, as_json=False, temperature=0.7, num_ctx=8192):
    """One chat turn. keep_alive=0 unloads the model afterwards so the GPU is free for the next stage."""
    ensure_server()
    ensure_model(model)
    payload = {
        "model": model,
        "stream": False,
        "keep_alive": 0,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "options": {"temperature": temperature, "num_ctx": num_ctx},
    }
    if as_json:
        payload["format"] = "json"
    try:
        out = _post("/api/chat", payload)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Ollama error {e.code}: {e.read().decode('utf-8', 'ignore')[:300]}")
    text = out.get("message", {}).get("content", "").strip()
    if not as_json:
        return text
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        a, b = text.find("{"), text.rfind("}")
        if a >= 0 and b > a:
            return json.loads(text[a:b + 1])
        raise RuntimeError("Model did not return valid JSON:\n" + text[:500])


def embed(texts, model=EMBED_MODEL, batch=32):
    """Return a list of embedding vectors (lists of floats)."""
    ensure_server()
    ensure_model(model)
    vectors = []
    for i in range(0, len(texts), batch):
        out = _post("/api/embed", {"model": model, "input": texts[i:i + batch], "keep_alive": 0})
        vectors.extend(out["embeddings"])
    return vectors

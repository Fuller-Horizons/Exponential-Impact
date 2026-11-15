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
FALLBACK_MODELS = ["gemma3:4b", "qwen3:4b", "phi4-mini", "llama3.2:3b"]
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


def _installed(name, have):
    return name in have or (":" not in name and name + ":latest" in have)


def pick_model(preferred=DEFAULT_MODEL):
    """Return a usable chat model: the preferred one, else pull it, else any installed fallback."""
    ensure_server()
    have = models()
    if _installed(preferred, have):
        return preferred
    try:
        ensure_model(preferred)
        return preferred
    except Exception as e:  # unknown name, offline...
        log(f"Could not get model {preferred} ({e}).")
    chat_models = [h for h in have if "embed" not in h]
    for cand in FALLBACK_MODELS + chat_models:
        if _installed(cand, have):
            log(f"Using installed model {cand} instead.")
            return cand
    raise RuntimeError(f"No local chat model is installed. Run: ollama pull {DEFAULT_MODEL}")


CONTEXT_SIZES = (2048, 4096, 6144, 8192)


def context_size(system, user, reply_tokens=1536):
    """The smallest context window that fits this request.

    The model's working memory for the conversation (its KV cache) grows with the window: for a 4B model a
    window of 8192 takes about 1 GB of graphics memory, 4096 about half that. On a 4 GB card a needlessly large
    window pushes part of the model onto the CPU, which is several times slower.
    """
    need = (len(system) + len(user)) / 3.2 + reply_tokens      # about 3.2 characters per token for English
    return next((c for c in CONTEXT_SIZES if c >= need), CONTEXT_SIZES[-1])


def chat(system, user, model=DEFAULT_MODEL, as_json=False, temperature=0.7, num_ctx=None, schema=None,
         keep_alive=0, reply_tokens=1536):
    """One chat turn.

    keep_alive=0 unloads the model afterwards so the GPU is free for the next stage. Loops that make several
    calls in a row pass keep_alive="5m" and call unload() when they finish, so the model loads once, not every call.
    `schema` (a JSON schema dict) makes Ollama constrain the reply to that shape; older Ollama
    versions that reject it fall back to plain JSON mode.
    """
    model = pick_model(model)
    payload = {
        "model": model,
        "stream": False,
        "keep_alive": keep_alive,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "options": {"temperature": temperature,
                    "num_ctx": num_ctx or context_size(system, user, reply_tokens)},
    }
    if schema:
        as_json = True
        payload["format"] = schema
    elif as_json:
        payload["format"] = "json"
    try:
        try:
            out = _post("/api/chat", payload)
        except urllib.error.HTTPError as e:
            if not (schema and e.code == 400):
                raise
            payload["format"] = "json"
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
    """Return a list of embedding vectors (lists of floats). The model stays loaded between batches."""
    ensure_server()
    ensure_model(model)
    vectors = []
    for i in range(0, len(texts), batch):
        last = i + batch >= len(texts)
        out = _post("/api/embed", {"model": model, "input": texts[i:i + batch], "keep_alive": 0 if last else "2m"})
        vectors.extend(out["embeddings"])
    return vectors


def unload(model):
    """Free the graphics memory a model is using (no-op if it is not loaded)."""
    try:
        _post("/api/generate", {"model": model, "keep_alive": 0}, timeout=30)
    except Exception:  # noqa: BLE001
        pass


def unload_all():
    """Unload every model Ollama has in memory. Does nothing if Ollama is not running (it is not started)."""
    if not server_up():
        return []
    try:
        loaded = [m.get("name") or m.get("model") for m in _get("/api/ps").get("models", [])]
    except Exception:  # noqa: BLE001
        return []
    for name in loaded:
        if name:
            unload(name)
    if loaded:
        log(f"  freed graphics memory held by {', '.join(loaded)}")
    return loaded

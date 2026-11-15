"""Tiny stand-in for the Ollama HTTP API used by the tests."""
import http.server
import json
import threading

KEYS = ("budget", "hir", "market", "cash", "video", "employ")
GOOD = {"title": "Cash Flow Wins", "scenes": [
    {"narration": "Most small businesses do not fail from bad ideas. They simply run out of cash before the idea can work.",
     "visual": "card", "card_text": "It's not the idea. It's the cash."},
    {"narration": "", "visual": "soundbite", "query": "why cash flow matters"},
    {"narration": "Hiring too early drains your account faster than almost anything else you can do in year one.",
     "visual": "footage", "query": "hiring first employee"},
    {"narration": "", "visual": "card"},
    {"narration": "Picture an empty register at closing time, and payroll due on Friday morning.",
     "visual": "hologram", "image_prompt": "empty cash register"},
    {"narration": "So watch the cash every single week, not once a quarter when it is already too late.",
     "visual": "footage", "query": "budgeting small business"},
    {"narration": "Follow the show for more straight talk about running a business.", "visual": "card",
     "card_text": "Follow for more"}]}
SHORT = {"title": "Too Short", "scenes": [{"narration": "Cash matters.", "visual": "card"},
                                          {"narration": "Watch it.", "visual": "card"},
                                          {"narration": "Follow us.", "visual": "card"}]}
PLAN = {"title": "Cash Flow Wins", "hooks": ["You run out of cash, not ideas.",
                                             "What kills more businesses than bad ideas?",
                                             "Last year a friend closed her shop with a full order book."],
        "beats": ["a", "b", "c", "d"], "cta": "Follow."}
OUTLINE = "TITLE: Cash Flow Wins\nHOOK: You run out of cash, not ideas.\nBEATS:\n1. a\n2. b\n3. c\n4. d\nCTA: Follow."
state = {"chats": 0, "script_calls": 0, "schema_seen": False, "ctx": [], "keep": [], "unloaded": [], "loaded": ["gemma3:4b"]}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if "version" in self.path:
            return self._send({"version": "test"})
        if "/api/ps" in self.path:
            return self._send({"models": [{"name": n} for n in state["loaded"]]})
        self._send({"models": [{"name": "gemma3:4b"}, {"name": "nomic-embed-text:latest"}]})

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if "/api/generate" in self.path:
            state["unloaded"].append(req.get("model"))
            return self._send({"done": True})
        if "embed" in self.path:
            vec = lambda t: [sum(w.startswith(k) for w in t.lower().split()) + 0.01 for k in KEYS]  # noqa: E731
            return self._send({"embeddings": [vec(t) for t in req["input"]]})
        state["chats"] += 1
        state["ctx"].append(req.get("options", {}).get("num_ctx"))
        state["keep"].append(req.get("keep_alive"))
        fmt = req.get("format")
        user = req["messages"][-1]["content"]
        props = fmt.get("properties", {}) if isinstance(fmt, dict) else {}
        if "hooks" in props:
            content = json.dumps(PLAN)
        elif "ratings" in props:      # highlight finder: score each "[n] text" passage
            import re
            ratings = []
            for n, text in re.findall(r"\[(\d+)\] ([^\n]*)", user):
                score = 90 if text.startswith("why cash") else 70 if text.startswith("hiring") else 40
                ratings.append({"id": int(n), "score": score, "title": "Cash is king" if score == 90 else "A moment"})
            ratings.append({"id": 9999, "score": 100, "title": "not a real passage"})
            content = json.dumps({"ratings": ratings})
        elif "linkedin" in props:     # social posts
            content = json.dumps({"linkedin": "Most businesses do not die from bad ideas.\n\nThey run out of cash.\n\nWhat is your runway?",
                                  "thread": ["You run out of cash, not ideas.", "Hiring early drains you.", "", "Watch it weekly. Full video on the channel."],
                                  "slides": [{"headline": "Cash, not ideas", "body": "Why good businesses close."},
                                             {"headline": "Hire late"}, {"body": "no headline here"},
                                             {"headline": "Watch it weekly", "body": "Follow for more."}]})
        elif "tags" in props:         # publish pack
            content = json.dumps({"title": "Why cash flow kills good businesses", "description": "Short and true.\n\n#cash #business",
                                  "tags": ["cash flow", "#small business", " "]})
        elif fmt:
            state["schema_seen"] = state["schema_seen"] or isinstance(fmt, dict)
            state["script_calls"] += 1
            content = json.dumps(SHORT if "Your last draft" not in user else GOOD)
        elif "style guide" in req["messages"][0]["content"]:
            content = "## Voice and tone\nDirect and practical.\n## Hook patterns\n- You run out of cash, not ideas."
        else:
            content = OUTLINE
        self._send({"message": {"content": content}})


def start():
    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_port}"

"""Turn the guide (guide/guide.html, also published online) into a stand-alone page that ships with the app.

The online version is a page fragment; this adds the document head, drops the web-font link so the page
works offline (it already names system fonts as fallbacks) and removes publishing-only tags.
"""
import pathlib
import re

HERE = pathlib.Path(__file__).parent


def standalone(text):
    text = text.replace("\r\n", "\n")
    title = re.search(r"<title>(.*?)</title>", text, re.S)
    head_end = text.index("</style>") + len("</style>")
    head, body = text[:head_end], text[head_end:]
    head = re.sub(r"<title>.*?</title>\n?", "", head, flags=re.S)
    head = re.sub(r'<meta name="claude:[^"]*"[^>]*>\n?', "", head)
    head = re.sub(r'<link rel="stylesheet" href="https://fonts\.googleapis\.com[^"]*">\n?', "", head)
    return ("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
            f"<title>{title.group(1) if title else 'Podcast Studio Guide'}</title>\n"
            "<!-- Generated from guide/guide.html by build.py; edit that file, not this one. -->\n"
            "<style>body{margin:0}img{max-width:100%}[hidden]{display:none!important}</style>\n"
            + head.strip() + "\n</head>\n<body>\n" + body.strip() + "\n</body>\n</html>\n")


def build():
    return standalone((HERE / "guide.html").read_text(encoding="utf-8"))

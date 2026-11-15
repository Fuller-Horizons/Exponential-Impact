"""Turn one video into social posts: a LinkedIn post, an X thread and carousel slides. Drafted by the local model.

  python repurpose.py --project <project folder>            uses the project's script
  python repurpose.py --text-file transcript.txt --out DIR  uses any transcript

Writes linkedin.txt, x-thread.txt, carousel.txt and slide_01.png ... into <project>/social (or --out).
Nothing is posted anywhere: these are drafts for you to review and paste.
"""
import argparse
import os

from common import ensure_dir, fail, log, read_json, read_text, write_json, write_text

SCHEMA = {"type": "object", "required": ["linkedin", "thread", "slides"], "properties": {
    "linkedin": {"type": "string"},
    "thread": {"type": "array", "items": {"type": "string"}},
    "slides": {"type": "array", "items": {"type": "object", "required": ["headline"], "properties": {
        "headline": {"type": "string"}, "body": {"type": "string"}}}}}}
SLIDE = (1080, 1350)   # 4:5, the carousel size Instagram and LinkedIn both accept


def house_rules(workspace):
    path = os.path.join(workspace, "house-rules.md")
    return read_text(path)[:3000] if os.path.exists(path) else ""


def draft(text, title, model, rules=""):
    import llm

    system = ("You turn a video transcript into social posts in the speaker's own voice. Reply with JSON only. "
              "Use only claims that are in the transcript. Plain words, no hype, no emojis unless the rules ask."
              + (f"\n\nHOUSE RULES (always follow):\n{rules}" if rules else ""))
    user = (f"Video title: {title}\n\nTRANSCRIPT:\n{text[:6000]}\n\n"
            "Return JSON with:\n"
            "- \"linkedin\": one post of 120 to 220 words. First line is a hook that stands alone. Short paragraphs "
            "separated by blank lines. End with a question.\n"
            "- \"thread\": 5 to 8 posts for X, each under 270 characters. The first is the hook; the last points to the video.\n"
            "- \"slides\": 5 to 8 carousel slides. Each has a \"headline\" of at most 8 words and a \"body\" of at most "
            "25 words. Slide 1 is the hook; the last slide is the call to action.")
    got = llm.chat(system, user, model, schema=SCHEMA, temperature=0.6)
    thread = [" ".join(str(t).split())[:280] for t in (got.get("thread") or []) if str(t).strip()][:10]
    slides = []
    for s in got.get("slides") or []:
        if isinstance(s, dict) and str(s.get("headline") or "").strip():
            slides.append({"headline": " ".join(str(s["headline"]).split())[:80],
                           "body": " ".join(str(s.get("body") or "").split())[:200]})
    return {"linkedin": str(got.get("linkedin") or "").strip(), "thread": thread, "slides": slides[:10]}


def write_out(posts, out_dir, kit, title):
    import visuals

    ensure_dir(out_dir)
    write_text(os.path.join(out_dir, "linkedin.txt"), posts["linkedin"] + "\n")
    write_text(os.path.join(out_dir, "x-thread.txt"),
               "\n\n".join(f"{n}/{len(posts['thread'])}  {t}" for n, t in enumerate(posts["thread"], 1)) + "\n")
    write_text(os.path.join(out_dir, "carousel.txt"),
               "\n\n".join(f"Slide {n}: {s['headline']}\n{s['body']}" for n, s in enumerate(posts["slides"], 1)) + "\n")
    for old in os.listdir(out_dir):
        if old.startswith("slide_") and old.endswith(".png"):
            os.remove(os.path.join(out_dir, old))
    for n, s in enumerate(posts["slides"], 1):
        visuals.card_image(s["headline"], os.path.join(out_dir, f"slide_{n:02}.png"), brand=kit, canvas=SLIDE,
                           kicker=title if n == 1 else f"{n} / {len(posts['slides'])}", body=s["body"])
    write_json(os.path.join(out_dir, "posts.json"), posts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project")
    ap.add_argument("--text-file")
    ap.add_argument("--out")
    ap.add_argument("--title", default="")
    ap.add_argument("--model", default="gemma3:4b")
    a = ap.parse_args()

    import brand
    if a.project:
        project = os.path.abspath(a.project)
        source = os.path.join(project, "script.txt")
        if not os.path.exists(source):
            fail("This project has no script yet. Make the video first.")
        title = a.title or (read_json(os.path.join(project, "script.json"), {}) or {}).get("title", "")
        out_dir = a.out or os.path.join(project, "social")
        workspace, kit = os.path.dirname(os.path.dirname(project)), brand.load(project)
    elif a.text_file:
        source, title = a.text_file, a.title
        if not a.out:
            fail("Give --out when using --text-file.")
        out_dir = a.out
        workspace, kit = os.path.dirname(os.path.abspath(a.out)), brand.load()
    else:
        fail("Give --project or --text-file.")
    text = read_text(source).strip()
    if len(text.split()) < 20:
        fail("There is not enough text to work from.")
    posts = draft(text, title, a.model, house_rules(workspace))
    if not posts["linkedin"] or len(posts["thread"]) < 2 or len(posts["slides"]) < 2:
        fail("The local model did not produce usable posts. Try another model, or use 'Polish with Claude Code'.")
    write_out(posts, out_dir, kit, title)
    log(f"LinkedIn post: {len(posts['linkedin'].split())} words | X thread: {len(posts['thread'])} posts | "
        f"carousel: {len(posts['slides'])} slides")
    log(f"SOCIAL POSTS: {out_dir}")


if __name__ == "__main__":
    main()

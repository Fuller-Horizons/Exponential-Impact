"""Word-timed captions (ASS) built from known text and timings - no speech recognition needed."""
import re

from common import write_text

HIGHLIGHT = "&H0000D7FF"  # gold, ASS colours are &HAABBGGRR


def word_times(text, start, end):
    """Spread the words of `text` across [start, end] in proportion to their length."""
    words = re.sub(r"[{}\\]", "", text).split()
    if not words or end <= start:
        return []
    weights = [len(w) + 1 for w in words]
    total, t, out = float(sum(weights)), start, []
    for w, wt in zip(words, weights):
        step = (end - start) * wt / total
        out.append((w, t, t + step))
        t += step
    return out


def group(words, max_words=4, max_chars=24):
    """Break a word list into short on-screen lines."""
    lines, cur, chars = [], [], 0
    for w in words:
        if cur and (len(cur) >= max_words or chars + len(w[0]) + 1 > max_chars):
            lines.append(cur)
            cur, chars = [], 0
        cur.append(w)
        chars += len(w[0]) + 1
        if w[0][-1:] in ".!?" and len(cur) >= 2:
            lines.append(cur)
            cur, chars = [], 0
    if cur:
        lines.append(cur)
    return lines


def _ts(t):
    t = max(0.0, t)
    cs = int(round(t * 100))
    return f"{cs // 360000}:{cs // 6000 % 60:02}:{cs // 100 % 60:02}.{cs % 100:02}"


def build_ass(words, width, height, path, font="Arial", highlight=HIGHLIGHT, uppercase=False, title=None):
    """Write an ASS file where each word changes colour as it is spoken. Returns seconds of caption coverage.

    `title=(text, seconds)` also shows a headline near the top for the first `seconds`.
    """
    if uppercase:
        words = [(w.upper(), a, b) for w, a, b in words]
    vertical = height > width
    size = int(height * (0.047 if vertical else 0.065))
    margin_v = int(height * (0.16 if vertical else 0.08))
    head = (
        "[Script Info]\nScriptType: v4.00+\nWrapStyle: 0\nScaledBorderAndShadow: yes\n"
        f"PlayResX: {width}\nPlayResY: {height}\n\n"
        "[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, "
        "Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
        "Alignment, MarginL, MarginR, MarginV, Encoding\n"
        f"Style: Cap,{font},{size},{highlight},&H00FFFFFF,&H00000000,&H64000000,-1,0,0,0,100,100,0,0,1,"
        f"{max(3, size // 11)},0,2,{int(width * 0.06)},{int(width * 0.06)},{margin_v},1\n"
        f"Style: Title,{font},{int(size * 1.05)},&H00FFFFFF,&H00FFFFFF,&H00000000,&HA0000000,-1,0,0,0,100,100,0,0,3,"
        f"{max(6, size // 6)},0,8,{int(width * 0.07)},{int(width * 0.07)},{int(height * 0.07)},1\n\n"
        "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n")
    lines, covered = [], 0.0
    if title and title[0].strip():
        text = re.sub(r"[{}\\\n]", " ", title[0]).strip()
        lines.append(f"Dialogue: 1,{_ts(0)},{_ts(title[1])},Title,,0,0,0,,{text}")
    for line in group(words):
        start, end = line[0][1], line[-1][2]
        if end - start < 0.05:
            continue
        text = " ".join(f"{{\\k{max(1, int(round((b - a) * 100)))}}}{w}" for w, a, b in line)
        lines.append(f"Dialogue: 0,{_ts(start)},{_ts(end)},Cap,,0,0,0,,{text}")
        covered += end - start
    write_text(path, head + "\n".join(lines) + "\n")
    return covered

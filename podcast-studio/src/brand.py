"""Brand kit: the show's colours, font and logo, set once in <workspace>/brand.json (or per project)."""
import os

from common import read_json

DEFAULT = {
    "accent": "#FFC400",            # bar and kicker on cards
    "background": "#20223E",        # card background (drawn as a soft top-to-bottom gradient)
    "text": "#FFFFFF",              # card text
    "caption_highlight": "#FFD700",  # colour a caption word turns as it is spoken
    "caption_uppercase": False,
    "font": "Segoe UI",             # one of FONTS, or set "font_file" to any .ttf/.otf path
    "font_file": "",
    "logo": "",                     # PNG shown in a corner of the whole video
    "logo_position": "top-right",   # top-right | top-left
    "music": "",                    # a music file played quietly under every video (lowered while someone speaks)
}
# family name (used by captions) -> bold font file in C:\Windows\Fonts (used by cards)
FONTS = {
    "Segoe UI": "segoeuib.ttf", "Arial": "arialbd.ttf", "Impact": "impact.ttf", "Bahnschrift": "bahnschrift.ttf",
    "Georgia": "georgiab.ttf", "Verdana": "verdanab.ttf", "Trebuchet MS": "trebucbd.ttf",
}


def load(project=None):
    """Defaults, overridden by <workspace>/brand.json, then by <project>/brand.json."""
    kit = dict(DEFAULT)
    if project:
        workspace = os.path.dirname(os.path.dirname(os.path.abspath(project)))
        for path in (os.path.join(workspace, "brand.json"), os.path.join(project, "brand.json")):
            data = read_json(path)
            if isinstance(data, dict):
                kit.update({k: v for k, v in data.items() if k in DEFAULT and v not in (None, "")})
    return kit


def rgb(hex_colour, fallback=(255, 255, 255)):
    h = str(hex_colour).strip().lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    try:
        return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
    except ValueError:
        return fallback


def ass_colour(hex_colour):
    r, g, b = rgb(hex_colour)
    return f"&H00{b:02X}{g:02X}{r:02X}"


def font_files(kit):
    """Candidate font files for cards, best first."""
    out = []
    if kit.get("font_file"):
        out.append(kit["font_file"])
    name = FONTS.get(kit.get("font", ""))
    if name:
        out.append(os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts", name))
    return out


def caption_font(kit):
    return kit.get("font") if kit.get("font") in FONTS else "Arial"

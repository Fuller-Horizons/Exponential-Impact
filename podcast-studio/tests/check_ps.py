"""Static PowerShell syntax check with tree-sitter (weaker than the real parser in Test-PodcastStudio.ps1).

  pip install tree-sitter tree-sitter-powershell
  python tests/check_ps.py file.ps1 [...]
Exit code = number of files with syntax errors.
"""
import sys

import tree_sitter_powershell
from tree_sitter import Language, Parser


def errors(node, out):
    if node.type == "ERROR" or node.is_missing:
        out.append(node)
        return
    if node.has_error:
        for child in node.children:
            errors(child, out)


def check(path):
    src = open(path, "rb").read()
    if src.startswith(b"\xef\xbb\xbf"):
        src = src[3:]
    src = src.replace(b"\r\n", b"\n")
    tree = Parser(Language(tree_sitter_powershell.language())).parse(src)
    found = []
    errors(tree.root_node, found)
    lines = src.split(b"\n")
    for n in found[:15]:
        row = n.start_point[0]
        kind = "missing " + n.type if n.is_missing else "syntax error"
        print(f"  {path}:{row + 1}: {kind}: {lines[row].decode('utf-8', 'replace').strip()[:100]}")
    print(f"{'FAIL' if found else 'ok  '} {path} ({len(found)} problems)")
    return bool(found)


if __name__ == "__main__":
    sys.exit(sum(check(p) for p in sys.argv[1:]))

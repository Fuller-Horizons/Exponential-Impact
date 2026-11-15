"""Static lint for the PowerShell files: variables that are read but never assigned, and calls to
functions that are neither defined in the file nor known PowerShell commands.

It cannot run the scripts, so it catches typos and renamed-but-not-updated names, not logic errors.
  python tests/lint_ps.py file.ps1 [...]      exit code = number of problems
"""
import re
import sys

AUTOMATIC = {"_", "this", "null", "true", "false", "args", "error", "lastexitcode", "psscriptroot", "input",
             "psitem", "erroractionpreference", "progresspreference", "host", "pid", "matches", "home", "pwd",
             "psversiontable", "myinvocation", "pscmdlet", "stacktrace", "ofs"}
KNOWN_COMMANDS = {c.lower() for c in """
Add-Type New-Object Join-Path Split-Path Test-Path New-Item Remove-Item Copy-Item Get-Content Set-Content
Get-ChildItem Select-Object ForEach-Object Where-Object Start-Process Get-Command Out-Null Out-Host ConvertFrom-Json
ConvertTo-Json Get-Date Write-Host Start-Sleep Get-CimInstance Invoke-RestMethod Invoke-Expression Start-Transcript
Stop-Transcript Get-PSDrive Sort-Object Measure-Object Write-Output Write-Error Out-File Get-Item Set-Location
Push-Location Pop-Location Set-Item Out-String
""".split()}


def strip(src):
    """Remove comments and string contents (keeping $variables that sit inside double-quoted strings)."""
    src = re.sub(r"<#.*?#>", lambda m: "\n" * m.group(0).count("\n"), src, flags=re.S)
    src = re.sub(r"(?m)^@'\n.*?\n'@", lambda m: "\n" * m.group(0).count("\n"), src, flags=re.S)  # here-strings
    out = []
    for line in src.split("\n"):
        res, i, n = [], 0, len(line)
        while i < n:
            c = line[i]
            if c == "'":
                j = i + 1
                while j < n:
                    if line[j] == "'":
                        if j + 1 < n and line[j + 1] == "'":
                            j += 2
                            continue
                        break
                    j += 1
                res.append("''")
                i = j + 1
            elif c == '"':
                j, keep = i + 1, []
                while j < n and line[j] != '"':
                    if line[j] == "`":
                        j += 2
                        continue
                    keep.append(line[j])
                    j += 1
                # keep only the variable references from inside the string
                res.append(" " + " ".join(re.findall(r"\$(?:script:|global:|env:)?\{?[A-Za-z_]\w*", "".join(keep))) + " ")
                i = j + 1
            elif c == "#":
                break
            else:
                res.append(c)
                i += 1
        out.append("".join(res))
    return out


def lint(path):
    raw = open(path, encoding="utf-8-sig").read().replace("\r\n", "\n")
    lines = strip(raw)
    text = "\n".join(lines)
    assigned = set(AUTOMATIC)
    patterns = [
        r"\$(?:script:|global:)?\{?([A-Za-z_]\w*)\}?\s*(?:=(?!=)|\+=|-=|\*=)",       # $x = ...
        r"foreach\s*\(\s*\$([A-Za-z_]\w*)\s+in\b",                                   # foreach ($x in
        r"for\s*\(\s*\$([A-Za-z_]\w*)\s*=",                                          # for ($i = ...
        r"\[ref\]\s*\$([A-Za-z_]\w*)",
        r"\[[\w.\[\]]+\]\s*\$([A-Za-z_]\w*)\s*(?=[,)=])",                             # typed parameters
        r"(?:function\s+[\w-]+\s*\(|param\s*\()[^)]*?\$([A-Za-z_]\w*)",                # first untyped parameter
        r",\s*\$([A-Za-z_]\w*)\s*(?=[,)]|=\s)",                                       # later untyped parameters
    ]
    for pat in patterns:
        assigned.update(m.lower() for m in re.findall(pat, text))
    functions = {m.lower() for m in re.findall(r"(?m)^\s*function\s+([\w-]+)", text)}
    problems = []
    for n, line in enumerate(lines, 1):
        for scope, name in re.findall(r"\$(script:|global:|env:)?\{?([A-Za-z_]\w*)", line):
            if scope == "env:" or name.lower() in assigned:
                continue
            problems.append((n, f"variable ${name} is read but never assigned"))
            assigned.add(name.lower())  # report each name once
        for name in re.findall(r"(?<![\w$.\-:\[])([A-Z][a-z]+-[A-Z][A-Za-z0-9]+)\b(?!\s*=)", line):
            if name.lower() not in functions and name.lower() not in KNOWN_COMMANDS:
                problems.append((n, f"call to unknown command {name}"))
                functions.add(name.lower())
    for n, msg in problems:
        print(f"  {path}:{n}: {msg}")
    print(f"{'FAIL' if problems else 'ok  '} {path} ({len(problems)} problems)")
    return len(problems)


if __name__ == "__main__":
    sys.exit(sum(lint(p) for p in sys.argv[1:]))

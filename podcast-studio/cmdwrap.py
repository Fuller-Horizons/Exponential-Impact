"""Wrap the PowerShell installer in Install-PodcastStudio.cmd: one file to double-click.

The batch part copies the PowerShell part (everything after the marker line) to %TEMP% and runs it with
-ExecutionPolicy Bypass for that run only, so the user needs no PowerShell window or policy change.
The file stays plain text: open it in Notepad to read exactly what it does.
"""
MARKER = b"#PS1BEGIN"

STUB = r"""@echo off
setlocal
rem Podcast Studio installer. Double-click to install, or run from a command prompt with options, e.g.
rem   Install-PodcastStudio.cmd -WithCodex -WithWhisperX
rem Everything below the PS1BEGIN line is the PowerShell installer (Setup-PodcastStudio.ps1), readable as text.
title Podcast Studio setup
set "PSTUDIO_SELF=%~f0"
set "PSTUDIO_PS1=%TEMP%\Setup-PodcastStudio.ps1"
echo Unpacking the installer...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:PSTUDIO_SELF); $i=$s.IndexOf('#'+'PS1BEGIN', [StringComparison]::Ordinal); if ($i -lt 0) { exit 3 }; $b=$s.IndexOf([char]10, $i)+1; [IO.File]::WriteAllText($env:PSTUDIO_PS1, $s.Substring($b), (New-Object Text.UTF8Encoding $true))"
if errorlevel 1 goto unpackfail
powershell -NoProfile -ExecutionPolicy Bypass -File "%PSTUDIO_PS1%" %*
set "RC=%ERRORLEVEL%"
del "%PSTUDIO_PS1%" >nul 2>&1
echo.
if "%RC%"=="0" (echo Podcast Studio setup finished.) else (echo Setup stopped with code %RC%. See the logs folder under the install folder.)
pause
exit /b %RC%
:unpackfail
echo Could not unpack the installer. Download Install-PodcastStudio.cmd again.
pause
exit /b 1
"""


def make(ps1_utf8):
    """ps1_utf8: the installer as UTF-8 bytes with CRLF line ends (no BOM)."""
    stub = STUB.replace("\n", "\r\n").encode("ascii")
    assert MARKER not in stub, "the batch part must not contain the marker itself"
    return stub + MARKER + b"\r\n" + ps1_utf8


def extract(cmd_bytes):
    """What the batch part hands to PowerShell (used by the tests)."""
    i = cmd_bytes.index(MARKER)
    return cmd_bytes[cmd_bytes.index(b"\n", i) + 1:]

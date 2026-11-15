# Podcast Studio self-test. Quick by default; -Full also loads the language model and the voice clone.
#   powershell -ExecutionPolicy Bypass -File Test-PodcastStudio.ps1 [-Full] [-Model gemma3:4b]
param([switch]$Full, [string]$Model = 'gemma3:4b')
$Root = Split-Path $PSScriptRoot -Parent
$Py = Join-Path $Root 'venv\Scripts\python.exe'
$bad = 0

Write-Host 'PowerShell syntax' -ForegroundColor Cyan
foreach ($f in Get-ChildItem $PSScriptRoot -Filter *.ps1) {
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    if ($errs.Count) {
        $bad++
        foreach ($e in $errs) { Write-Host ("  [FAIL] {0}:{1}: {2}" -f $f.Name, $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red }
    } else { Write-Host "  [pass] $($f.Name)" }
}

if (-not (Test-Path $Py)) { Write-Host "  [FAIL] Python venv missing at $Py" -ForegroundColor Red; exit 1 }
$env:PYTHONPATH = $PSScriptRoot
$env:PYTHONIOENCODING = 'utf-8'
$argv = @('-u', (Join-Path $PSScriptRoot 'selftest.py'), '--root', $Root, '--model', $Model)
if ($Full) { $argv += '--full' }
& $Py @argv
if ($LASTEXITCODE -ne 0) { $bad++ }
exit $bad

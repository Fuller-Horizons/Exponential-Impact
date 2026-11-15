<#
  Podcast Studio - one-shot installer for Windows 10/11 (4 GB NVIDIA GPU, 16 GB RAM)

  Installs:  Git, Python 3.11, Node.js LTS, FFmpeg, yt-dlp, Deno, Ollama (winget), Claude Code (optional),
             PyTorch (CUDA 12.4), Qwen3-TTS 0.6B voice cloning, faster-whisper, diffusers, Pillow,
             a local language model (Ollama), claude-video "watch" skill, HyperFrames CLI.
  After install everything in the Create tab runs on this PC with no cloud calls.
  Creates :  <Root>\app\PodcastStudio.ps1 (GUI), <Root>\workspace, desktop shortcut.

  Run (normal PowerShell window, not admin):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-PodcastStudio.ps1
  Options: -Root D:\PodcastStudio  -Model gemma3:4b  -SkipModels  -SkipClaude  -CpuOnly  -WithStills  -Upgrade
  Safe to re-run. Versions are pinned: a re-run reinstalls the exact set recorded in requirements.lock
  unless you pass -Upgrade.
#>
param(
    [string]$Root = (Join-Path $env:USERPROFILE 'PodcastStudio'),
    [string]$Model = 'gemma3:4b',
    [switch]$SkipModels,
    [switch]$SkipClaude,
    [switch]$CpuOnly,
    [switch]$WithStills,
    [switch]$Upgrade
)
# Pinned upstream versions (verified to resolve together for Windows / Python 3.11)
$Pins = @{
    'claude-video' = @{ repo = 'bradautomates/claude-video'; sha = '03ceb42f7fa2c4439aca01752118044baabffb8f' }
    'Qwen3-TTS'    = @{ repo = 'QwenLM/Qwen3-TTS';           sha = '022e286b98fbec7e1e916cb940cdf532cd9f488e' }
}
$PyPins = 'faster-whisper==1.2.1', 'diffusers==0.39.0', 'pillow==13.0.0', 'fal-client==1.0.3',
          'huggingface_hub==0.36.2', 'soundfile==0.14.0', 'numpy==2.2.6'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$started = Get-Date

function Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "    [ok] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "    [!] $m" -ForegroundColor Yellow }
function Has([string]$c)  { [bool](Get-Command $c -ErrorAction SilentlyContinue) }
function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User') + ';' +
                (Join-Path $env:USERPROFILE '.local\bin') + ';' +
                (Join-Path $env:LOCALAPPDATA 'Programs\Ollama')
}
function Native([string]$what, [scriptblock]$cmd, [switch]$Soft) {
    & $cmd | Out-Host
    if ($LASTEXITCODE -ne 0) {
        if ($Soft) { Warn "$what failed (exit $LASTEXITCODE) - continuing"; return $false }
        throw "$what failed (exit $LASTEXITCODE)"
    }
    return $true
}

# ------------------------------------------------------------------ 1. prerequisites
Step 'Checking this PC'
if (-not (Has 'winget')) { throw "winget is missing. Install 'App Installer' from the Microsoft Store, then re-run." }
if (Has 'nvidia-smi') {
    $gpu = (& nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader) -join '; '
    Ok "GPU: $gpu"
} else {
    Warn 'nvidia-smi not found: update the NVIDIA driver for GPU voice cloning. Continuing (CPU works, slower).'
}
$ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
Ok "RAM: $ramGb GB"
$drive = Get-PSDrive -Name ($Root.Substring(0, 1))
if ($drive.Free -lt 25GB) { Warn ("Only {0:N0} GB free on {1}: - need ~20 GB (PyTorch + models)." -f ($drive.Free / 1GB), $drive.Name) }

# ------------------------------------------------------------------ 2. system tools
Step 'Installing system tools (winget)'
$pkgs = 'Git.Git', 'Python.Python.3.11', 'OpenJS.NodeJS.LTS', 'Gyan.FFmpeg', 'yt-dlp.yt-dlp', 'DenoLand.Deno', 'Ollama.Ollama'
foreach ($id in $pkgs) {
    Write-Host "    $id ..."
    & winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
    # already-installed returns non-zero: try an upgrade, ignore "no update"
    if ($LASTEXITCODE -ne 0) { & winget upgrade --id $id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null }
}
Refresh-Path
foreach ($c in 'git', 'node', 'ffmpeg', 'yt-dlp', 'deno', 'ollama') {
    if (Has $c) { Ok $c } else { Warn "$c not on PATH yet - open a new PowerShell window and re-run this script." }
}
$nodeMajor = 0
if (Has 'node') { $nodeMajor = [int]((& node --version).TrimStart('v').Split('.')[0]) }
if ($nodeMajor -lt 22) { Warn "Node $nodeMajor found; HyperFrames needs Node 22+. Run: winget upgrade OpenJS.NodeJS.LTS" }

$pyLauncher = $null
if (Has 'py') { $pyLauncher = { & py -3.11 @args } }
elseif (Has 'python') { $pyLauncher = { & python @args } }
else { throw 'Python 3.11 not found on PATH. Open a new PowerShell window and re-run.' }

# ------------------------------------------------------------------ 3. Claude Code
if (-not $SkipClaude) {
    Step 'Claude Code'
    if (-not (Has 'claude')) {
        Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
        Refresh-Path
    }
    if (Has 'claude') { Ok ("claude " + (& claude --version)) } else { Warn 'Claude Code not on PATH yet - reopen PowerShell later.' }
}

# ------------------------------------------------------------------ 4. folders + repos
Step "Creating $Root"
foreach ($d in 'repos', 'app', 'logs', 'workspace\analysis', 'workspace\voice', 'workspace\scripts', 'workspace\clips', 'workspace\output', 'workspace\frames', 'workspace\projects', 'workspace\library') {
    New-Item -ItemType Directory -Force -Path (Join-Path $Root $d) | Out-Null
}
foreach ($name in $Pins.Keys) {
    $dir = Join-Path $Root "repos\$name"
    $sha = $Pins[$name].sha
    if (-not (Test-Path (Join-Path $dir '.git'))) {
        Native "git clone $name" { & git clone --depth 1 --quiet "https://github.com/$($Pins[$name].repo)" $dir } | Out-Null
    }
    if ($Upgrade) {
        Native "git update $name" { & git -C $dir fetch --depth 1 --quiet origin; & git -C $dir checkout --quiet --detach FETCH_HEAD } -Soft | Out-Null
        Ok "$name (latest)"
    } else {
        $ok = Native "git fetch $name@pin" { & git -C $dir fetch --depth 1 --quiet origin $sha } -Soft
        if ($ok) { Native "git checkout $name" { & git -C $dir checkout --quiet --detach $sha } | Out-Null; Ok "$name @ $($sha.Substring(0, 8))" }
        else { Warn "${name}: pinned commit unavailable - using the cloned version" }
    }
}

# ------------------------------------------------------------------ 5. Python environment
Step 'Python environment (PyTorch + Qwen3-TTS + faster-whisper + fal.ai) - this is the big download'
$venv = Join-Path $Root 'venv'
$py = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path $py)) { Native 'create venv' { & $pyLauncher -m venv $venv } | Out-Null }
Native 'pip upgrade' { & $py -m pip install --upgrade --quiet pip wheel setuptools } | Out-Null
if ($CpuOnly) {
    Native 'torch (cpu)' { & $py -m pip install --quiet torch==2.6.0 torchaudio==2.6.0 } | Out-Null
} else {
    Native 'torch (cuda 12.4)' { & $py -m pip install --quiet torch==2.6.0 torchaudio==2.6.0 --index-url https://download.pytorch.org/whl/cu124 } | Out-Null
}
$lock = Join-Path $Root 'requirements.lock'
$torchIndex = 'https://download.pytorch.org/whl/cu124'
if ((Test-Path $lock) -and -not $Upgrade) {
    Ok 'reinstalling the exact versions in requirements.lock (pass -Upgrade to refresh)'
    if ($CpuOnly) { Native 'locked packages' { & $py -m pip install --quiet -r $lock } | Out-Null }
    else { Native 'locked packages' { & $py -m pip install --quiet -r $lock --extra-index-url $torchIndex } | Out-Null }
    Native 'qwen-tts' { & $py -m pip install --quiet --no-deps -e (Join-Path $Root 'repos\Qwen3-TTS') } | Out-Null
} else {
    Native 'qwen-tts' { & $py -m pip install --quiet -e (Join-Path $Root 'repos\Qwen3-TTS') } | Out-Null
    Native 'pinned tools' { & $py -m pip install --quiet @PyPins } | Out-Null
    & $py -m pip freeze --exclude-editable | Set-Content -Path $lock -Encoding ASCII
    Ok "versions recorded in $lock"
}
& $py -c "import torch; ok=torch.cuda.is_available(); print('    torch', torch.__version__, '| CUDA:', ok, '|', torch.cuda.get_device_name(0) if ok else 'cpu only')"

# ------------------------------------------------------------------ 6. model weights
if (-not $SkipModels) {
    Step 'Downloading models (Qwen3-TTS 0.6B Base + tokenizer, whisper-small)'
    Native 'model download' {
        & $py -c "from huggingface_hub import snapshot_download as d; [print('    ', d(r)) for r in ('Qwen/Qwen3-TTS-12Hz-0.6B-Base', 'Qwen/Qwen3-TTS-Tokenizer-12Hz')]; from faster_whisper import WhisperModel; WhisperModel('small', device='cpu', compute_type='int8'); print('     whisper-small ready')"
    } -Soft | Out-Null
    if ($WithStills) {
        Step 'Downloading Stable Diffusion 1.5 for AI stills (~4 GB)'
        Native 'SD 1.5 download' {
            & $py -c "from huggingface_hub import snapshot_download as d; print('    ', d('stable-diffusion-v1-5/stable-diffusion-v1-5', allow_patterns=['*.json', '*.txt', 'unet/diffusion_pytorch_model.safetensors', 'vae/diffusion_pytorch_model.safetensors', 'text_encoder/model.safetensors']))"
        } -Soft | Out-Null
    }

    Step "Local language model (Ollama: $Model + nomic-embed-text)"
    if (Has 'ollama') {
        $up = $false
        try { Invoke-RestMethod http://127.0.0.1:11434/api/version -TimeoutSec 3 | Out-Null; $up = $true } catch { }
        if (-not $up) {
            Start-Process ollama -ArgumentList 'serve' -WindowStyle Hidden
            foreach ($i in 1..30) {
                Start-Sleep -Milliseconds 500
                try { Invoke-RestMethod http://127.0.0.1:11434/api/version -TimeoutSec 2 | Out-Null; $up = $true; break } catch { }
            }
        }
        if ($up) {
            Native "ollama pull $Model" { & ollama pull $Model } -Soft | Out-Null
            Native 'ollama pull nomic-embed-text' { & ollama pull nomic-embed-text } -Soft | Out-Null
        } else { Warn 'Ollama did not start - open the Ollama app, then re-run this script.' }
    } else { Warn 'Ollama not on PATH yet - open a new PowerShell window and re-run.' }
}

# ------------------------------------------------------------------ 7. watch skill + HyperFrames
Step 'Video analysis skill (claude-video / watch)'
Native 'watch setup' { & $py (Join-Path $Root 'repos\claude-video\skills\watch\scripts\setup.py') --engine local --backend none --detail balanced } -Soft | Out-Null

Step 'HyperFrames (HTML -> MP4 editor)'
if (Has 'npm') {
    Native 'npm i -g hyperframes' { & npm install -g hyperframes --silent } -Soft | Out-Null
    Refresh-Path
}
if ((-not $SkipClaude) -and (Has 'claude')) {
    Step 'Claude Code plugins (watch, hyperframes)'
    Native 'marketplace claude-video' { & claude plugin marketplace add bradautomates/claude-video } -Soft | Out-Null
    Native 'plugin watch'             { & claude plugin install watch@claude-video } -Soft | Out-Null
    Native 'marketplace hyperframes'  { & claude plugin marketplace add heygen-com/hyperframes } -Soft | Out-Null
    Native 'plugin hyperframes'       { & claude plugin install hyperframes@hyperframes } -Soft | Out-Null
}

# ------------------------------------------------------------------ 8. app files
Step 'Writing Podcast Studio app'
$appDir = Join-Path $Root 'app'
$files = [ordered]@{}
#__FILES__
foreach ($name in $files.Keys) {
    $target = if ($name -eq 'CLAUDE.md') { Join-Path $Root 'workspace\CLAUDE.md' } else { Join-Path $appDir $name }
    if ($name -eq 'CLAUDE.md' -and (Test-Path $target)) { Ok 'workspace\CLAUDE.md kept (already exists)'; continue }
    [System.IO.File]::WriteAllText($target, $files[$name], (New-Object System.Text.UTF8Encoding($true)))
    Ok $name
}

# ------------------------------------------------------------------ 9. shortcut
$gui = Join-Path $appDir 'PodcastStudio.ps1'
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Podcast Studio.lnk'
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($lnk)
$sc.TargetPath = 'powershell.exe'
$sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$gui`""
$sc.WorkingDirectory = $appDir
$sc.IconLocation = 'shell32.dll,115'
$sc.Save()
Ok "Desktop shortcut: $lnk"

# ------------------------------------------------------------------ 10. self-test
Step 'Self-test (syntax, tools, packages, GPU, local model, render)'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $appDir 'Test-PodcastStudio.ps1') -Model $Model
if ($LASTEXITCODE -eq 0) { Ok 'self-test passed' } else { Warn "self-test reported problems - see $Root\logs\selftest.json" }

$mins = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
Write-Host "`nDone in $mins min. Launching Podcast Studio..." -ForegroundColor Green
Write-Host "Next: Voice clone tab > extract a voice sample; Create tab > Index footage, then type a prompt."
Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$gui`""

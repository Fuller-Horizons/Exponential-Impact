<#
  Podcast Studio - one-shot installer for Windows 10/11 (4 GB NVIDIA GPU, 16 GB RAM)

  Installs:  Git, Python 3.11, Node.js LTS, FFmpeg, yt-dlp, Deno, Ollama (winget), Claude Code (optional),
             PyTorch (CUDA 12.4), Qwen3-TTS 0.6B voice cloning, faster-whisper, diffusers, Pillow,
             a local language model (Ollama), claude-video "watch" skill, HyperFrames CLI.
  After install everything in the Create tab runs on this PC with no cloud calls.
  Hybrid part: the "Edit recording" tab hands a raw recording to Claude Code (a cloud model, your subscription)
  with the Herk Edit Kit by Nate Herk (MIT). Installing the kit runs its npm packages' install scripts.
  Creates :  <Root>\app\PodcastStudio.ps1 (GUI), <Root>\workspace, desktop shortcut.

  Run (normal PowerShell window, not admin):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-PodcastStudio.ps1
  Options: -Root D:\PodcastStudio  -Model gemma3:4b  -SkipModels  -SkipClaude  -CpuOnly  -WithStills  -Upgrade
           -CheckOnly   (look at this PC and the network, install nothing)
           -WithWhisperX  optional: more exact word timing (and who-said-what if HF_TOKEN is set). About 5 GB more.
           -WithLipSync   optional: MuseTalk lip-sync in its own Python 3.10 environment. About 10 GB more, slow
                          on a 4 GB card, and the least-tested part of this installer.
  A full log of every run is saved to <Root>\logs\install-<time>.log.
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
    [switch]$Upgrade,
    [switch]$CheckOnly,
    [switch]$WithWhisperX,
    [switch]$WithLipSync
)
# Pinned upstream versions (verified to resolve together for Windows / Python 3.11)
$Pins = @{
    'claude-video' = @{ repo = 'bradautomates/claude-video'; sha = '03ceb42f7fa2c4439aca01752118044baabffb8f' }
    'Qwen3-TTS'    = @{ repo = 'QwenLM/Qwen3-TTS';           sha = '022e286b98fbec7e1e916cb940cdf532cd9f488e' }
    'LR-ASD'       = @{ repo = 'Junhua-Liao/LR-ASD';         sha = '1b6dcd2d8fc2895683de6508ec6294ec47d388ca' }
    'herk-edit-kit' = @{ repo = 'nateherkai/herk-edit-kit';  sha = '10511e5af86fc47756ea89803b397422e2d89284' }
}
$MuseTalkSha = '0a89dec45a0192b824e3cf4daf96c239440c5ed8'
$PyPins = 'faster-whisper==1.2.1', 'diffusers==0.39.0', 'pillow==13.0.0', 'fal-client==1.0.3',
          'huggingface_hub==0.36.2', 'soundfile==0.14.0', 'numpy==2.2.6', 'opencv-python-headless==4.12.0.88',
          'google-api-python-client==2.202.0', 'google-auth-oauthlib==1.5.0'
$ModelFallbacks = 'gemma3:4b', 'phi4-mini', 'qwen3:4b', 'llama3.2:3b'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$started = Get-Date
$logName = 'install-' + $started.ToString('yyyyMMdd-HHmmss') + '.log'
$tempLog = Join-Path $env:TEMP "PodcastStudio-$logName"
try { Start-Transcript -Path $tempLog -Force | Out-Null } catch { }
function Save-Log {
    try { Stop-Transcript | Out-Null } catch { }
    try {
        $dir = Join-Path $Root 'logs'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Copy-Item $tempLog (Join-Path $dir $logName) -Force
        Write-Host "Log saved: $(Join-Path $dir $logName)"
    } catch { Write-Host "Log saved: $tempLog" }
}
trap {
    Write-Host "`nINSTALL FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "At: $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
    Save-Log
    Write-Host 'Fix the problem above and run this script again - finished steps are skipped or quick.' -ForegroundColor Yellow
    exit 1
}

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
    $gpu = (& nvidia-smi '--query-gpu=name,memory.total,driver_version' '--format=csv,noheader') -join '; '
    Ok "GPU: $gpu"
} else {
    Warn 'nvidia-smi not found: update the NVIDIA driver for GPU voice cloning. Continuing (CPU works, slower).'
}
$gb = 1024 * 1024 * 1024
$ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / $gb)
Ok "RAM: $ramGb GB"
$drive = Get-PSDrive -Name ($Root.Substring(0, 1))
$freeGb = [math]::Round($drive.Free / $gb)
if ($freeGb -lt 25) { Warn "Only $freeGb GB free on drive $($drive.Name) - need about 20 GB (PyTorch + models)." } else { Ok "Disk: $freeGb GB free" }

Step 'Checking the network (hosts the installer downloads from)'
$hosts = [ordered]@{ 'github.com' = 'code'; 'pypi.org' = 'Python packages'; 'download.pytorch.org' = 'PyTorch';
                     'huggingface.co' = 'voice and speech models'; 'ollama.com' = 'language model' }
foreach ($h in $hosts.Keys) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ok = $c.BeginConnect($h, 443, $null, $null).AsyncWaitHandle.WaitOne(4000) -and $c.Connected
        $c.Close()
    } catch { $ok = $false }
    if ($ok) { Ok "$h ($($hosts[$h]))" } else { Warn "cannot reach $h - needed for $($hosts[$h])" }
}
if ($CheckOnly) {
    Step 'Already installed'
    foreach ($c in 'git', 'python', 'py', 'node', 'ffmpeg', 'yt-dlp', 'deno', 'ollama', 'claude') {
        if (Has $c) { Ok $c } else { Write-Host "    [  ] $c (will be installed)" }
    }
    if (Test-Path (Join-Path $Root 'venv\Scripts\python.exe')) { Ok "existing install at $Root" } else { Write-Host "    [  ] no install at $Root yet" }
    Write-Host "`nCheck only - nothing was installed. Run again without -CheckOnly to install." -ForegroundColor Green
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Log saved: $tempLog"
    exit 0
}

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
foreach ($d in 'repos', 'app', 'logs', 'models', 'workspace\highlights', 'workspace\episodes', 'workspace\analysis', 'workspace\voice', 'workspace\scripts', 'workspace\clips', 'workspace\output', 'workspace\frames', 'workspace\projects', 'workspace\library') {
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

# Herk Edit Kit (MIT, by Nate Herk): the editing skills Claude Code uses in the "Edit recording" tab
$kit = Join-Path $Root 'repos\herk-edit-kit'
if ((Test-Path (Join-Path $kit 'package.json')) -and (Has 'npm')) {
    Step 'Herk Edit Kit packages (npm ci) - used by Claude Code to edit recordings'
    Push-Location $kit
    $kitOk = Native 'npm ci (herk-edit-kit)' { & npm ci --no-audit --no-fund --silent } -Soft
    if ($kitOk) { Native 'kit setup' { & npm run setup --silent } -Soft | Out-Null }
    Pop-Location
    if ($kitOk) { Ok 'Herk Edit Kit ready' } else { Warn 'The kit packages did not install. "Edit recording" still prepares files; Claude Code can finish the setup.' }
} else { Warn 'Herk Edit Kit or npm missing - the "Edit recording" tab will not have its editing skills.' }

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

    # Smaller conversation memory on the graphics card: flash attention, and an 8-bit KV cache (about half the
    # memory of the default). Ollama reads these when it starts, so they apply after its next restart.
    foreach ($kv in @(@('OLLAMA_FLASH_ATTENTION', '1'), @('OLLAMA_KV_CACHE_TYPE', 'q8_0'), @('OLLAMA_MAX_LOADED_MODELS', '1'))) {
        if (-not [Environment]::GetEnvironmentVariable($kv[0], 'User')) {
            [Environment]::SetEnvironmentVariable($kv[0], $kv[1], 'User')
            Set-Item -Path "Env:$($kv[0])" -Value $kv[1]
        }
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
            $got = $null
            foreach ($m in (@($Model) + $ModelFallbacks | Select-Object -Unique)) {
                if (Native "ollama pull $m" { & ollama pull $m } -Soft) { $got = $m; break }
            }
            if ($got) {
                if ($got -ne $Model) { Warn "$Model was not available - using $got instead"; $Model = $got }
                Ok "language model: $Model"
            } else { Warn 'No language model could be downloaded. Later, run: ollama pull <model name>' }
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

# ------------------------------------------------------------------ 7b. optional extras (their own environments)
if ($WithWhisperX) {
    Step 'WhisperX (optional: exact word timing, speaker labels)'
    $wx = Join-Path $Root 'venv-whisperx'
    if (-not (Test-Path (Join-Path $wx 'Scripts\python.exe'))) { Native 'create venv-whisperx' { & $pyLauncher -m venv $wx } -Soft | Out-Null }
    $wxPy = Join-Path $wx 'Scripts\python.exe'
    if (Test-Path $wxPy) {
        Native 'pip upgrade (whisperx)' { & $wxPy -m pip install --upgrade --quiet pip } -Soft | Out-Null
        if ($CpuOnly) { $ok = Native 'whisperx' { & $wxPy -m pip install --quiet 'whisperx==3.8.6' } -Soft }
        else { $ok = Native 'whisperx' { & $wxPy -m pip install --quiet 'whisperx==3.8.6' --extra-index-url 'https://download.pytorch.org/whl/cu128' } -Soft }
        if ($ok -and (Test-Path (Join-Path $wx 'Scripts\whisperx.exe'))) { Ok 'WhisperX installed (set the HF_TOKEN environment variable to add speaker labels)' }
        else { Warn 'WhisperX did not install - the built-in word timing will be used instead' }
    }
}
if ($WithLipSync) {
    Step 'MuseTalk lip-sync (optional, Python 3.10 environment)'
    & winget install --id Python.Python.3.10 --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
    Refresh-Path
    $mt = Join-Path $Root 'repos\MuseTalk'
    $mv = Join-Path $Root 'venv-musetalk'
    $mvPy = Join-Path $mv 'Scripts\python.exe'
    $lipOk = $true
    if (-not (Test-Path (Join-Path $mt '.git'))) { $lipOk = Native 'git clone MuseTalk' { & git clone --depth 1 --quiet 'https://github.com/TMElyralab/MuseTalk' $mt } -Soft }
    if ($lipOk) {
        if (Native 'git fetch MuseTalk@pin' { & git -C $mt fetch --depth 1 --quiet origin $MuseTalkSha } -Soft) { & git -C $mt checkout --quiet --detach $MuseTalkSha }
        if (-not (Test-Path $mvPy)) { $lipOk = Native 'create venv-musetalk' { & py -3.10 -m venv $mv } -Soft }
    }
    if ($lipOk) { $lipOk = Native 'torch 2.0.1 (cu118)' { & $mvPy -m pip install --quiet torch==2.0.1 torchvision==0.15.2 torchaudio==2.0.2 --index-url 'https://download.pytorch.org/whl/cu118' } -Soft }
    if ($lipOk) { $lipOk = Native 'MuseTalk requirements' { & $mvPy -m pip install --quiet -r (Join-Path $mt 'requirements.txt') } -Soft }
    if ($lipOk) { $lipOk = Native 'openmim' { & $mvPy -m pip install --quiet --no-cache-dir -U openmim } -Soft }
    foreach ($pkg in 'mmengine', 'mmcv==2.0.1', 'mmdet==3.1.0', 'mmpose==1.1.0') {
        if ($lipOk) { $lipOk = Native "mim install $pkg" { & $mvPy -m mim install $pkg } -Soft }
    }
    if ($lipOk -and -not $SkipModels) {
        # the project's own download script, minus the line that points it at a mirror site
        $bat = (Get-Content (Join-Path $mt 'download_weights.bat')) | Where-Object { $_ -notmatch 'HF_ENDPOINT' }
        Set-Content -Path (Join-Path $mt 'download_weights_official.bat') -Value $bat -Encoding ASCII
        $oldPath = $env:Path
        $env:Path = (Join-Path $mv 'Scripts') + ';' + $env:Path
        Push-Location $mt
        $lipOk = Native 'MuseTalk weights' { & cmd.exe /c 'download_weights_official.bat' } -Soft
        Pop-Location
        $env:Path = $oldPath
    }
    if ($lipOk -and (Test-Path (Join-Path $mt 'models\musetalkV15\unet.pth'))) { Ok 'MuseTalk installed (tick Lip-sync in the Create tab to use it)' }
    else { Warn 'MuseTalk did not install completely - lip-sync stays off. Everything else is unaffected.' }
}

# ------------------------------------------------------------------ 8. app files
Step 'Writing Podcast Studio app'
$appDir = Join-Path $Root 'app'
$files = [ordered]@{}
$files['PodcastStudio.ps1'] = @'
# Podcast Studio - local GUI: prompt -> outline -> script -> voice -> visuals -> video (all on this PC)
# Windows PowerShell 5.1+.  Launch:  powershell -ExecutionPolicy Bypass -File PodcastStudio.ps1
#   -SmokeTest  builds every screen invisibly, exercises the main handlers, writes logs\gui-smoke.json and exits
#               (exit code = number of failed checks). Run by Test-PodcastStudio.ps1.
param([switch]$SmokeTest)
$script:Smoke = [bool]$SmokeTest
$Error.Clear()
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Root   = Split-Path $PSScriptRoot -Parent
$App    = $PSScriptRoot
$Py     = Join-Path $Root 'venv\Scripts\python.exe'
$Work   = Join-Path $Root 'workspace'
$Watch  = Join-Path $Root 'repos\claude-video\skills\watch\scripts\watch.py'
$LogDir = Join-Path $Root 'logs'
foreach ($d in 'analysis','voice','scripts','clips','output','frames','projects','library') { New-Item -ItemType Directory -Force -Path (Join-Path $Work $d) | Out-Null }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$env:PYTHONUNBUFFERED = '1'
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONPATH = $App
$env:PSTUDIO_ROOT = $Root
$userFal = [Environment]::GetEnvironmentVariable('FAL_KEY', 'User')
if ($userFal) { $env:FAL_KEY = $userFal }

# ---------------------------------------------------------------- helpers
function Stamp { (Get-Date).ToString('yyyyMMdd-HHmmss') }
function Q([string]$s) {
    if ($s -match '[\s"]' -or $s -eq '') {
        if ($s.EndsWith('\')) { $s += '\' }
        return '"' + ($s -replace '"', '\"') + '"'
    }
    return $s
}
$script:lastMsg = ''
function Msg([string]$t) {
    $script:lastMsg = $t
    if ($script:Smoke) { return }   # never block the smoke test on a message box
    [void][System.Windows.Forms.MessageBox]::Show($t, 'Podcast Studio')
}
function Pick-File([string]$filter = 'All files|*.*', [string]$dir = $Work) {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = $filter; $d.InitialDirectory = $dir
    if ($d.ShowDialog() -eq 'OK') { return $d.FileName }
    return $null
}
# How episode footage is framed: label shown in the app -> value the pipeline understands
$Framings = [ordered]@{
    'Auto' = 'auto'; 'Stacked' = 'stack'; 'Side by side' = 'side'; 'Both in frame' = 'wide'
    'One person' = 'single'; 'Left person' = 'single-left'; 'Right person' = 'single-right'
    'Active speaker' = 'speaker'
}
function Get-FramingLabel([string]$value) {
    foreach ($k in $Framings.Keys) { if ($Framings[$k] -eq $value) { return $k } }
    return ''
}
$Kit = Join-Path $Root 'repos\herk-edit-kit'
$RulesFile = Join-Path $Work 'house-rules.md'
function Get-Slug([string]$name) {
    $s = ([System.IO.Path]::GetFileNameWithoutExtension($name).ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $s) { $s = 'recording' }
    return $s
}
function Add-HouseRule([string]$text, [string]$file = $RulesFile) {
    $text = ($text -replace '\s+', ' ').Trim()
    if (-not $text) { return $false }
    if (-not (Test-Path $file)) {
        [System.IO.File]::WriteAllText($file, "# House rules`n`nLasting corrections. Every script, edit and post follows these.`n`n")
    }
    [System.IO.File]::AppendAllText($file, "- $text`n")
    return $true
}
function Start-Claude([string]$dir, [string]$promptFile) {
    # Opens Claude Code in its own window with the prompt read from a file (no quoting problems)
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Msg 'Claude Code is not installed or not on PATH. Re-run the installer, then run "claude" once to sign in.'; return $false }
    $safe = $promptFile -replace "'", "''"
    Start-Process powershell.exe -WorkingDirectory $dir -ArgumentList '-NoExit', '-Command', "claude (Get-Content -Raw -LiteralPath '$safe')"
    return $true
}
$VideoFilter = 'Video|*.mp4;*.mov;*.mkv;*.webm|All files|*.*'
$AudioFilter = 'Audio|*.wav;*.mp3;*.m4a;*.flac|All files|*.*'
$ImageFilter = 'Image|*.png;*.jpg;*.jpeg;*.webp|All files|*.*'

# ---------------------------------------------------------------- form
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Podcast Studio'
$form.Size = New-Object System.Drawing.Size(980, 820)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(8, 8)
$tabs.Size = New-Object System.Drawing.Size(950, 470)
$tabs.Anchor = 'Top,Left,Right'
$form.Controls.Add($tabs)

$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true; $log.ScrollBars = 'Vertical'; $log.ReadOnly = $true
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$log.Location = New-Object System.Drawing.Point(8, 520)
$log.Size = New-Object System.Drawing.Size(950, 250)
$log.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($log)

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(8, 488); $status.Size = New-Object System.Drawing.Size(560, 24)
$status.Text = 'Ready.'
$form.Controls.Add($status)

function Log([string]$t) { $log.AppendText($t + "`r`n") }

function Add-Button($parent, [string]$text, [int]$x, [int]$y, [int]$w = 150) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, 30)
    $parent.Controls.Add($b); return $b
}
function Add-Label($parent, [string]$text, [int]$x, [int]$y, [int]$w = 130) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, ($y + 4)); $l.Size = New-Object System.Drawing.Size($w, 22)
    $parent.Controls.Add($l); return $l
}
function Add-Text($parent, [int]$x, [int]$y, [int]$w, [string]$value = '', [int]$h = 0) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y); $t.Text = $value
    if ($h -gt 0) { $t.Multiline = $true; $t.ScrollBars = 'Vertical'; $t.Size = New-Object System.Drawing.Size($w, $h) }
    else { $t.Size = New-Object System.Drawing.Size($w, 24) }
    $parent.Controls.Add($t); return $t
}
function Add-Combo($parent, [int]$x, [int]$y, [int]$w, [string[]]$items, [bool]$editable = $false) {
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Location = New-Object System.Drawing.Point($x, $y); $c.Size = New-Object System.Drawing.Size($w, 24)
    if (-not $editable) { $c.DropDownStyle = 'DropDownList' }
    [void]$c.Items.AddRange($items); $c.SelectedIndex = 0
    $parent.Controls.Add($c); return $c
}
function New-Tab([string]$title) {
    $p = New-Object System.Windows.Forms.TabPage; $p.Text = $title
    $tabs.TabPages.Add($p); return $p
}

# ---------------------------------------------------------------- job runner (non-blocking)
# onDone callbacks run in script scope; pass values through $script:ctx (no closures needed)
$script:proc = $null; $script:onDone = $null; $script:pos = @{}; $script:ctx = @{}
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400

function Read-New([string]$path) {
    if (-not (Test-Path $path)) { return }
    $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $start = [long]$script:pos[$path]
        if ($fs.Length -le $start) { return }
        [void]$fs.Seek($start, 'Begin')
        $buf = New-Object byte[] ($fs.Length - $start)
        $n = $fs.Read($buf, 0, $buf.Length)
        $script:pos[$path] = $start + $n
        $txt = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n) -replace "`r?`n", "`r`n"
        $log.AppendText($txt)
    } finally { $fs.Close() }
}

$timer.Add_Tick({
    Read-New $script:outFile; Read-New $script:errFile
    if ($script:proc -and $script:proc.HasExited) {
        $timer.Stop()
        Read-New $script:outFile; Read-New $script:errFile
        $code = $script:proc.ExitCode
        $script:proc = $null
        $done = $script:onDone; $script:onDone = $null
        if ($code -eq 0) {
            $status.Text = 'Done.'; Log '--- finished OK ---'
            if ($done) { & $done }
        } else {
            $status.Text = "Failed (exit $code) - see log."; Log "--- FAILED (exit $code) ---"
        }
    }
})

function Start-Job2([string]$label, [string]$exe, [string[]]$argv, [scriptblock]$onDone = $null) {
    if ($script:proc -and -not $script:proc.HasExited) { Msg 'A job is already running. Wait or press Stop.'; return }
    if (-not (Test-Path $Py)) { Msg "Python venv not found at $Py. Re-run Setup-PodcastStudio.ps1."; return }
    $script:outFile = Join-Path $LogDir 'job.out.log'
    $script:errFile = Join-Path $LogDir 'job.err.log'
    Remove-Item $script:outFile, $script:errFile -ErrorAction Ignore
    $script:pos = @{}
    $script:onDone = $onDone
    $argString = ($argv | ForEach-Object { Q $_ }) -join ' '
    Log ''; Log "=== $label ==="; Log "$exe $argString"
    $status.Text = "Running: $label ..."
    $script:proc = Start-Process -FilePath $exe -ArgumentList $argString -WorkingDirectory $Work `
        -RedirectStandardOutput $script:outFile -RedirectStandardError $script:errFile -NoNewWindow -PassThru
    $null = $script:proc.Handle   # PS 5.1: keeps ExitCode available
    $timer.Start()
}
function Run-Py([string]$label, [string]$script, [string[]]$argv, [scriptblock]$onDone = $null) {
    Start-Job2 $label $Py (@('-u', (Join-Path $App $script)) + $argv) $onDone
}

$btnStop = Add-Button $form 'Stop job' 580 484 110
$btnStop.Add_Click({
    if ($script:proc -and -not $script:proc.HasExited) {
        & taskkill.exe /PID $script:proc.Id /T /F | Out-Null
        Log '--- stopped by user ---'
    }
})
$btnWs = Add-Button $form 'Open workspace' 700 484 125
$btnWs.Add_Click({ Start-Process explorer.exe $Work })
$btnClaude = Add-Button $form 'Open Claude Code' 833 484 125
$btnClaude.Add_Click({
    Start-Process powershell.exe -WorkingDirectory $Work -ArgumentList '-NoExit', '-Command', 'claude'
})

# ================================================================ TAB 0: Create (prompt -> outline -> video, all local)
$t0 = New-Tab 'Create'
Add-Label $t0 'Project name' 10 12 | Out-Null
$cName = Add-Text $t0 150 12 170 'my-video'
Add-Label $t0 'Length (s)' 335 12 70 | Out-Null
$cSecs = Add-Text $t0 405 12 45 '45'
Add-Label $t0 'Format' 465 12 50 | Out-Null
$cFmt = Add-Combo $t0 515 12 70 @('9:16', '16:9', '1:1')
Add-Label $t0 'Local model' 600 12 80 | Out-Null
$cModel = Add-Combo $t0 685 12 120 @('gemma3:4b', 'phi4-mini', 'qwen3:4b', 'llama3.2:3b') $true
$cLip = New-Object System.Windows.Forms.CheckBox
$cLip.Text = 'Lip-sync'; $cLip.Location = New-Object System.Drawing.Point(815, 12); $cLip.Size = New-Object System.Drawing.Size(95, 24)
$t0.Controls.Add($cLip)
function Load-DefaultModel {
    $f = Join-Path $Work 'settings.json'
    if (-not (Test-Path $f)) { return }
    try {
        $m = ([System.IO.File]::ReadAllText($f) | ConvertFrom-Json).model
        if ($m) { $cModel.Text = [string]$m }
    } catch { }
}
Load-DefaultModel
Add-Label $t0 'Video topic / prompt' 10 47 | Out-Null
$cPrompt = Add-Text $t0 150 47 760 '' 50
Add-Label $t0 'Voice sample WAV' 10 107 | Out-Null
$cVoice = Add-Text $t0 150 107 640
$b = Add-Button $t0 'Browse...' 800 105 110; $b.Add_Click({ $f = Pick-File $AudioFilter (Join-Path $Work 'voice'); if ($f) { $cVoice.Text = $f } })
Add-Label $t0 'Episode folder' 10 142 | Out-Null
$cLib = Add-Text $t0 150 142 400
$b = Add-Button $t0 'Browse...' 560 140 90
$b.Add_Click({ $d = New-Object System.Windows.Forms.FolderBrowserDialog; if ($d.ShowDialog() -eq 'OK') { $cLib.Text = $d.SelectedPath } })
$b = Add-Button $t0 'Index footage' 660 140 130
$b.Add_Click({
    if (-not (Test-Path $cLib.Text)) { Msg 'Pick the folder that holds your episode video files.'; return }
    Run-Py 'Index footage library' 'library.py' @('index', $cLib.Text, '--lib', (Join-Path $Work 'library'))
})
$cStills = New-Object System.Windows.Forms.CheckBox
$cStills.Text = 'AI stills'; $cStills.Location = New-Object System.Drawing.Point(805, 142); $cStills.Size = New-Object System.Drawing.Size(105, 24)
$t0.Controls.Add($cStills)

function Get-Project {
    $name = ($cName.Text -replace '[^\w\-]', '-').Trim('-')
    if (-not $name) { Msg 'Enter a project name.'; return $null }
    $dir = Join-Path $Work "projects\$name"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}
function Get-ProjectArgs([string]$dir, [string]$stage) {
    [System.IO.File]::WriteAllText((Join-Path $dir 'prompt.txt'), $cPrompt.Text)
    $argv = @('--project', $dir, '--stage', $stage, '--prompt-file', (Join-Path $dir 'prompt.txt'),
        '--seconds', $cSecs.Text, '--format', $cFmt.Text, '--model', $cModel.Text, '--language', $vLang.Text,
        '--stills', $(if ($cStills.Checked) { 'on' } else { 'off' }),
        '--lipsync', $(if ($cLip.Checked) { 'on' } else { 'off' }),
        '--soundbites', $(if ($cBites.Checked) { 'on' } else { 'off' }),
        '--framing', $Framings[[string]$cFrame.SelectedItem])
    if ($cVoice.Text) { $argv += @('--voice', $cVoice.Text) }
    return $argv
}

$b = Add-Button $t0 '1. Draft outline' 150 180 150
$b.Add_Click({
    if (-not $cPrompt.Text.Trim()) { Msg 'Describe the video first.'; return }
    $dir = Get-Project; if (-not $dir) { return }
    $script:ctx = @{ dir = $dir }
    Run-Py 'Draft outline (local model)' 'pipeline.py' ((Get-ProjectArgs $dir 'outline') + '--force') {
        $f = Join-Path $script:ctx.dir 'outline.txt'
        if (Test-Path $f) { $cOutline.Text = ([System.IO.File]::ReadAllText($f) -replace "`r?`n", "`r`n") }
        $cHook.Items.Clear()
        $h = Join-Path $script:ctx.dir 'hooks.json'
        if (Test-Path $h) {
            foreach ($x in @([System.IO.File]::ReadAllText($h) | ConvertFrom-Json)) { if ($x) { [void]$cHook.Items.Add([string]$x) } }
            if ($cHook.Items.Count -gt 0) { $cHook.SelectedIndex = 0 }
        }
    }
})
$b = Add-Button $t0 '2. Approve + make video' 310 180 190
$b.Add_Click({
    if (-not $cOutline.Text.Trim()) { Msg 'Draft an outline first (or type one).'; return }
    if (-not (Test-Path $cVoice.Text)) { Msg 'Pick a reference voice WAV (make one in the Voice clone tab).'; return }
    $dir = Get-Project; if (-not $dir) { return }
    [System.IO.File]::WriteAllText((Join-Path $dir 'outline.txt'), $cOutline.Text)
    $script:ctx = @{ dir = $dir }
    Run-Py 'Make video (script, voice, visuals, render)' 'pipeline.py' (Get-ProjectArgs $dir 'all') {
        $f = Join-Path $script:ctx.dir 'final.mp4'
        if (Test-Path $f) { $script:lastFinal = $f; Start-Process explorer.exe "/select,`"$f`"" }
        Load-Scenes $true
    }
})
$b = Add-Button $t0 'Open project' 510 180 120
$b.Add_Click({ $dir = Get-Project; if ($dir) { Start-Process explorer.exe $dir } })
$b = Add-Button $t0 'Self-test' 640 180 100
$b.Add_Click({
    Start-Job2 'Self-test (quick)' 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $App 'Test-PodcastStudio.ps1'), '-Model', $cModel.Text)
})
$b = Add-Button $t0 'Full self-test' 750 180 160
$b.Add_Click({
    Start-Job2 'Self-test (full: loads models, measures VRAM)' 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $App 'Test-PodcastStudio.ps1'), '-Full', '-Model', $cModel.Text)
})
Add-Label $t0 'Hook (pick one)' 10 218 | Out-Null
$cHook = New-Object System.Windows.Forms.ComboBox
$cHook.DropDownStyle = 'DropDownList'
$cHook.Location = New-Object System.Drawing.Point(150, 218); $cHook.Size = New-Object System.Drawing.Size(325, 24)
$t0.Controls.Add($cHook)
Add-Label $t0 'Framing' 485 218 55 | Out-Null
$cFrame = Add-Combo $t0 543 218 132 @($Framings.Keys)
$cHook.Add_SelectedIndexChanged({
    if ($cHook.SelectedIndex -lt 0) { return }
    $lines = $cOutline.Text -split "`r?`n"
    for ($k = 0; $k -lt $lines.Count; $k++) {
        if ($lines[$k] -match '^\s*HOOK:') {
            $lines[$k] = 'HOOK: ' + [string]$cHook.SelectedItem
            $cOutline.Text = $lines -join "`r`n"
            break
        }
    }
})
$cBites = New-Object System.Windows.Forms.CheckBox
$cBites.Text = 'Soundbites'; $cBites.Checked = $true
$cBites.Location = New-Object System.Drawing.Point(685, 218); $cBites.Size = New-Object System.Drawing.Size(105, 24)
$t0.Controls.Add($cBites)
$b = Add-Button $t0 'Brand kit...' 800 215 110
$b.Add_Click({ Show-BrandKit })
Add-Label $t0 'Outline (editable)' 10 252 | Out-Null
$cOutline = Add-Text $t0 150 252 760 '' 153
$n0 = Add-Label $t0 'Runs fully on this PC: a local model writes the outline and script, your cloned voice narrates, and scenes use real soundbites and footage from your indexed episodes, text cards and optional AI stills. Ends with a quality report (qa.json). A failed run resumes: press step 2 again.' 150 408 760
$n0.Size = New-Object System.Drawing.Size(760, 34)

# ---------------------------------------------------------------- brand kit dialog (workspace\brand.json)
function Show-BrandKit([string]$path = '') {
    if (-not $path) { $path = Join-Path $Work 'brand.json' }
    $kit = @{ accent = '#FFC400'; background = '#20223E'; text = '#FFFFFF'; caption_highlight = '#FFD700'
              caption_uppercase = $false; font = 'Segoe UI'; logo = ''; logo_position = 'top-right'; music = '' }
    if (Test-Path $path) {
        try {
            $saved = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
            foreach ($k in @($kit.Keys)) { if ($null -ne $saved.$k -and "$($saved.$k)" -ne '') { $kit[$k] = $saved.$k } }
        } catch { }
    }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Brand kit'; $f.Size = New-Object System.Drawing.Size(520, 440); $f.StartPosition = 'CenterParent'
    $f.Font = $form.Font; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $pick = {
        $d = New-Object System.Windows.Forms.ColorDialog
        $d.Color = $this.BackColor; $d.FullOpen = $true
        if ($d.ShowDialog() -eq 'OK') { $this.BackColor = $d.Color }
    }
    $swatches = @{}
    $y = 18
    foreach ($row in @(@('accent', 'Accent colour (bar, title)'), @('background', 'Card background'), @('text', 'Card text'),
                       @('caption_highlight', 'Caption highlight'))) {
        Add-Label $f $row[1] 20 $y 200 | Out-Null
        $sw = New-Object System.Windows.Forms.Button
        $sw.Location = New-Object System.Drawing.Point(230, $y); $sw.Size = New-Object System.Drawing.Size(120, 26)
        $sw.FlatStyle = 'Flat'
        try { $sw.BackColor = [System.Drawing.ColorTranslator]::FromHtml([string]$kit[$row[0]]) } catch { $sw.BackColor = [System.Drawing.Color]::White }
        $sw.Add_Click($pick)
        $f.Controls.Add($sw); $swatches[$row[0]] = $sw
        $y += 36
    }
    Add-Label $f 'Font' 20 $y 200 | Out-Null
    $font = Add-Combo $f 230 $y 200 @('Segoe UI', 'Arial', 'Impact', 'Bahnschrift', 'Georgia', 'Verdana', 'Trebuchet MS')
    if ($font.Items.Contains([string]$kit.font)) { $font.SelectedItem = [string]$kit.font }
    $y += 36
    $upper = New-Object System.Windows.Forms.CheckBox
    $upper.Text = 'Captions in CAPITALS'; $upper.Checked = [bool]$kit.caption_uppercase
    $upper.Location = New-Object System.Drawing.Point(230, $y); $upper.Size = New-Object System.Drawing.Size(220, 24)
    $f.Controls.Add($upper)
    $y += 36
    Add-Label $f 'Logo (PNG, optional)' 20 $y 200 | Out-Null
    $logo = Add-Text $f 230 $y 170 ([string]$kit.logo)
    $lb = Add-Button $f '...' 405 ($y - 2) 35
    $lb.Tag = $logo
    $lb.Add_Click({ $p = Pick-File 'Image|*.png;*.jpg;*.jpeg|All files|*.*' $Work; if ($p) { $this.Tag.Text = $p } })
    $lc = Add-Button $f 'Clear' 445 ($y - 2) 50
    $lc.Tag = $logo
    $lc.Add_Click({ $this.Tag.Text = '' })
    $y += 36
    Add-Label $f 'Logo corner' 20 $y 200 | Out-Null
    $pos = Add-Combo $f 230 $y 120 @('top-right', 'top-left')
    if ($pos.Items.Contains([string]$kit.logo_position)) { $pos.SelectedItem = [string]$kit.logo_position }
    $y += 36
    Add-Label $f 'Music bed (optional)' 20 $y 200 | Out-Null
    $music = Add-Text $f 230 $y 170 ([string]$kit.music)
    $mb = Add-Button $f '...' 405 ($y - 2) 35
    $mb.Tag = $music
    $mb.Add_Click({ $p = Pick-File $AudioFilter $Work; if ($p) { $this.Tag.Text = $p } })
    $mc = Add-Button $f 'Clear' 445 ($y - 2) 50
    $mc.Tag = $music
    $mc.Add_Click({ $this.Tag.Text = '' })
    $ok = Add-Button $f 'Save' 300 350 90; $ok.DialogResult = 'OK'; $f.AcceptButton = $ok
    $cancel = Add-Button $f 'Cancel' 400 350 90; $cancel.DialogResult = 'Cancel'; $f.CancelButton = $cancel
    if ($script:Smoke) { $f.Opacity = 0; $f.ShowInTaskbar = $false; $f.Add_Shown({ $this.DialogResult = [System.Windows.Forms.DialogResult]::OK }) }
    if ($f.ShowDialog($form) -ne 'OK') { return }
    $out = [ordered]@{}
    foreach ($k in 'accent', 'background', 'text', 'caption_highlight') {
        $c = $swatches[$k].BackColor
        $out[$k] = '#{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B
    }
    $out['font'] = [string]$font.SelectedItem
    $out['caption_uppercase'] = [bool]$upper.Checked
    $out['logo'] = $logo.Text
    $out['logo_position'] = [string]$pos.SelectedItem
    $out['music'] = $music.Text
    [System.IO.File]::WriteAllText($path, ($out | ConvertTo-Json))
    Log "Brand kit saved: $path (used by the next video you make)"
}

# ================================================================ TAB: Edit recording (hybrid: prepared here, edited by Claude Code + Herk Edit Kit)
$tR = New-Tab 'Edit recording'
Add-Label $tR 'Raw recording' 10 12 | Out-Null
$rFile = Add-Text $tR 150 12 640
$b = Add-Button $tR 'Browse...' 800 10 110
$b.Add_Click({ $f = Pick-File $VideoFilter; if ($f) { $rFile.Text = $f; $rSlug.Text = Get-Slug $f; Load-RecordingPrompt } })
Add-Label $tR 'Project name' 10 47 | Out-Null
$rSlug = Add-Text $tR 150 47 250
Add-Label $tR 'Type' 415 47 40 | Out-Null
$rKind = Add-Combo $tR 460 47 190 @('Short (reel or Short)', 'Long video')
$rTight = New-Object System.Windows.Forms.CheckBox
$rTight.Text = 'Remove pauses here first'; $rTight.Checked = $true
$rTight.Location = New-Object System.Drawing.Point(662, 47); $rTight.Size = New-Object System.Drawing.Size(250, 24)
$tR.Controls.Add($rTight)
$rPrompt = Add-Text $tR 150 165 760 '' 175
$lr = Add-Label $tR 'What Claude Code will be asked (you can edit it)' 10 165 135
$lr.Size = New-Object System.Drawing.Size(135, 80)

function Get-RecordingKind { if ($rKind.SelectedIndex -eq 1) { return 'long' } else { return 'short' } }
function Get-RecordingProject {
    if (-not $rSlug.Text.Trim()) { return $null }
    return (Join-Path $Kit ("video-projects\" + $rSlug.Text.Trim()))
}
function Load-RecordingPrompt {
    $rPrompt.Text = ''
    $proj = Get-RecordingProject; if (-not $proj) { return }
    $pf = Join-Path $proj ("prompt-" + (Get-RecordingKind) + ".txt")
    if (Test-Path $pf) { $rPrompt.Text = ([System.IO.File]::ReadAllText($pf) -replace "`r?`n", "`r`n") }
}
$rKind.Add_SelectedIndexChanged({ Load-RecordingPrompt })

$b = Add-Button $tR '1. Prepare (transcribe here)' 150 85 220
$b.Add_Click({
    if (-not (Test-Path $rFile.Text)) { Msg 'Choose your raw recording first.'; return }
    if ($rSlug.Text -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { Msg 'The project name must be lowercase letters, digits and dashes, like my-first-take.'; return }
    $argv = @('prepare', '--recording', $rFile.Text, '--slug', $rSlug.Text, '--workspace', $Work)
    if ($rTight.Checked) { $argv += '--tighten' }
    Run-Py 'Prepare recording (copy, transcribe on this PC)' 'recording.py' $argv { Load-RecordingPrompt }
})
$b = Add-Button $tR '2. Edit with Claude Code' 380 85 200
$b.Add_Click({
    $proj = Get-RecordingProject
    if (-not $proj -or -not (Test-Path (Join-Path $proj 'assets\raw.json'))) { Msg 'Press "1. Prepare" first.'; return }
    if (-not $rPrompt.Text.Trim()) { Load-RecordingPrompt }
    $pf = Join-Path $proj ("prompt-" + (Get-RecordingKind) + ".txt")
    [System.IO.File]::WriteAllText($pf, ($rPrompt.Text -replace "`r`n", "`n"))
    if (Start-Claude $Kit $pf) { Log "Claude Code opened in $Kit. Its window shows the edit; answer its questions there." }
})
$b = Add-Button $tR 'Open project folder' 590 85 160
$b.Add_Click({ $proj = Get-RecordingProject; if ($proj -and (Test-Path $proj)) { Start-Process explorer.exe $proj } else { Msg 'Nothing prepared yet.' } })
$b = Add-Button $tR 'House rules' 760 85 150
$b.Add_Click({
    if (-not (Test-Path $RulesFile)) { [void](Add-HouseRule 'Example: never open with "In this video". (Delete this line and add your own.)') }
    Start-Process notepad.exe $RulesFile
})
$b = Add-Button $tR 'Quick trim (no AI)' 150 125 220
$b.Add_Click({
    if (-not (Test-Path $rFile.Text)) { Msg 'Choose your raw recording first.'; return }
    $out = [System.IO.Path]::ChangeExtension($rFile.Text, $null).TrimEnd('.') + '.tight.mp4'
    $script:ctx = @{ out = $out }
    Run-Py 'Quick trim: remove dead air (on this PC, no AI)' 'recording.py' @('tighten', '--recording', $rFile.Text, '--out', $out) {
        if (Test-Path $script:ctx.out) { Start-Process explorer.exe "/select,`"$($script:ctx.out)`"" }
    }
})
$b = Add-Button $tR 'Split long recording' 380 125 160
$b.Add_Click({
    if (-not (Test-Path $rFile.Text)) { Msg 'Choose your raw recording first.'; return }
    if ($rSlug.Text -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { Msg 'The project name must be lowercase letters, digits and dashes, like my-first-take.'; return }
    $argv = @('split', '--recording', $rFile.Text, '--slug', $rSlug.Text, '--workspace', $Work, '--minutes', $rMinutes.Text)
    if ($rTight.Checked) { $argv += '--tighten' }
    Run-Py 'Split into parts (each part is its own project)' 'recording.py' $argv {
        Log 'Edit each part: set Project name to <name>-part-01, -02 ... and press "2. Edit with Claude Code" for each. Then press "Join edited parts".'
    }
})
Add-Label $tR 'parts of' 545 125 55 | Out-Null
$rMinutes = Add-Text $tR 602 125 35 '8'
Add-Label $tR 'min' 640 125 30 | Out-Null
$b = Add-Button $tR 'Join edited parts' 760 125 150
$b.Add_Click({
    $base = ($rSlug.Text.Trim() -replace '-part-\d+$', '')
    if (-not $base) { Msg 'Type the project name the recording was split under.'; return }
    Run-Py 'Join the edited parts' 'recording.py' @('join', '--slug', $base) {
        $j = Join-Path $Kit ("video-projects\" + ($rSlug.Text.Trim() -replace '-part-\d+$', '') + '-joined.mp4')
        if (Test-Path $j) { Start-Process explorer.exe "/select,`"$j`"" }
    }
})
$nR = Add-Label $tR ('Hybrid: this PC copies and transcribes the recording; Claude Code then edits it with the Herk Edit Kit. The transcript and editing decisions go to Claude; ' +
    'the video files stay here. For recordings over about 15 minutes, split them first: each part edits and renders in far less memory.') 150 348 760
$nR.Size = New-Object System.Drawing.Size(760, 60)

# ================================================================ TAB: Scenes (edit one scene, re-make only what changed)
$tS = New-Tab 'Scenes'
$script:sceneData = @()
$b = Add-Button $tS 'Load scenes' 10 10 120
$b.Add_Click({ Load-Scenes $false })
$sInfo = Add-Label $tS 'Shows the project named in the Create tab.' 140 10 600
$b = Add-Button $tS 'Add a house rule...' 760 10 150
$b.Add_Click({ Show-RuleDialog })
function Show-RuleDialog {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Add a house rule'; $f.Size = New-Object System.Drawing.Size(560, 230); $f.StartPosition = 'CenterParent'
    $f.Font = $form.Font; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $l = Add-Label $f 'A lasting correction, in one sentence. Every future script, edit and post will follow it.' 15 12 520
    $l.Size = New-Object System.Drawing.Size(520, 36)
    $box = Add-Text $f 15 55 515 '' 70
    $ok = Add-Button $f 'Save rule' 330 140 100; $ok.DialogResult = 'OK'
    $cancel = Add-Button $f 'Cancel' 440 140 90; $cancel.DialogResult = 'Cancel'; $f.CancelButton = $cancel
    if ($script:Smoke) { $f.Opacity = 0; $f.ShowInTaskbar = $false; $f.Add_Shown({ $this.DialogResult = [System.Windows.Forms.DialogResult]::Cancel }) }
    if ($f.ShowDialog($form) -ne 'OK') { return }
    if (Add-HouseRule $box.Text) { Log "House rule saved: $($box.Text.Trim())" }
}
$eList = New-Object System.Windows.Forms.ListBox
$eList.Location = New-Object System.Drawing.Point(10, 45); $eList.Size = New-Object System.Drawing.Size(340, 340)
$eList.HorizontalScrollbar = $true; $eList.Font = New-Object System.Drawing.Font('Consolas', 9)
$tS.Controls.Add($eList)
Add-Label $tS 'Type' 365 45 90 | Out-Null
$eType = Add-Combo $tS 460 45 150 @('card', 'footage', 'soundbite', 'still')
Add-Label $tS 'Framing' 625 45 60 | Out-Null
$eLayout = Add-Combo $tS 690 45 220 (@('(video default)') + @($Framings.Keys))
Add-Label $tS 'Narration' 365 80 90 | Out-Null
$eNarr = Add-Text $tS 460 80 450 '' 95
Add-Label $tS 'Search words' 365 183 90 | Out-Null
$eQuery = Add-Text $tS 460 183 450
Add-Label $tS 'Card text' 365 218 90 | Out-Null
$eCard = Add-Text $tS 460 218 450
Add-Label $tS 'Image prompt' 365 253 90 | Out-Null
$eImg = Add-Text $tS 460 253 450

function Load-Scenes([bool]$quiet) {
    $dir = Get-Project; if (-not $dir) { return }
    $keep = $eList.SelectedIndex
    $eList.Items.Clear(); $script:sceneData = @()
    $file = Join-Path $dir 'script.json'
    if (-not (Test-Path $file)) {
        if (-not $quiet) { Msg 'This project has no script yet. Make the video first (Create tab, step 2).' }
        return
    }
    try { $doc = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { Msg "Could not read $file"; return }
    $script:sceneData = @($doc.scenes)
    $n = 0
    foreach ($sc in $script:sceneData) {
        $n++
        $t = if ($sc.narration) { [string]$sc.narration } else { "[soundbite] $($sc.query)" }
        [void]$eList.Items.Add(('{0:00} {1,-9} {2}' -f $n, $sc.visual, $t))
    }
    $sInfo.Text = "Project: $(Split-Path $dir -Leaf)   |   $n scenes   |   $($doc.title)"
    if ($keep -ge 0 -and $keep -lt $eList.Items.Count) { $eList.SelectedIndex = $keep }
}
function Get-SceneNumber {
    if ($eList.SelectedIndex -lt 0) { Msg 'Load the scenes and pick one first.'; return 0 }
    return $eList.SelectedIndex + 1
}
$eList.Add_SelectedIndexChanged({
    $i = $eList.SelectedIndex
    if ($i -lt 0 -or $i -ge $script:sceneData.Count) { return }
    $sc = $script:sceneData[$i]
    if ($eType.Items.Contains([string]$sc.visual)) { $eType.SelectedItem = [string]$sc.visual }
    $label = Get-FramingLabel ([string]$sc.layout)
    if ($label) { $eLayout.SelectedItem = $label } else { $eLayout.SelectedIndex = 0 }
    $eNarr.Text = [string]$sc.narration; $eQuery.Text = [string]$sc.query
    $eCard.Text = [string]$sc.card_text; $eImg.Text = [string]$sc.image_prompt
})

$b = Add-Button $tS 'Save scene' 460 295 105
$b.Add_Click({
    $n = Get-SceneNumber; if ($n -eq 0) { return }
    $dir = Get-Project; if (-not $dir) { return }
    $fields = [ordered]@{ narration = $eNarr.Text; visual = [string]$eType.SelectedItem; query = $eQuery.Text
                          card_text = $eCard.Text; image_prompt = $eImg.Text
                          layout = $(if ($eLayout.SelectedIndex -gt 0) { $Framings[[string]$eLayout.SelectedItem] } else { '' }) }
    $edit = Join-Path $dir 'edit.json'
    [System.IO.File]::WriteAllText($edit, ($fields | ConvertTo-Json))
    Run-Py "Save scene $n" 'scenes.py' @('set', '--project', $dir, '--index', "$n", '--fields-file', $edit) { Load-Scenes $true }
})
$b = Add-Button $tS 'Re-make this scene' 573 295 150
$b.Add_Click({
    $n = Get-SceneNumber; if ($n -eq 0) { return }
    $dir = Get-Project; if (-not $dir) { return }
    $script:ctx = @{ dir = $dir }
    Run-Py "Re-make scene $n" 'scenes.py' @('remake', '--project', $dir, '--index', "$n") {
        Run-Py 'Re-make video (only what changed)' 'pipeline.py' @('--project', $script:ctx.dir, '--stage', 'all') { Load-Scenes $true }
    }
})
$b = Add-Button $tS 'Add after' 731 295 85
$b.Add_Click({
    $n = Get-SceneNumber; if ($n -eq 0) { return }
    $dir = Get-Project; if (-not $dir) { return }
    Run-Py "Add scene after $n" 'scenes.py' @('add', '--project', $dir, '--index', "$n") { Load-Scenes $true }
})
$b = Add-Button $tS 'Delete' 824 295 86
$b.Add_Click({
    $n = Get-SceneNumber; if ($n -eq 0) { return }
    $dir = Get-Project; if (-not $dir) { return }
    if ([System.Windows.Forms.MessageBox]::Show("Delete scene $n?", 'Podcast Studio', 'YesNo') -ne 'Yes') { return }
    Run-Py "Delete scene $n" 'scenes.py' @('delete', '--project', $dir, '--index', "$n") { Load-Scenes $true }
})
$b = Add-Button $tS 'Apply changes + re-make video' 460 335 263
$b.Add_Click({
    $dir = Get-Project; if (-not $dir) { return }
    $script:ctx = @{ dir = $dir }
    Run-Py 'Re-make video (only what changed)' 'pipeline.py' @('--project', $dir, '--stage', 'all') {
        $v = Join-Path $script:ctx.dir 'final.mp4'
        if (Test-Path $v) { $script:lastFinal = $v }
        Load-Scenes $true
    }
})
$b = Add-Button $tS 'Play video' 731 335 85
$b.Add_Click({
    $dir = Get-Project; if (-not $dir) { return }
    $v = Join-Path $dir 'final.mp4'
    if (Test-Path $v) { Start-Process $v } else { Msg 'No finished video yet - press "Apply changes + re-make video".' }
})
$b = Add-Button $tS 'Quality report' 824 335 86
$b.Add_Click({
    $dir = Get-Project; if (-not $dir) { return }
    $q = Join-Path $dir 'qa.json'
    if (Test-Path $q) { Start-Process notepad.exe $q } else { Msg 'No quality report yet.' }
})
$nS = Add-Label $tS ('Save scene stores your edit; press "Apply changes" to rebuild. Only edited scenes are re-made. ' +
    '"Re-make this scene" gives a new voice take and the next best footage. Framing applies to footage and soundbites.') 365 378 545
$nS.Size = New-Object System.Drawing.Size(545, 62)

# ================================================================ TAB: Highlights (best moments of an episode -> clips)
$tH = New-Tab 'Highlights'
$script:hlClips = @()
Add-Label $tH 'Episode video' 10 12 | Out-Null
$hEp = Add-Text $tH 150 12 640
$b = Add-Button $tH 'Browse...' 800 10 110; $b.Add_Click({ $f = Pick-File $VideoFilter; if ($f) { $hEp.Text = $f } })
Add-Label $tH 'Clips to make' 10 47 | Out-Null
$hCount = Add-Text $tH 150 47 40 '5'
Add-Label $tH 'Shortest (s)' 205 47 85 | Out-Null
$hMin = Add-Text $tH 292 47 40 '20'
Add-Label $tH 'Longest (s)' 345 47 80 | Out-Null
$hMax = Add-Text $tH 428 47 40 '45'
Add-Label $tH 'Shape' 480 47 45 | Out-Null
$hFmt = Add-Combo $tH 528 47 70 @('9:16', '16:9', '1:1')
Add-Label $tH 'Framing' 610 47 55 | Out-Null
$hFrame = Add-Combo $tH 668 47 132 @($Framings.Keys)
$hFrame.SelectedItem = 'Active speaker'
$hTitle = New-Object System.Windows.Forms.CheckBox
$hTitle.Text = 'Headline'; $hTitle.Checked = $true
$hTitle.Location = New-Object System.Drawing.Point(812, 47); $hTitle.Size = New-Object System.Drawing.Size(98, 24)
$tH.Controls.Add($hTitle)
$hList = New-Object System.Windows.Forms.ListBox
$hList.Location = New-Object System.Drawing.Point(10, 125); $hList.Size = New-Object System.Drawing.Size(900, 250)
$hList.HorizontalScrollbar = $true; $hList.Font = New-Object System.Drawing.Font('Consolas', 9)
$tH.Controls.Add($hList)

function Get-HighlightsDir {
    if (-not $hEp.Text) { return $null }
    $stem = ([System.IO.Path]::GetFileNameWithoutExtension($hEp.Text) -replace '[^\w\-]+', '-').Trim('-')
    return (Join-Path $Work "highlights\$stem")
}
function Load-Highlights {
    $hList.Items.Clear(); $script:hlClips = @()
    $dir = Get-HighlightsDir
    if (-not $dir) { return }
    $file = Join-Path $dir 'highlights.json'
    if (-not (Test-Path $file)) { return }
    try { $doc = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { return }
    foreach ($c in @($doc.clips)) {
        $script:hlClips += [string]$c.file
        [void]$hList.Items.Add(('{0,3}  {1,5:N1}s  {2,-8} {3}  |  {4}' -f $c.score, $c.seconds, $c.framing, $c.title, $c.text))
    }
}
$b = Add-Button $tH 'Find highlights + make clips' 150 85 230
$b.Add_Click({
    if (-not (Test-Path $hEp.Text)) { Msg 'Choose an episode video that has been indexed (Create tab > Index footage).'; return }
    $argv = @('--lib', (Join-Path $Work 'library'), '--episode', $hEp.Text, '--out', (Join-Path $Work 'highlights'),
        '--count', $hCount.Text, '--min', $hMin.Text, '--max', $hMax.Text, '--format', $hFmt.Text,
        '--framing', $Framings[[string]$hFrame.SelectedItem], '--model', $cModel.Text)
    if (-not $hTitle.Checked) { $argv += '--no-title' }
    Run-Py 'Find highlights and make clips' 'highlights.py' $argv { Load-Highlights }
})
$b = Add-Button $tH 'Show clips' 390 85 110
$b.Add_Click({ Load-Highlights; if ($hList.Items.Count -eq 0) { Msg 'No clips have been made for this episode yet.' } })
$b = Add-Button $tH 'Play selected' 510 85 120
$b.Add_Click({
    $i = $hList.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:hlClips.Count -and (Test-Path $script:hlClips[$i])) { Start-Process $script:hlClips[$i] }
})
$b = Add-Button $tH 'Open clips folder' 640 85 150
$b.Add_Click({ $d = Get-HighlightsDir; if ($d -and (Test-Path $d)) { Start-Process explorer.exe $d } })
$nH = Add-Label $tH ('Finds the strongest moments in one episode and cuts each into a finished clip with the hosts'' own sound, captions and a headline. ' +
    'The episode must be in the footage index. "Active speaker" cuts to whoever is talking when two hosts are on screen.') 10 385 900
$nH.Size = New-Object System.Drawing.Size(900, 50)

# ================================================================ TAB: Publish (title, description, YouTube upload)
$tP = New-Tab 'Publish'
$b = Add-Button $tP 'Load' 10 10 100
$b.Add_Click({ Load-Publish $false })
$pInfo = Add-Label $tP 'Publishes the project named in the Create tab.' 120 10 780
Add-Label $tP 'Title' 10 47 | Out-Null
$pTitle = Add-Text $tP 150 47 760
Add-Label $tP 'Description' 10 82 | Out-Null
$pDesc = Add-Text $tP 150 82 760 '' 120
Add-Label $tP 'Tags (commas)' 10 210 | Out-Null
$pTags = Add-Text $tP 150 210 760
Add-Label $tP 'Privacy' 10 245 | Out-Null
$pPrivacy = Add-Combo $tP 150 245 120 @('private', 'unlisted', 'public')
Add-Label $tP 'Schedule' 285 245 65 | Out-Null
$pWhen = Add-Text $tP 352 245 150
Add-Label $tP 'optional, e.g. 2026-12-01 09:30 (private only)' 510 245 400 | Out-Null
$script:pubUrl = ''

function Get-PublishFile { $dir = Get-Project; if (-not $dir) { return $null }; return (Join-Path $dir 'publish.json') }
function Load-Publish([bool]$quiet) {
    $file = Get-PublishFile; if (-not $file) { return }
    $script:pubUrl = ''
    $pInfo.Text = "Project: $(Split-Path (Split-Path $file -Parent) -Leaf)"
    if (-not (Test-Path $file)) {
        if (-not $quiet) { Msg 'Nothing saved yet. Press "Write title + description" or type your own and press Save.' }
        return
    }
    try { $doc = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { Msg "Could not read $file"; return }
    $pTitle.Text = [string]$doc.title
    $pDesc.Text = ([string]$doc.description -replace "`r?`n", "`r`n")
    $pTags.Text = [string]$doc.tags
    $pWhen.Text = [string]$doc.publish_at
    if ($pPrivacy.Items.Contains([string]$doc.privacy)) { $pPrivacy.SelectedItem = [string]$doc.privacy }
    if ($doc.url) { $script:pubUrl = [string]$doc.url; $pInfo.Text += "   |   uploaded: $($doc.url)" }
}
function Save-Publish {
    $file = Get-PublishFile; if (-not $file) { return $false }
    $out = [ordered]@{}
    if (Test-Path $file) {
        try { foreach ($p in ([System.IO.File]::ReadAllText($file) | ConvertFrom-Json).PSObject.Properties) { $out[$p.Name] = $p.Value } } catch { }
    }
    $out['title'] = $pTitle.Text.Trim()
    $out['description'] = ($pDesc.Text -replace "`r`n", "`n")
    $out['tags'] = $pTags.Text.Trim()
    $out['privacy'] = [string]$pPrivacy.SelectedItem
    $out['publish_at'] = $pWhen.Text.Trim()
    [System.IO.File]::WriteAllText($file, ($out | ConvertTo-Json))
    return $true
}
$b = Add-Button $tP 'Write title + description (local)' 150 285 240
$b.Add_Click({
    $dir = Get-Project; if (-not $dir) { return }
    Run-Py 'Write title and description (local model)' 'publish.py' @('pack', '--project', $dir, '--model', $cModel.Text) { Load-Publish $true }
})
$b = Add-Button $tP 'Save' 400 285 80
$b.Add_Click({ if (Save-Publish) { Log 'Publish details saved.' } })
$b = Add-Button $tP 'YouTube sign-in file...' 490 285 170
$b.Add_Click({
    $f = Pick-File 'Google sign-in file|*.json|All files|*.*' ([Environment]::GetFolderPath('UserProfile'))
    if ($f) { Copy-Item $f (Join-Path $Work 'youtube_client_secret.json') -Force; Log 'YouTube sign-in file saved in the workspace.' }
})
$b = Add-Button $tP 'Upload to YouTube' 670 285 150
$b.Add_Click({
    $dir = Get-Project; if (-not $dir) { return }
    if (-not (Test-Path (Join-Path $dir 'final.mp4'))) { Msg 'This project has no finished video yet.'; return }
    if (-not $pTitle.Text.Trim()) { Msg 'Add a title first.'; return }
    if (-not (Test-Path (Join-Path $Work 'youtube_client_secret.json'))) { Msg 'Choose your YouTube sign-in file first (see the steps below).'; return }
    $what = "Upload ""$($pTitle.Text.Trim())"" to YouTube as $($pPrivacy.SelectedItem)?"
    if ($pWhen.Text.Trim()) { $what += " It will go public at $($pWhen.Text.Trim())." }
    if ([System.Windows.Forms.MessageBox]::Show($what, 'Podcast Studio', 'YesNo') -ne 'Yes') { return }
    if (-not (Save-Publish)) { return }
    Run-Py 'Upload to YouTube' 'publish.py' @('upload', '--project', $dir) { Load-Publish $true }
})
$b = Add-Button $tP 'Open' 830 285 80
$b.Add_Click({ if ($script:pubUrl) { Start-Process $script:pubUrl } else { Msg 'This project has not been uploaded yet.' } })
$b = Add-Button $tP 'Write social posts (local)' 150 320 210
$b.Add_Click({
    $dir = Get-Project; if (-not $dir) { return }
    Run-Py 'Write LinkedIn post, X thread and carousel (local model)' 'repurpose.py' @('--project', $dir, '--model', $cModel.Text) {
        $d = Join-Path (Get-Project) 'social'
        if (Test-Path $d) { Start-Process explorer.exe $d }
    }
})
$b = Add-Button $tP 'Open posts folder' 370 320 150
$b.Add_Click({
    $dir = Get-Project; if (-not $dir) { return }
    $d = Join-Path $dir 'social'
    if (Test-Path $d) { Start-Process explorer.exe $d } else { Msg 'No posts yet. Press "Write social posts (local)".' }
})
$b = Add-Button $tP 'Polish with Claude Code' 530 320 190
$b.Add_Click({
    $dir = Get-Project; if (-not $dir) { return }
    $d = Join-Path $dir 'social'
    if (-not (Test-Path (Join-Path $d 'linkedin.txt'))) { Msg 'Write the social posts first.'; return }
    $pf = Join-Path $d 'polish-prompt.txt'
    [System.IO.File]::WriteAllText($pf, ("Read script.txt, then social/linkedin.txt, social/x-thread.txt and social/carousel.txt. " +
        "Rewrite the three posts so they are sharper and sound like this show, keeping every claim true to script.txt. " +
        "Follow every rule in $RulesFile if it exists. Save over the same three files and show me what changed. Do not post anything anywhere."))
    [void](Start-Claude $dir $pf)
})
$nP = Add-Label $tP ('Nothing leaves this PC until you press Upload and confirm. Videos upload as private unless you change Privacy. ' +
    'One-time setup: in Google Cloud Console create a project, enable "YouTube Data API v3", create an OAuth client of type "Desktop app", ' +
    'download its JSON file and choose it with "YouTube sign-in file...". Social posts are drafts in the project''s social folder; nothing is posted.') 150 360 760
$nP.Size = New-Object System.Drawing.Size(760, 80)

# ================================================================ TAB 1: Analyze
$t1 = New-Tab 'Analyze'
Add-Label $t1 'YouTube URL or file' 10 15 | Out-Null
$aSrc = Add-Text $t1 150 15 640
$b = Add-Button $t1 'Browse...' 800 13 110; $b.Add_Click({ $f = Pick-File $VideoFilter; if ($f) { $aSrc.Text = $f } })
Add-Label $t1 'Frame detail' 10 55 | Out-Null
$aDetail = Add-Combo $t1 150 55 160 @('balanced', 'efficient', 'token-burner', 'transcript')
Add-Label $t1 'Start (opt.)' 330 55 80 | Out-Null
$aStart = Add-Text $t1 415 55 80
Add-Label $t1 'End (opt.)' 510 55 70 | Out-Null
$aEnd = Add-Text $t1 585 55 80
Add-Label $t1 'Whisper model' 10 95 | Out-Null
$aWhisper = Add-Combo $t1 150 95 160 @('small', 'base', 'medium', 'tiny')

$b = Add-Button $t1 'Extract frames + captions' 10 140 230
$b.Add_Click({
    if (-not $aSrc.Text) { Msg 'Enter a URL or file.'; return }
    $argv = @('-u', $Watch, $aSrc.Text, '--engine', 'local', '--detail', $aDetail.Text, '--out-dir', (Join-Path $Work 'analysis'))
    if ($aStart.Text) { $argv += @('--start', $aStart.Text) }
    if ($aEnd.Text) { $argv += @('--end', $aEnd.Text) }
    Start-Job2 'Analyze (watch skill)' $Py $argv
})
$b = Add-Button $t1 'Transcribe (faster-whisper)' 250 140 230
$b.Add_Click({
    $src = $aSrc.Text
    if (-not $src) { Msg 'Enter a URL or file.'; return }
    $name = 'transcript-' + (Stamp)
    $script:ctx = @{ name = $name }
    if ($src -like 'http*') {
        $dl = Join-Path $Work "analysis\$name.%(ext)s"
        Start-Job2 'Download audio (yt-dlp)' 'yt-dlp' @('-f', 'bestaudio/best', '-x', '--audio-format', 'm4a', '-o', $dl, $src) {
            $f = Get-ChildItem (Join-Path $Work 'analysis') -Filter "$($script:ctx.name).*" | Select-Object -First 1
            if ($f) { Run-Py 'Transcribe' 'captions.py' @($f.FullName, '--model', $aWhisper.Text) }
        }
    } else {
        Run-Py 'Transcribe' 'captions.py' @($src, '--model', $aWhisper.Text, '--out', (Join-Path $Work "analysis\$name"))
    }
})
$b = Add-Button $t1 'Compare local models' 730 140 180
$b.Add_Click({
    Run-Py 'Compare local models (writes two test scripts with each)' 'modelbench.py' @('--workspace', $Work, '--save') { Load-DefaultModel }
})
$b = Add-Button $t1 'Build style bible (local)' 490 140 230
$b.Add_Click({
    if (-not (Test-Path (Join-Path $Work 'library\index.json'))) { Msg 'Index your episodes first (Create tab > Index footage).'; return }
    $script:ctx = @{ out = (Join-Path $Work 'style-bible.md') }
    Run-Py 'Build style bible (local model)' 'stylebible.py' @('--lib', (Join-Path $Work 'library'), '--out', $script:ctx.out, '--model', $cModel.Text) {
        if (Test-Path $script:ctx.out) { Start-Process notepad.exe $script:ctx.out }
    }
})
$b = Add-Button $t1 'Download + index (YouTube)' 10 180 230
$b.Add_Click({
    if ($aSrc.Text -notlike 'http*') { Msg 'Paste a YouTube video, playlist or channel link in the box at the top.'; return }
    Run-Py 'Download from YouTube and add to the footage library' 'ytimport.py' @('--url', $aSrc.Text, '--dest', (Join-Path $Work 'episodes'),
        '--lib', (Join-Path $Work 'library'), '--max', $aMax.Text) { $cLib.Text = Join-Path $Work 'episodes' }
})
Add-Label $t1 'up to' 250 180 40 | Out-Null
$aMax = Add-Text $t1 292 180 40 '5'
Add-Label $t1 'videos. Only for videos you own or may reuse.' 340 180 400 | Out-Null
$note = Add-Label $t1 ("Tips: 'balanced' samples scene changes. For a 45-min episode, analyse 5-10 min windows with Start/End. " +
    "Output lands in workspace\analysis. The style bible is written on this PC from your indexed episodes; the Create tab reads it automatically.") 10 222 900
$note.Size = New-Object System.Drawing.Size(900, 60)

# ================================================================ TAB 2: Voice
$t2 = New-Tab 'Voice clone'
Add-Label $t2 'Sample source' 10 15 | Out-Null
$vSrc = Add-Text $t2 150 15 640
$b = Add-Button $t2 'Browse...' 800 13 110; $b.Add_Click({ $f = Pick-File 'Media|*.mp4;*.mov;*.mkv;*.webm;*.wav;*.mp3;*.m4a|All files|*.*'; if ($f) { $vSrc.Text = $f } })
Add-Label $t2 'Start (MM:SS)' 10 50 | Out-Null
$vStart = Add-Text $t2 150 50 80 '00:30'
Add-Label $t2 'Seconds' 250 50 60 | Out-Null
$vDur = Add-Text $t2 315 50 50 '12'
Add-Label $t2 'Voice name' 385 50 80 | Out-Null
$vName = Add-Text $t2 470 50 120 'host'
$b = Add-Button $t2 'Extract sample' 610 48 140
$b.Add_Click({
    if (-not $vSrc.Text) { Msg 'Enter a sample source.'; return }
    $vd = Join-Path $Work 'voice'
    $script:ctx = @{ wav = (Join-Path $vd "$($vName.Text).wav"); txt = (Join-Path $vd "$($vName.Text).txt") }
    Run-Py 'Extract voice sample' 'extract_voice.py' @($vSrc.Text, '--start', $vStart.Text, '--duration', $vDur.Text, '--outdir', $vd, '--name', $vName.Text) {
        $vRef.Text = $script:ctx.wav
        $cVoice.Text = $script:ctx.wav
        if (Test-Path $script:ctx.txt) { $vRefText.Text = Get-Content $script:ctx.txt -Raw -Encoding UTF8 }
    }
})
$b = Add-Button $t2 'Play sample' 760 48 150; $b.Add_Click({ if (Test-Path $vRef.Text) { Start-Process $vRef.Text } })

Add-Label $t2 'Reference WAV' 10 90 | Out-Null
$vRef = Add-Text $t2 150 90 640
$b = Add-Button $t2 'Browse...' 800 88 110; $b.Add_Click({ $f = Pick-File $AudioFilter (Join-Path $Work 'voice'); if ($f) { $vRef.Text = $f; $t = [IO.Path]::ChangeExtension($f, '.txt'); if (Test-Path $t) { $vRefText.Text = Get-Content $t -Raw -Encoding UTF8 } } })
Add-Label $t2 'Sample transcript' 10 125 | Out-Null
$vRefText = Add-Text $t2 150 125 760 '' 45
Add-Label $t2 'Script to speak' 10 180 | Out-Null
$vScript = Add-Text $t2 150 180 760 '' 170
Add-Label $t2 'Language' 10 362 | Out-Null
$vLang = Add-Combo $t2 150 362 130 @('English', 'Spanish', 'French', 'German', 'Italian', 'Portuguese', 'Russian', 'Japanese', 'Korean', 'Chinese')
Add-Label $t2 'Device' 300 362 55 | Out-Null
$vDev = Add-Combo $t2 360 362 90 @('cuda', 'cpu')
$b = Add-Button $t2 'Generate voiceover' 470 360 170
$b.Add_Click({
    if (-not (Test-Path $vRef.Text)) { Msg 'Pick or extract a reference WAV first.'; return }
    if (-not $vScript.Text.Trim()) { Msg 'Write a script.'; return }
    $id = Stamp
    $sf = Join-Path $Work "scripts\script-$id.txt"
    Set-Content -Path $sf -Value $vScript.Text -Encoding UTF8
    $rt = Join-Path $Work "scripts\ref-$id.txt"
    Set-Content -Path $rt -Value $vRefText.Text -Encoding UTF8
    $out = Join-Path $Work "output\voice-$id.wav"
    $argv = @('--script', $sf, '--ref-audio', $vRef.Text, '--out', $out, '--language', $vLang.Text, '--device', $vDev.Text)
    if ($vRefText.Text.Trim()) { $argv += @('--ref-text', $rt) }
    $script:ctx = @{ out = $out }
    Run-Py 'Voiceover (Qwen3-TTS 0.6B)' 'tts.py' $argv {
        $script:lastVoice = $script:ctx.out; $sVoice.Text = $script:ctx.out; $fAudio.Text = $script:ctx.out
    }
})
$b = Add-Button $t2 'Play last voiceover' 650 360 170
$b.Add_Click({ if ($script:lastVoice -and (Test-Path $script:lastVoice)) { Start-Process $script:lastVoice } })
$n2 = Add-Label $t2 'Only clone voices with the speaker''s consent. A clean 8-15 s sample with no music or crosstalk works best.' 10 405 900
$n2.Size = New-Object System.Drawing.Size(900, 40)

# ================================================================ TAB 3: Cloud video (fal.ai)
$t3 = New-Tab '3 - Cloud video (fal.ai)'
Add-Label $t3 'Model endpoint' 10 15 | Out-Null
$fEnd = Add-Combo $t3 150 15 460 @(
    'fal-ai/latentsync',
    'fal-ai/wan/v2.2-a14b/image-to-video',
    'fal-ai/wan/v2.2-a14b/animate/move',
    'fal-ai/wan-i2v'
) $true
$b = Add-Button $t3 'Browse models' 620 13 140; $b.Add_Click({ Start-Process 'https://fal.ai/models?keywords=wan' })
$b = Add-Button $t3 'Set fal.ai key' 770 13 140
$b.Add_Click({
    $kf = New-Object System.Windows.Forms.Form
    $kf.Text = 'fal.ai API key'; $kf.Size = New-Object System.Drawing.Size(460, 150); $kf.StartPosition = 'CenterParent'
    $kt = New-Object System.Windows.Forms.TextBox; $kt.UseSystemPasswordChar = $true
    $kt.Location = New-Object System.Drawing.Point(15, 20); $kt.Size = New-Object System.Drawing.Size(410, 24)
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Save'; $ok.Location = New-Object System.Drawing.Point(335, 60)
    $ok.DialogResult = 'OK'; $kf.AcceptButton = $ok
    $kf.Controls.AddRange(@($kt, $ok))
    if ($kf.ShowDialog() -eq 'OK' -and $kt.Text.Trim()) {
        [Environment]::SetEnvironmentVariable('FAL_KEY', $kt.Text.Trim(), 'User')
        $env:FAL_KEY = $kt.Text.Trim()
        Log 'fal.ai key saved to your user environment.'
    }
})
Add-Label $t3 'Prompt' 10 55 | Out-Null
$fPrompt = Add-Text $t3 150 55 760 '' 70
Add-Label $t3 'Image (image_url)' 10 135 | Out-Null
$fImage = Add-Text $t3 150 135 640
$b = Add-Button $t3 'Browse...' 800 133 110; $b.Add_Click({ $f = Pick-File $ImageFilter (Join-Path $Work 'frames'); if ($f) { $fImage.Text = $f } })
Add-Label $t3 'Video (video_url)' 10 170 | Out-Null
$fVideo = Add-Text $t3 150 170 640
$b = Add-Button $t3 'Browse...' 800 168 110; $b.Add_Click({ $f = Pick-File $VideoFilter; if ($f) { $fVideo.Text = $f } })
Add-Label $t3 'Audio (audio_url)' 10 205 | Out-Null
$fAudio = Add-Text $t3 150 205 640
$b = Add-Button $t3 'Browse...' 800 203 110; $b.Add_Click({ $f = Pick-File $AudioFilter (Join-Path $Work 'output'); if ($f) { $fAudio.Text = $f } })
Add-Label $t3 'Extra JSON' 10 240 | Out-Null
$fExtra = Add-Text $t3 150 240 760 '{}'

Add-Label $t3 'Grab frame: video' 10 285 | Out-Null
$gSrc = Add-Text $t3 150 285 470
$b = Add-Button $t3 'Browse...' 630 283 90; $b.Add_Click({ $f = Pick-File $VideoFilter; if ($f) { $gSrc.Text = $f } })
Add-Label $t3 'at' 730 285 20 | Out-Null
$gAt = Add-Text $t3 755 285 60 '00:10'
$b = Add-Button $t3 'Grab' 825 283 85
$b.Add_Click({
    if (-not (Test-Path $gSrc.Text)) { Msg 'Pick a local video (download YouTube clips first with yt-dlp).'; return }
    $png = Join-Path $Work ("frames\frame-" + (Stamp) + '.png')
    $script:ctx = @{ out = $png }
    Start-Job2 'Grab frame' 'ffmpeg' @('-y', '-hide_banner', '-loglevel', 'error', '-ss', $gAt.Text, '-i', $gSrc.Text, '-frames:v', '1', '-q:v', '2', $png) {
        $fImage.Text = $script:ctx.out
    }
})

$b = Add-Button $t3 'Generate clip in cloud' 150 330 220
$b.Add_Click({
    if (-not $env:FAL_KEY) { Msg 'Set your fal.ai key first.'; return }
    $out = Join-Path $Work ("clips\clip-" + (Stamp) + '.mp4')
    $argv = @('--endpoint', $fEnd.Text, '--out', $out, '--extra', $fExtra.Text)
    if ($fPrompt.Text.Trim()) { $argv += @('--prompt', $fPrompt.Text.Trim()) }
    if ($fImage.Text) { $argv += @('--image', $fImage.Text) }
    if ($fVideo.Text) { $argv += @('--video', $fVideo.Text) }
    if ($fAudio.Text) { $argv += @('--audio', $fAudio.Text) }
    $script:ctx = @{ out = $out }
    Run-Py "fal.ai: $($fEnd.Text)" 'fal_generate.py' $argv { [void]$sClips.Items.Add($script:ctx.out) }
})
$n3 = Add-Label $t3 ('Lip-sync: endpoint fal-ai/latentsync + Video + Audio (your voiceover).  New scene: a Wan image-to-video endpoint + Image + Prompt. ' +
    'Endpoint ids change - confirm on fal.ai/models and type any id. Billed per run by fal.ai.') 380 328 530
$n3.Size = New-Object System.Drawing.Size(530, 70)

# ================================================================ TAB 4: Assemble
$t4 = New-Tab 'Assemble'
Add-Label $t4 'Clips (in order)' 10 15 | Out-Null
$sClips = New-Object System.Windows.Forms.ListBox
$sClips.Location = New-Object System.Drawing.Point(150, 15); $sClips.Size = New-Object System.Drawing.Size(640, 170)
$sClips.HorizontalScrollbar = $true
$t4.Controls.Add($sClips)
$b = Add-Button $t4 'Add...' 800 15 110
$b.Add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog; $d.Filter = $VideoFilter; $d.Multiselect = $true; $d.InitialDirectory = (Join-Path $Work 'clips')
    if ($d.ShowDialog() -eq 'OK') { foreach ($f in $d.FileNames) { [void]$sClips.Items.Add($f) } }
})
$b = Add-Button $t4 'Remove' 800 50 110; $b.Add_Click({ if ($sClips.SelectedIndex -ge 0) { $sClips.Items.RemoveAt($sClips.SelectedIndex) } })
$b = Add-Button $t4 'Move up' 800 85 110
$b.Add_Click({ $i = $sClips.SelectedIndex; if ($i -gt 0) { $v = $sClips.Items[$i]; $sClips.Items.RemoveAt($i); $sClips.Items.Insert($i - 1, $v); $sClips.SelectedIndex = $i - 1 } })
$b = Add-Button $t4 'Move down' 800 120 110
$b.Add_Click({ $i = $sClips.SelectedIndex; if ($i -ge 0 -and $i -lt $sClips.Items.Count - 1) { $v = $sClips.Items[$i]; $sClips.Items.RemoveAt($i); $sClips.Items.Insert($i + 1, $v); $sClips.SelectedIndex = $i + 1 } })

Add-Label $t4 'Voiceover (opt.)' 10 200 | Out-Null
$sVoice = Add-Text $t4 150 200 640
$b = Add-Button $t4 'Browse...' 800 198 110; $b.Add_Click({ $f = Pick-File $AudioFilter (Join-Path $Work 'output'); if ($f) { $sVoice.Text = $f } })
Add-Label $t4 'Music (opt.)' 10 235 | Out-Null
$sMusic = Add-Text $t4 150 235 520
Add-Label $t4 'Vol' 680 235 30 | Out-Null
$sVol = Add-Text $t4 715 235 75 '0.12'
$b = Add-Button $t4 'Browse...' 800 233 110; $b.Add_Click({ $f = Pick-File $AudioFilter; if ($f) { $sMusic.Text = $f } })
Add-Label $t4 'Format' 10 272 | Out-Null
$sFmt = Add-Combo $t4 150 272 140 @('9:16', '16:9', '1:1')
$sCap = New-Object System.Windows.Forms.CheckBox
$sCap.Text = 'Burn in captions'; $sCap.Checked = $true
$sCap.Location = New-Object System.Drawing.Point(310, 272); $sCap.Size = New-Object System.Drawing.Size(160, 24)
$t4.Controls.Add($sCap)

$b = Add-Button $t4 'Render MP4' 150 315 170
$b.Add_Click({
    if ($sClips.Items.Count -eq 0) { Msg 'Add at least one clip.'; return }
    $out = Join-Path $Work ("output\final-" + (Stamp) + '.mp4')
    $argv = @('--clips') + @($sClips.Items | ForEach-Object { [string]$_ }) + @('--format', $sFmt.Text, '--out', $out)
    if ($sVoice.Text) { $argv += @('--voice', $sVoice.Text) }
    if ($sMusic.Text) { $argv += @('--music', $sMusic.Text, '--music-volume', $sVol.Text) }
    if ($sCap.Checked) { $argv += '--captions' }
    $script:ctx = @{ out = $out }
    Run-Py 'Assemble (ffmpeg)' 'assemble.py' $argv { $script:lastFinal = $script:ctx.out; Start-Process explorer.exe "/select,`"$($script:ctx.out)`"" }
})
$b = Add-Button $t4 'Play last render' 330 315 170
$b.Add_Click({ if ($script:lastFinal -and (Test-Path $script:lastFinal)) { Start-Process $script:lastFinal } })
$b = Add-Button $t4 'HyperFrames (kinetic edit)' 510 315 220
$b.Add_Click({
    $prompt = 'Use the /hyperframes skill. Read style-bible.md. Build a HyperFrames project in hyperframes/ from the clips in clips/ and the newest voiceover in output/, with kinetic captions in the show style, then render it to output/.'
    Start-Process powershell.exe -WorkingDirectory $Work -ArgumentList '-NoExit', '-Command', ("claude " + (Q $prompt))
})
$n4 = Add-Label $t4 'Render MP4 = fast ffmpeg assembly on CPU. HyperFrames = Claude Code builds an animated HTML edit and renders it (Node 22 + Chromium, CPU).' 10 360 900
$n4.Size = New-Object System.Drawing.Size(900, 40)

# fal.ai is optional: move it to the end
$tabs.TabPages.Remove($t3); $t3.Text = 'Cloud (optional)'; $tabs.TabPages.Add($t3)
$tabs.SelectedIndex = 0

# ---------------------------------------------------------------- startup checks
$form.Add_Shown({
    Log "Podcast Studio  |  root: $Root"
    foreach ($tool in 'ffmpeg', 'yt-dlp', 'ollama', 'node', 'claude') {
        if (Get-Command $tool -ErrorAction SilentlyContinue) { Log "  [ok] $tool" } else { Log "  [missing] $tool - re-run setup" }
    }
    if (Test-Path $Py) { Log '  [ok] python venv' } else { Log '  [missing] python venv - re-run setup' }
    if (Test-Path (Join-Path $Work 'library\index.json')) { Log '  [ok] footage library indexed' } else { Log '  [info] no footage library yet (Create tab > Index footage)' }
})
$form.Add_FormClosing({ if ($script:proc -and -not $script:proc.HasExited) { & taskkill.exe /PID $script:proc.Id /T /F | Out-Null } })
if (-not $script:Smoke) {
    [void]$form.ShowDialog()
    return
}

# ================================================================ smoke test (only with -SmokeTest)
$buildErrors = @($Error | ForEach-Object { '{0} (line {1})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber })
$Error.Clear()
$script:smokeResults = @()
function Check([string]$name, [scriptblock]$body) {
    $detail = ''
    $before = $Error.Count
    try {
        $detail = [string](& $body)
        if ($Error.Count -gt $before) { throw ('error raised: ' + $Error[0].Exception.Message) }
        $status = 'pass'
    } catch {
        $status = 'FAIL'
        $detail = '{0} (line {1})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber
    }
    $script:smokeResults += [ordered]@{ check = $name; status = $status; detail = $detail }
    Write-Host ('  [{0}] {1}: {2}' -f $status, $name, $detail)
}
function Pump([int]$ms) {
    $until = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $until) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 }
}
function Expect([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }

Write-Host 'App screens (invisible smoke test)'
$form.Opacity = 0; $form.ShowInTaskbar = $false
$form.Show(); Pump 300

Check 'screens build without errors' {
    Expect ($buildErrors.Count -eq 0) ("{0} error(s) while building: {1}" -f $buildErrors.Count, ($buildErrors -join ' | '))
    'no errors'
}
Check 'all tabs open' {
    Expect ($tabs.TabPages.Count -eq 9) "expected 9 tabs, found $($tabs.TabPages.Count)"
    $names = @()
    for ($i = 0; $i -lt $tabs.TabPages.Count; $i++) {
        $tabs.SelectedIndex = $i; Pump 60
        $page = $tabs.TabPages[$i]
        Expect ($page.Controls.Count -ge 5) "tab '$($page.Text)' has only $($page.Controls.Count) controls"
        $names += $page.Text
    }
    $tabs.SelectedIndex = 0
    $names -join ', '
}
Check 'startup checks logged' {
    Expect ($log.Text -match 'Podcast Studio') 'the log box is empty after the window opened'
    "$(@($log.Lines).Count) log lines"
}
$savedName = $cName.Text
$cName.Text = '_smoketest'
$smokeDir = Join-Path $Work 'projects\_smoketest'
Check 'hook dropdown rewrites the outline' {
    $cOutline.Text = "TITLE: T`r`nHOOK: first`r`nBEATS:`r`n1. a`r`nCTA: c"
    $cHook.Items.Clear()
    foreach ($h in 'first', 'second hook', 'third') { [void]$cHook.Items.Add($h) }
    $cHook.SelectedIndex = 1
    Expect ($cOutline.Text -match 'HOOK: second hook') 'HOOK line was not replaced'
    Expect ($cOutline.Text -match 'TITLE: T' -and $cOutline.Text -match 'CTA: c') 'other outline lines were damaged'
    $cOutline.Text = ''; $cHook.Items.Clear()
    'HOOK line replaced'
}
Check 'project arguments' {
    $cPrompt.Text = 'smoke test prompt'
    $dir = Get-Project
    Expect ($dir -eq $smokeDir) "unexpected project folder: $dir"
    $argv = @(Get-ProjectArgs $dir 'outline')
    foreach ($need in '--project', '--stage', 'outline', '--prompt-file', '--seconds', '--format', '--model', '--stills', '--lipsync', '--soundbites', '--framing') {
        Expect ($argv -contains $need) "missing argument $need"
    }
    $cFrame.SelectedItem = 'Side by side'
    $argv = @(Get-ProjectArgs $dir 'outline')
    Expect ($argv[[array]::IndexOf($argv, '--framing') + 1] -eq 'side') 'framing choice was not passed on'
    $cFrame.SelectedIndex = 0
    Expect (Test-Path (Join-Path $dir 'prompt.txt')) 'prompt.txt was not written'
    $cPrompt.Text = ''
    "$($argv.Count) arguments"
}
Check 'scenes tab loads and selects' {
    $json = '{"title":"Smoke","scenes":[{"narration":"First line.","visual":"card","query":"q1","card_text":"Card one","image_prompt":""},' +
            '{"narration":"","visual":"soundbite","query":"cash flow","card_text":"","image_prompt":"","layout":"single-left"}]}'
    [System.IO.File]::WriteAllText((Join-Path $smokeDir 'script.json'), $json)
    Load-Scenes $true
    Expect ($eList.Items.Count -eq 2) "expected 2 scenes, list shows $($eList.Items.Count)"
    $eList.SelectedIndex = 0
    Expect ($eNarr.Text -eq 'First line.' -and $eCard.Text -eq 'Card one' -and [string]$eType.SelectedItem -eq 'card') 'scene 1 fields not filled in'
    Expect ($eLayout.SelectedIndex -eq 0) 'scene 1 should show the video default framing'
    $eList.SelectedIndex = 1
    Expect ([string]$eType.SelectedItem -eq 'soundbite' -and $eQuery.Text -eq 'cash flow') 'scene 2 fields not filled in'
    Expect ([string]$eLayout.SelectedItem -eq 'Left person') "scene 2 framing shows '$($eLayout.SelectedItem)'"
    Expect ((Get-FramingLabel 'wide') -eq 'Both in frame' -and (Get-FramingLabel 'nope') -eq '') 'framing labels are wrong'
    Expect ((Get-FramingLabel 'speaker') -eq 'Active speaker') 'active-speaker framing is missing'
    Expect ((Get-SceneNumber) -eq 2) 'scene number is wrong'
    [string]$eList.Items[1]
}
Check 'brand kit dialog opens and saves' {
    $tmp = Join-Path $smokeDir 'brand-smoke.json'
    Show-BrandKit $tmp
    Expect (Test-Path $tmp) 'brand file was not written'
    $kit = [System.IO.File]::ReadAllText($tmp) | ConvertFrom-Json
    foreach ($k in 'accent', 'background', 'text', 'caption_highlight', 'font', 'logo_position') {
        Expect ([bool]$kit.$k) "brand file is missing $k"
    }
    Expect ($kit.accent -match '^#[0-9A-F]{6}$') "accent is not a colour: $($kit.accent)"
    "accent $($kit.accent), font $($kit.font)"
}
Check 'highlights list' {
    $hEp.Text = Join-Path $smokeDir 'My Episode 01.mp4'
    $hdir = Get-HighlightsDir
    Expect ((Split-Path $hdir -Leaf) -eq 'My-Episode-01') "clips folder name is '$(Split-Path $hdir -Leaf)'"
    New-Item -ItemType Directory -Force -Path $hdir | Out-Null
    $json = '{"clips":[{"file":"C:\\x\\clip_01.mp4","score":90,"seconds":31.5,"framing":"speaker","title":"Cash is king","text":"why cash flow"},' +
            '{"file":"C:\\x\\clip_02.mp4","score":70,"seconds":22.0,"framing":"stack","title":"Hiring","text":"hiring is hard"}]}'
    [System.IO.File]::WriteAllText((Join-Path $hdir 'highlights.json'), $json)
    Load-Highlights
    Expect ($hList.Items.Count -eq 2 -and $script:hlClips.Count -eq 2) "expected 2 clips, list shows $($hList.Items.Count)"
    Expect ([string]$hList.Items[0] -match 'Cash is king' -and $script:hlClips[1] -eq 'C:\x\clip_02.mp4') 'clip rows are wrong'
    Expect ($Framings[[string]$hFrame.SelectedItem] -eq 'speaker') 'highlights should default to the active-speaker framing'
    Remove-Item $hdir -Recurse -Force
    $hEp.Text = ''; Load-Highlights
    [string]$hList.Items.Count + ' rows after clearing'
}
Check 'publish details save and load' {
    $file = Get-PublishFile
    [System.IO.File]::WriteAllText($file, '{"title":"Old","description":"line one\nline two","tags":"a, b","privacy":"unlisted","publish_at":"","video_id":"abc123","url":"https://youtu.be/abc123"}')
    Load-Publish $true
    Expect ($pTitle.Text -eq 'Old' -and [string]$pPrivacy.SelectedItem -eq 'unlisted' -and $pTags.Text -eq 'a, b') 'fields not loaded'
    Expect ($pDesc.Lines.Count -eq 2) 'description line breaks were lost'
    Expect ($script:pubUrl -eq 'https://youtu.be/abc123') 'uploaded link not picked up'
    $pTitle.Text = 'New title'; $pPrivacy.SelectedItem = 'private'; $pWhen.Text = '2099-12-01 09:30'
    Expect (Save-Publish) 'save failed'
    $doc = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json
    Expect ($doc.title -eq 'New title' -and $doc.privacy -eq 'private' -and $doc.publish_at -eq '2099-12-01 09:30') 'edits not saved'
    Expect ($doc.video_id -eq 'abc123' -and $doc.description -eq "line one`nline two") 'saving must keep the upload record and line breaks'
    $pTitle.Text = ''; $pDesc.Text = ''; $pTags.Text = ''; $pWhen.Text = ''; $pPrivacy.SelectedIndex = 0
    'saved and reloaded'
}
Check 'default model setting' {
    $settings = Join-Path $Work 'settings.json'
    $had = Test-Path $settings
    $keep = if ($had) { [System.IO.File]::ReadAllText($settings) } else { '' }
    $before = $cModel.Text
    [System.IO.File]::WriteAllText($settings, '{"model":"smoke-model:1b"}')
    Load-DefaultModel
    $seen = $cModel.Text
    if ($had) { [System.IO.File]::WriteAllText($settings, $keep) } else { Remove-Item $settings -Force }
    $cModel.Text = $before
    Expect ($seen -eq 'smoke-model:1b') "model box shows '$seen'"
    'model box follows settings.json'
}
Check 'recording tab and house rules' {
    Expect ((Get-Slug 'C:\x\My Take #3 (final).MOV') -eq 'my-take-3-final') "slug is '$(Get-Slug 'C:\x\My Take #3 (final).MOV')'"
    Expect ((Get-Slug '!!!.mp4') -eq 'recording') 'empty names need a fallback'
    $rSlug.Text = 'smoke-take'
    Expect ((Get-RecordingProject) -eq (Join-Path $Kit 'video-projects\smoke-take')) 'recording project path is wrong'
    $rKind.SelectedIndex = 1
    Expect ((Get-RecordingKind) -eq 'long') 'type box does not map to the long edit'
    $rKind.SelectedIndex = 0
    Expect ((Get-RecordingKind) -eq 'short') 'type box does not map to the short edit'
    Expect ($rTight.Checked -and $rMinutes.Text -eq '8') 'pause removal should be on and parts 8 minutes by default'
    Expect (('my-talk-part-03' -replace '-part-\d+$', '') -eq 'my-talk') 'part names do not map back to the base name'
    $rSlug.Text = ''
    $rules = Join-Path $smokeDir 'rules.md'
    Expect (Add-HouseRule "  Never   open with a greeting. " $rules) 'rule was not saved'
    Expect (-not (Add-HouseRule '   ' $rules)) 'an empty rule must be refused'
    [void](Add-HouseRule 'Keep hooks under ten words.' $rules)
    $text = [System.IO.File]::ReadAllText($rules)
    Expect ($text -match '# House rules' -and $text -match '- Never open with a greeting\.' -and $text -match '- Keep hooks under ten words\.') 'rules file content is wrong'
    Show-RuleDialog
    'slug, project path, type and rules file'
}
Check 'argument quoting' {
    Expect ((Q 'plain') -eq 'plain') 'plain value changed'
    Expect ((Q 'two words') -eq '"two words"') 'spaces not quoted'
    Expect ((Q 'C:\dir with space\') -eq '"C:\dir with space\\"') 'trailing backslash not doubled'
    Expect ((Q 'say "hi"') -eq '"say \"hi\""') 'inner quotes not escaped'
    'ok'
}
Check 'background job runs and reports' {
    Expect (Test-Path $Py) "Python environment missing at $Py"
    $script:smokeDone = $false
    Start-Job2 'smoke job' 'cmd.exe' @('/c', 'echo', 'smoke-job-ok') { $script:smokeDone = $true }
    $until = (Get-Date).AddSeconds(20)
    while (-not $script:smokeDone -and (Get-Date) -lt $until) { Pump 100 }
    Expect $script:smokeDone 'the job never reported completion'
    Expect ($log.Text -match 'smoke-job-ok') 'job output did not reach the log box'
    Expect ($status.Text -eq 'Done.') "status line shows '$($status.Text)'"
    'ran, output captured, completion handler fired'
}
Check 'failed job is reported' {
    $script:smokeDone = $false
    Start-Job2 'smoke failing job' 'cmd.exe' @('/c', 'exit', '3') { $script:smokeDone = $true }
    $until = (Get-Date).AddSeconds(20)
    while ($script:proc -and (Get-Date) -lt $until) { Pump 100 }
    Expect (-not $script:smokeDone) 'completion handler ran for a failed job'
    Expect ($status.Text -match 'Failed') "status line shows '$($status.Text)'"
    $status.Text
}
$cName.Text = $savedName
Remove-Item $smokeDir -Recurse -Force -ErrorAction SilentlyContinue

$failed = @($script:smokeResults | Where-Object { $_.status -eq 'FAIL' })
$report = [ordered]@{ when = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); passed = ($failed.Count -eq 0); results = $script:smokeResults }
[System.IO.File]::WriteAllText((Join-Path $LogDir 'gui-smoke.json'), ($report | ConvertTo-Json -Depth 5))
Write-Host ("App smoke test: {0} of {1} checks passed" -f ($script:smokeResults.Count - $failed.Count), $script:smokeResults.Count)
$form.Close(); $form.Dispose()
exit $failed.Count
'@
$files['Test-PodcastStudio.ps1'] = @'
# Podcast Studio self-test. Quick by default; -Full also loads the language model and the voice clone.
#   powershell -ExecutionPolicy Bypass -File Test-PodcastStudio.ps1 [-Full] [-Model gemma3:4b]
#   -NoGui skips the invisible app smoke test.
param([switch]$Full, [string]$Model = 'gemma3:4b', [switch]$NoGui)
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

if (-not $NoGui) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'PodcastStudio.ps1') -SmokeTest
    if ($LASTEXITCODE -ne 0) {
        $bad++
        Write-Host "  [FAIL] app smoke test - see $Root\logs\gui-smoke.json" -ForegroundColor Red
    }
}
exit $bad
'@
$files['common.py'] = @'
"""Shared helpers for Podcast Studio scripts."""
import importlib.util
import json
import os
import shutil
import subprocess
import sys

FORMATS = {"16:9": (1920, 1080), "9:16": (1080, 1920), "1:1": (1080, 1080)}
FF = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error"]


def log(msg):
    print(msg, flush=True)


def run(cmd, **kw):
    log("> " + " ".join(str(c) for c in cmd))
    subprocess.run([str(c) for c in cmd], check=True, **kw)


def fail(msg):
    log("ERROR: " + msg)
    sys.exit(1)


def ensure_dir(p):
    os.makedirs(p, exist_ok=True)
    return p


def read_text(path):
    """Read text written by PowerShell or Python (tolerates a UTF-8 BOM)."""
    with open(path, encoding="utf-8-sig") as f:
        return f.read()


def write_text(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def read_json(path, default=None):
    if not os.path.exists(path):
        return default
    return json.loads(read_text(path))


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "default=nw=1:nk=1", path], capture_output=True, text=True)
    try:
        return float(out.stdout.strip())
    except ValueError:
        return 0.0


def video_size(path):
    """(width, height) of the first video stream, or (0, 0)."""
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=width,height", "-of", "csv=p=0:s=x", path], capture_output=True, text=True)
    try:
        w, h = out.stdout.strip().split("x")[:2]
        return int(w), int(h)
    except ValueError:
        return 0, 0


def gpu_used_mb():
    """GPU memory in use right now (MiB) from nvidia-smi, or None."""
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=10)
        return int(out.stdout.strip().splitlines()[0])
    except Exception:
        return None


def record_metric(project_dir, stage, **values):
    """Append measurements (VRAM, seconds...) to <project>/metrics.json."""
    path = os.path.join(project_dir, "metrics.json")
    data = read_json(path, {})
    data.setdefault(stage, {}).update(values)
    write_json(path, data)


def _expose_torch_cuda_dlls():
    """faster-whisper (ctranslate2) needs cuBLAS/cuDNN DLLs; the PyTorch wheel ships them."""
    if os.name != "nt":
        return
    spec = importlib.util.find_spec("torch")
    if not spec or not spec.origin:
        return
    lib = os.path.join(os.path.dirname(spec.origin), "lib")
    if os.path.isdir(lib):
        os.environ["PATH"] = lib + os.pathsep + os.environ.get("PATH", "")
        try:
            os.add_dll_directory(lib)
        except OSError:
            pass


_whisper = {}


def studio_root():
    """The PodcastStudio folder (parent of the app folder), or PSTUDIO_ROOT when set."""
    return os.environ.get("PSTUDIO_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def settings():
    """workspace/settings.json: user choices such as {"model": ..., "encoder": "auto|cpu|nvenc", "proxies": true}."""
    data = read_json(os.path.join(studio_root(), "workspace", "settings.json"), {}) or {}
    return data if isinstance(data, dict) else {}


# ------------------------------------------------------------------ video encoding
# Every clip this app writes is tagged, so later steps know they can join clips without re-encoding them.
ENC_VERSION = "1"
X264 = ["-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p"]
NVENC_TRIES = (["-c:v", "h264_nvenc", "-preset", "p4", "-rc", "vbr", "-b:v", "0", "-pix_fmt", "yuv420p"],
               ["-c:v", "h264_nvenc", "-preset", "fast", "-rc", "vbr", "-b:v", "0", "-pix_fmt", "yuv420p"])
_encoder = {}


def _nvenc_args():
    """NVENC settings that work on this PC, or None. Tested once and remembered in logs/encoder.json."""
    cache = os.path.join(studio_root(), "logs", "encoder.json")
    ffmpeg = shutil.which("ffmpeg") or "ffmpeg"
    known = read_json(cache, {}) or {}
    if known.get("ffmpeg") == ffmpeg and "nvenc" in known:
        return known["nvenc"]
    found = None
    try:
        listing = subprocess.run([ffmpeg, "-hide_banner", "-encoders"], capture_output=True, text=True, timeout=20).stdout
        if "h264_nvenc" in listing:
            for args in NVENC_TRIES:
                test = subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                                       "color=c=black:s=320x240:r=30:d=0.5", *args, "-cq", "23", "-f", "null", "-"],
                                      capture_output=True, text=True, timeout=60)
                if test.returncode == 0:
                    found = args
                    break
    except (OSError, subprocess.TimeoutExpired):
        found = None
    try:
        os.makedirs(os.path.dirname(cache), exist_ok=True)
        write_json(cache, {"ffmpeg": ffmpeg, "nvenc": found})
    except OSError:
        pass
    return found


def encoder():
    """("x264" | "nvenc", base args). NVENC moves video encoding from the CPU to the graphics card's encoder chip.

    Choose with workspace/settings.json "encoder": "auto" (default), "cpu" or "nvenc", or PSTUDIO_ENCODER.
    """
    choice = (os.environ.get("PSTUDIO_ENCODER") or settings().get("encoder") or "auto").lower()
    if choice not in _encoder:
        nv = _nvenc_args() if choice in ("auto", "nvenc") else None
        if choice == "nvenc" and not nv:
            log("  NVENC was asked for but does not work here - using the CPU encoder")
        _encoder[choice] = ("nvenc", nv) if nv else ("x264", X264)
    return _encoder[choice]


def venc(quality=20):
    """Video encoder arguments for one output at `quality` (CRF-like: lower is better), plus this app's tag."""
    kind, args = encoder()
    q = ["-cq", str(quality + 1)] if kind == "nvenc" else ["-crf", str(quality)]
    return list(args) + q + ["-metadata", f"comment=pstudio-enc={kind}-{ENC_VERSION}"]


def enc_tag():
    return f"pstudio-enc={encoder()[0]}-{ENC_VERSION}"


def probe(path):
    """Key facts about a media file for deciding whether it can be joined without re-encoding."""
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                          "stream=codec_type,codec_name,profile,width,height,pix_fmt,r_frame_rate,sample_rate,channels"
                          ":format=duration:format_tags=comment", "-of", "json", path], capture_output=True, text=True)
    try:
        data = json.loads(out.stdout or "{}")
    except json.JSONDecodeError:
        data = {}
    info = {"tag": (data.get("format", {}).get("tags", {}) or {}).get("comment", ""),
            "duration": float(data.get("format", {}).get("duration") or 0)}
    for st in data.get("streams", []):
        kind = st.get("codec_type")
        if kind == "video" and "video" not in info:
            info["video"] = (st.get("codec_name"), st.get("profile"), st.get("width"), st.get("height"),
                             st.get("pix_fmt"), st.get("r_frame_rate"))
        elif kind == "audio" and "audio" not in info:
            info["audio"] = (st.get("codec_name"), st.get("sample_rate"), st.get("channels"))
    return info


def joinable(paths, width, height, fps="30/1"):
    """True when every clip was written by this app's current encoder at this size and frame rate, with AAC
    48 kHz stereo sound, so they can be joined by copying (no re-encode)."""
    tag = enc_tag()
    first = None
    for p in paths:
        info = probe(p)
        v, a = info.get("video"), info.get("audio")
        if info["tag"] != tag or not v or not a or v[2:4] != (width, height) or v[4] != "yuv420p" or v[5] != fps:
            return False
        if a != ("aac", "48000", 2):
            return False
        if first is None:
            first = v
        elif v != first:
            return False
    return bool(paths)


def free_gpu():
    """Unload any language model Ollama is holding so the graphics card's memory is free for the next model."""
    try:
        import llm
        llm.unload_all()
    except Exception:  # noqa: BLE001 - Ollama not installed or not running: nothing to free
        pass


# ------------------------------------------------------------------ transcription
def _faster_whisper(path, model_size, language, device, words):
    """Run faster-whisper. Returns [{"start", "end", "text", "words": [[start, end, word], ...]}]."""
    _expose_torch_cuda_dlls()
    from faster_whisper import WhisperModel

    attempts = (("cuda", "int8_float16"), ("cuda", "int8"), ("cpu", "int8"))
    if device == "cpu":
        attempts = attempts[2:]
    last = None
    for dev, compute in attempts:
        key = (model_size, dev, compute)
        try:
            if key not in _whisper:
                log(f"Loading whisper-{model_size} on {dev} ({compute})...")
                _whisper[key] = WhisperModel(model_size, device=dev, compute_type=compute)
            segments, info = _whisper[key].transcribe(path, language=language, vad_filter=True,
                                                      word_timestamps=bool(words))
            out = []
            for s in segments:
                seg = {"start": s.start, "end": s.end, "text": s.text.strip(), "words": []}
                for w in (getattr(s, "words", None) or []) if words else []:
                    if w.word.strip():
                        seg["words"].append([round(w.start, 2), round(w.end, 2), w.word.strip()])
                out.append(seg)
            return out
        except Exception as e:  # missing CUDA DLLs, OOM, etc.
            _whisper.pop(key, None)
            last = e
            log(f"  {dev}/{compute} failed: {e}")
    raise RuntimeError(f"Transcription failed: {last}")


def whisperx_exe():
    """Path to the optional WhisperX program (its own environment), or None."""
    cand = [os.environ.get("PSTUDIO_WHISPERX"),
            os.path.join(studio_root(), "venv-whisperx", "Scripts", "whisperx.exe"),
            os.path.join(studio_root(), "venv-whisperx", "bin", "whisperx")]
    return next((c for c in cand if c and os.path.exists(c)), None)


def _whisperx(exe, path, model_size, language):
    """Run WhisperX (forced word alignment; speaker labels when HF_TOKEN is set). Same shape as _faster_whisper."""
    import tempfile

    tmp = tempfile.mkdtemp(prefix="pstudio_wx_")
    cmd = [exe, path, "--model", model_size, "--output_dir", tmp, "--output_format", "json",
           "--compute_type", "int8", "--batch_size", "4"]
    if language:
        cmd += ["--language", language]
    token = os.environ.get("HF_TOKEN")
    if token:
        cmd += ["--diarize", "--hf_token", token, "--min_speakers", "1", "--max_speakers", "4"]
    log("Transcribing with WhisperX" + (" (with speaker labels)" if token else "") + "...")
    done = subprocess.run(cmd, capture_output=True, text=True)
    files = [f for f in os.listdir(tmp) if f.endswith(".json")]
    if done.returncode != 0 or not files:
        raise RuntimeError((done.stderr or done.stdout or "no output")[-400:])
    data = read_json(os.path.join(tmp, files[0]))
    out = []
    for s in data.get("segments", []):
        seg = {"start": float(s["start"]), "end": float(s["end"]), "text": str(s.get("text", "")).strip(), "words": []}
        if s.get("speaker"):
            seg["speaker"] = s["speaker"]
        for w in s.get("words", []):
            if "start" in w and "end" in w and str(w.get("word", "")).strip():
                seg["words"].append([round(float(w["start"]), 2), round(float(w["end"]), 2), str(w["word"]).strip()])
        out.append(seg)
    import shutil
    shutil.rmtree(tmp, ignore_errors=True)
    return out


def _transcribe_piece(path, model_size, language, device):
    exe = whisperx_exe()
    if exe and device != "cpu":
        try:
            return _whisperx(exe, path, model_size, language)
        except Exception as e:  # noqa: BLE001
            log(f"  WhisperX failed ({e}); using the built-in transcriber")
    return _faster_whisper(path, model_size, language, device, words=True)


def chunk_seconds():
    return float(os.environ.get("PSTUDIO_CHUNK_SECONDS") or 600)


def _clock(t):
    return f"{int(t // 60)}:{int(t % 60):02}"


def transcribe_words(path, model_size="small", language=None, device=None, cache=None):
    """Transcribe with word-level timing: [{"start", "end", "text", "words": [[start, end, word]], "speaker"?}].

    Uses WhisperX when its optional environment is installed (more exact word timing, and who-said-what
    when HF_TOKEN is set); otherwise faster-whisper's built-in word timestamps.

    Long recordings are done in 10-minute pieces from a small 16 kHz copy of the sound. Each piece starts where
    the last finished sentence ended, so no word is cut in half. With `cache` (a JSON path) finished pieces are
    saved, and an interrupted run carries on where it stopped.
    """
    import tempfile

    total, step, overlap = duration(path), chunk_seconds(), 30.0
    if total <= step + overlap:
        return _transcribe_piece(path, model_size, language, device)
    state = read_json(cache, None) if cache else None
    if not (isinstance(state, dict) and state.get("source") == os.path.abspath(path) and state.get("total") == round(total, 2)):
        state = {"source": os.path.abspath(path), "total": round(total, 2), "next": 0.0, "segments": []}
    elif state["next"] > 0:
        log(f"  resuming the transcript at {_clock(state['next'])}")
    tmp = tempfile.mkdtemp(prefix="pstudio_tx_")
    try:
        sound = os.path.join(tmp, "sound.wav")       # decode the recording once: 16 kHz mono is ~2 MB a minute
        subprocess.run(FF + ["-i", path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", sound], check=True)
        t = state["next"]
        while t < total - 0.5:
            length = min(step + overlap, total - t)
            last = t + length >= total - 0.5
            piece = os.path.join(tmp, "piece.wav")
            subprocess.run(FF + ["-ss", f"{t:.3f}", "-t", f"{length:.3f}", "-i", sound, "-c:a", "pcm_s16le", piece],
                           check=True)
            segs = _transcribe_piece(piece, model_size, language, device)
            keep = [s for s in segs if last or s["start"] < step]
            for s in keep:
                s["start"], s["end"] = round(s["start"] + t, 2), round(s["end"] + t, 2)
                s["words"] = [[round(a + t, 2), round(b + t, 2), w] for a, b, w in s.get("words") or []]
            state["segments"] += keep
            nxt = keep[-1]["end"] if keep and not last else t + step
            t = total if last else max(nxt, t + 1.0)
            state["next"] = round(t, 2)
            if cache:
                write_json(cache, state)
            log(f"  transcribed {_clock(min(t, total))} of {_clock(total)}")
        return state["segments"]
    finally:
        import shutil as _shutil
        _shutil.rmtree(tmp, ignore_errors=True)


def transcribe(path, model_size="small", language=None, device=None):
    """Transcribe with faster-whisper. Tries the GPU first, falls back to CPU int8.

    `device="cpu"` skips the GPU (used while another model is holding the VRAM).
    Returns [(start, end, text)].
    """
    return [(s["start"], s["end"], s["text"]) for s in _faster_whisper(path, model_size, language, device, False)]


def _plain_words(text):
    import re
    return re.findall(r"[a-z0-9']+", text.lower())


def speech_match(wav, text, device=None):
    """Share of the script's words that speech-to-text hears in `wav` (0-1). Catches garbled speech."""
    want = _plain_words(text)
    heard = set(_plain_words(" ".join(t for _, _, t in transcribe(wav, device=device))))
    return sum(1 for w in want if w in heard) / (len(want) or 1)


def srt_time(t):
    h, rem = divmod(t, 3600)
    m, s = divmod(rem, 60)
    ms = int(round((s - int(s)) * 1000))
    if ms == 1000:
        s, ms = s + 1, 0
    return f"{int(h):02}:{int(m):02}:{int(s):02},{ms:03}"


def write_srt(segs, path, max_words=7):
    """Write SRT, splitting long segments into short caption chunks."""
    idx = 1
    with open(path, "w", encoding="utf-8") as f:
        for start, end, text in segs:
            words = text.split()
            if not words:
                continue
            chunks = [words[i:i + max_words] for i in range(0, len(words), max_words)]
            dur = (end - start) / len(chunks)
            for j, chunk in enumerate(chunks):
                a, b = start + j * dur, start + (j + 1) * dur
                f.write(f"{idx}\n{srt_time(a)} --> {srt_time(b)}\n{' '.join(chunk)}\n\n")
                idx += 1
'@
$files['llm.py'] = @'
"""Local language model + embeddings through Ollama (http://127.0.0.1:11434). No cloud calls."""
import json
import os
import subprocess
import time
import urllib.error
import urllib.request

from common import log

HOST = os.environ.get("OLLAMA_HOST_URL", "http://127.0.0.1:11434")
DEFAULT_MODEL = "gemma3:4b"
FALLBACK_MODELS = ["gemma3:4b", "qwen3:4b", "phi4-mini", "llama3.2:3b"]
EMBED_MODEL = "nomic-embed-text"


def _post(path, payload, timeout=900):
    req = urllib.request.Request(HOST + path, data=json.dumps(payload).encode("utf-8"),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def _get(path, timeout=5):
    with urllib.request.urlopen(HOST + path, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def server_up():
    try:
        _get("/api/version")
        return True
    except Exception:
        return False


def ensure_server():
    """Start `ollama serve` in the background if it is not answering."""
    if server_up():
        return
    log("Starting Ollama...")
    flags = 0x00000008 | 0x08000000 if os.name == "nt" else 0  # DETACHED_PROCESS | CREATE_NO_WINDOW
    try:
        subprocess.Popen(["ollama", "serve"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         creationflags=flags)
    except FileNotFoundError:
        raise RuntimeError("Ollama is not installed. Re-run Setup-PodcastStudio.ps1.")
    for _ in range(40):
        time.sleep(0.5)
        if server_up():
            return
    raise RuntimeError("Ollama did not start. Run 'ollama serve' in a terminal to see why.")


def models():
    try:
        return [m["name"] for m in _get("/api/tags").get("models", [])]
    except Exception:
        return []


def ensure_model(name):
    have = models()
    if name in have or (":" not in name and name + ":latest" in have):
        return
    log(f"Downloading model {name} (one time)...")
    subprocess.run(["ollama", "pull", name], check=True)


def _installed(name, have):
    return name in have or (":" not in name and name + ":latest" in have)


def pick_model(preferred=DEFAULT_MODEL):
    """Return a usable chat model: the preferred one, else pull it, else any installed fallback."""
    ensure_server()
    have = models()
    if _installed(preferred, have):
        return preferred
    try:
        ensure_model(preferred)
        return preferred
    except Exception as e:  # unknown name, offline...
        log(f"Could not get model {preferred} ({e}).")
    chat_models = [h for h in have if "embed" not in h]
    for cand in FALLBACK_MODELS + chat_models:
        if _installed(cand, have):
            log(f"Using installed model {cand} instead.")
            return cand
    raise RuntimeError(f"No local chat model is installed. Run: ollama pull {DEFAULT_MODEL}")


CONTEXT_SIZES = (2048, 4096, 6144, 8192)


def context_size(system, user, reply_tokens=1536):
    """The smallest context window that fits this request.

    The model's working memory for the conversation (its KV cache) grows with the window: for a 4B model a
    window of 8192 takes about 1 GB of graphics memory, 4096 about half that. On a 4 GB card a needlessly large
    window pushes part of the model onto the CPU, which is several times slower.
    """
    need = (len(system) + len(user)) / 3.2 + reply_tokens      # about 3.2 characters per token for English
    return next((c for c in CONTEXT_SIZES if c >= need), CONTEXT_SIZES[-1])


def chat(system, user, model=DEFAULT_MODEL, as_json=False, temperature=0.7, num_ctx=None, schema=None,
         keep_alive=0, reply_tokens=1536):
    """One chat turn.

    keep_alive=0 unloads the model afterwards so the GPU is free for the next stage. Loops that make several
    calls in a row pass keep_alive="5m" and call unload() when they finish, so the model loads once, not every call.
    `schema` (a JSON schema dict) makes Ollama constrain the reply to that shape; older Ollama
    versions that reject it fall back to plain JSON mode.
    """
    model = pick_model(model)
    payload = {
        "model": model,
        "stream": False,
        "keep_alive": keep_alive,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "options": {"temperature": temperature,
                    "num_ctx": num_ctx or context_size(system, user, reply_tokens)},
    }
    if schema:
        as_json = True
        payload["format"] = schema
    elif as_json:
        payload["format"] = "json"
    try:
        try:
            out = _post("/api/chat", payload)
        except urllib.error.HTTPError as e:
            if not (schema and e.code == 400):
                raise
            payload["format"] = "json"
            out = _post("/api/chat", payload)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Ollama error {e.code}: {e.read().decode('utf-8', 'ignore')[:300]}")
    text = out.get("message", {}).get("content", "").strip()
    if not as_json:
        return text
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        a, b = text.find("{"), text.rfind("}")
        if a >= 0 and b > a:
            return json.loads(text[a:b + 1])
        raise RuntimeError("Model did not return valid JSON:\n" + text[:500])


def embed(texts, model=EMBED_MODEL, batch=32):
    """Return a list of embedding vectors (lists of floats). The model stays loaded between batches."""
    ensure_server()
    ensure_model(model)
    vectors = []
    for i in range(0, len(texts), batch):
        last = i + batch >= len(texts)
        out = _post("/api/embed", {"model": model, "input": texts[i:i + batch], "keep_alive": 0 if last else "2m"})
        vectors.extend(out["embeddings"])
    return vectors


def unload(model):
    """Free the graphics memory a model is using (no-op if it is not loaded)."""
    try:
        _post("/api/generate", {"model": model, "keep_alive": 0}, timeout=30)
    except Exception:  # noqa: BLE001
        pass


def unload_all():
    """Unload every model Ollama has in memory. Does nothing if Ollama is not running (it is not started)."""
    if not server_up():
        return []
    try:
        loaded = [m.get("name") or m.get("model") for m in _get("/api/ps").get("models", [])]
    except Exception:  # noqa: BLE001
        return []
    for name in loaded:
        if name:
            unload(name)
    if loaded:
        log(f"  freed graphics memory held by {', '.join(loaded)}")
    return loaded
'@
$files['library.py'] = @'
"""Footage library: transcribe your episodes once, then find the moment that matches a line of script.

Index:  python library.py index <folder-with-videos> --lib <workspace>/library
Search: python library.py search "topic words" --lib <workspace>/library
"""
import argparse
import hashlib
import math
import os
import re

from common import ensure_dir, fail, log, read_json, transcribe_words, write_json

VIDEO_EXT = (".mp4", ".mov", ".mkv", ".webm", ".m4v")
WINDOW = 20.0  # seconds of speech per searchable chunk


def _chunks(segs):
    """Group transcript segments into ~20 s chunks: (start, end, text, [[start, end, text]], [[start, end, word]])."""
    out, cur = [], None
    for seg in segs:
        start, end, text = seg["start"], seg["end"], seg["text"]
        row = [round(start, 2), round(end, 2), text]
        if cur is None:
            cur = [start, end, text, [row], list(seg.get("words") or [])]
        elif end - cur[0] <= WINDOW:
            cur[1], cur[2] = end, cur[2] + " " + text
            cur[3].append(row)
            cur[4] += seg.get("words") or []
        else:
            out.append(tuple(cur))
            cur = [start, end, text, [row], list(seg.get("words") or [])]
    if cur:
        out.append(tuple(cur))
    return out


def pick_soundbite(chunk, query, min_s=4.0, max_s=10.0):
    """Choose a 4-10 s spoken passage inside a chunk.

    Returns (start, seconds, [(rel_start, rel_end, text)], [[rel_start, rel_end, word]]).
    With word timing in the index the cut starts on the first word and ends on the last.
    """
    segs = chunk.get("segs") or [[chunk["start"], chunk["end"], chunk["text"]]]
    qw = set(_words(query))
    best = max(range(len(segs)), key=lambda i: (len(qw & set(_words(segs[i][2]))), -i))
    start, end, picked = segs[best][0], segs[best][1], [segs[best]]
    for seg in segs[best + 1:]:
        if end - start >= min_s or seg[1] - start > max_s:
            break
        picked.append(seg)
        end = seg[1]
    end = min(end, start + max_s)
    words = [w for w in chunk.get("words") or [] if w[0] >= start - 0.05 and w[1] <= end + 0.05]
    if words:
        start, end = max(0.0, words[0][0] - 0.12), words[-1][1]
    rel = [(max(0.0, a - start), min(b, end) - start, t) for a, b, t in picked if a < end]
    rel_words = [[round(max(0.0, a - start), 2), round(b - start, 2), w] for a, b, w in words]
    return round(start, 2), round(end - start + 0.2, 2), rel, rel_words


def index(folder, lib, whisper="small", use_embeddings=True, proxies=None):
    """Transcribe every video in `folder` into the searchable index. Long episodes are done in 10-minute pieces
    and an interrupted run resumes. Footage larger than 1080p also gets a 1080p working copy (see visuals.make_proxy),
    unless workspace/settings.json says "proxies": false."""
    from common import free_gpu, settings
    if proxies is None:
        proxies = settings().get("proxies", True) is not False
    free_gpu()
    ensure_dir(lib)
    path = os.path.join(lib, "index.json")
    data = read_json(path, {"files": {}, "chunks": []})
    videos = []
    for root, _, names in os.walk(folder):
        videos += [os.path.join(root, n) for n in names if n.lower().endswith(VIDEO_EXT)]
    if not videos:
        fail(f"No videos found in {folder}")
    for n, video in enumerate(sorted(videos), 1):
        stamp = f"{os.path.getsize(video)}-{int(os.path.getmtime(video))}"
        mine = [c for c in data["chunks"] if c["file"] == video]
        if data["files"].get(video) == stamp and mine and all("words" in c for c in mine):
            log(f"[{n}/{len(videos)}] already indexed: {os.path.basename(video)}")
            continue
        if data["files"].get(video) == stamp:
            log(f"[{n}/{len(videos)}] upgrading the index with word timing: {os.path.basename(video)}")
        log(f"[{n}/{len(videos)}] indexing {os.path.basename(video)}")
        data["chunks"] = [c for c in data["chunks"] if c["file"] != video]
        partial = os.path.join(lib, "partial", hashlib.sha1(f"{video}|{stamp}".encode("utf-8")).hexdigest()[:16] + ".json")
        os.makedirs(os.path.dirname(partial), exist_ok=True)
        for start, end, text, segs, words in _chunks(transcribe_words(video, whisper, cache=partial)):
            data["chunks"].append({"file": video, "start": round(start, 2), "end": round(end, 2),
                                   "text": text, "segs": segs, "words": words})
        data["files"][video] = stamp
        write_json(path, data)  # save after every file so a long run can resume
        if os.path.exists(partial):
            os.remove(partial)
    if proxies:
        import visuals
        for video in sorted(videos):
            try:
                visuals.make_proxy(video)
            except Exception as e:  # noqa: BLE001 - a missing working copy only makes later cuts slower
                log(f"  could not make a working copy of {os.path.basename(video)}: {e}")

    if use_embeddings:
        todo = [c for c in data["chunks"] if "vec" not in c]
        if todo:
            try:
                import llm
                log(f"Embedding {len(todo)} chunks with {llm.EMBED_MODEL}...")
                for c, v in zip(todo, llm.embed([c["text"] for c in todo])):
                    c["vec"] = [round(x, 5) for x in v]
                write_json(path, data)
            except Exception as e:
                log(f"Embeddings unavailable ({e}); keyword search will be used.")
    log(f"Library ready: {len(data['files'])} videos, {len(data['chunks'])} chunks -> {path}")


def _words(text):
    return [w for w in re.findall(r"[a-z0-9']+", text.lower()) if len(w) > 2]


def _cos(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na, nb = math.sqrt(sum(x * x for x in a)), math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


class Library:
    def __init__(self, lib):
        self.data = read_json(os.path.join(lib, "index.json"), {"files": {}, "chunks": []})
        self.chunks = [c for c in self.data["chunks"] if os.path.exists(c["file"])]
        self.used = set()

    def __len__(self):
        return len(self.chunks)

    def mark_used(self, file, start):
        """Exclude the chunk that contains this moment from later searches."""
        for c in self.chunks:
            if c["file"] == file and c["start"] - 0.01 <= start < max(c["end"], c["start"] + 0.02):
                self.used.add((c["file"], c["start"]))

    def search(self, query, avoid_reuse=True):
        """Best matching chunk for `query`, or None. Meaning search first, keyword overlap as fallback."""
        if not self.chunks:
            return None
        scores = None
        if all("vec" in c for c in self.chunks):
            try:
                import llm
                q = llm.embed([query])[0]
                scores = [_cos(q, c["vec"]) for c in self.chunks]
            except Exception as e:
                log(f"  embedding search failed ({e}); using keywords")
        if scores is None:
            qw = set(_words(query))
            scores = [len(qw & set(_words(c["text"]))) / (len(qw) or 1) for c in self.chunks]
        order = sorted(range(len(scores)), key=lambda i: -scores[i])
        for i in order:
            key = (self.chunks[i]["file"], self.chunks[i]["start"])
            if avoid_reuse and key in self.used:
                continue
            self.used.add(key)
            return dict(self.chunks[i], score=round(scores[i], 3))
        return None


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    i = sub.add_parser("index")
    i.add_argument("folder")
    i.add_argument("--lib", required=True)
    i.add_argument("--whisper", default="small")
    i.add_argument("--no-embeddings", action="store_true")
    i.add_argument("--no-proxies", action="store_true", help="Do not make 1080p working copies of 4K footage")
    s = sub.add_parser("search")
    s.add_argument("query")
    s.add_argument("--lib", required=True)
    a = ap.parse_args()
    if a.cmd == "index":
        index(a.folder, a.lib, a.whisper, not a.no_embeddings, proxies=False if a.no_proxies else None)
    else:
        hit = Library(a.lib).search(a.query)
        log(str(hit and {k: v for k, v in hit.items() if k != "vec"}))


if __name__ == "__main__":
    main()
'@
$files['visuals.py'] = @'
"""Local visuals: text cards (Pillow), pan-and-zoom on stills (ffmpeg), AI stills (SD 1.5), footage cuts."""
import argparse
import os
import textwrap

from common import FF, FORMATS, duration, log, run, venc

FONTS = [r"C:\Windows\Fonts\segoeuib.ttf", r"C:\Windows\Fonts\arialbd.ttf",
         "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
         "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf"]
SD_MODEL = "stable-diffusion-v1-5/stable-diffusion-v1-5"


def _font(size, preferred=()):
    from PIL import ImageFont
    for path in list(preferred) + FONTS:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def card_image(text, out_png, fmt="9:16", kicker=None, brand=None, canvas=None, body=None):
    """Render a title/quote card as a PNG in the brand colours: gradient, accent bar, centred wrapped text.

    `canvas=(width, height)` overrides the video shape (used for carousel slides); `body` adds smaller text below.
    """
    from PIL import Image, ImageDraw

    import brand as brandkit

    kit = brand or brandkit.load()
    accent, ink, base = brandkit.rgb(kit["accent"]), brandkit.rgb(kit["text"]), brandkit.rgb(kit["background"], (32, 34, 62))
    fonts = brandkit.font_files(kit)
    W, H = canvas or FORMATS[fmt]
    column = Image.new("RGB", (1, H))
    for y in range(H):  # darker at the top, the brand background colour at the bottom
        t = 0.45 + 0.55 * y / H
        column.putpixel((0, y), tuple(int(c * t) for c in base))
    img = column.resize((W, H))
    draw = ImageDraw.Draw(img)

    text = " ".join(text.split())
    size = int(min(W, H) * (0.10 if len(text) < 40 else 0.075 if len(text) < 90 else 0.058))
    while True:
        font = _font(size, fonts)
        per_line = max(8, int(W * 0.84 / (size * 0.56)))
        lines = textwrap.wrap(text, per_line) or [""]
        line_h = int(size * 1.25)
        if line_h * len(lines) <= H * 0.6 or size <= 24:
            break
        size = int(size * 0.9)

    body_font = _font(int(size * 0.5), fonts)
    body_lines = textwrap.wrap(" ".join(body.split()), max(12, int(W * 0.8 / (size * 0.5 * 0.56)))) if body else []
    body_h = int(size * 0.5 * 1.4)
    block_h = line_h * len(lines) + (int(size * 0.6) + body_h * len(body_lines) if body_lines else 0)
    y = (H - block_h) // 2
    bar_w, bar_h = int(W * 0.12), max(6, int(size * 0.14))
    draw.rectangle([(W - bar_w) // 2, y - bar_h * 4, (W + bar_w) // 2, y - bar_h * 3], fill=accent)
    if kicker:
        kf = _font(int(size * 0.45), fonts)
        kw = draw.textlength(kicker.upper(), font=kf)
        draw.text(((W - kw) // 2, y - bar_h * 4 - int(size * 0.8)), kicker.upper(), font=kf, fill=accent)
    for line in lines:
        w = draw.textlength(line, font=font)
        draw.text(((W - w) // 2 + 3, y + 3), line, font=font, fill=(0, 0, 0))
        draw.text(((W - w) // 2, y), line, font=font, fill=ink)
        y += line_h
    y += int(size * 0.6)
    for line in body_lines:
        w = draw.textlength(line, font=body_font)
        draw.text(((W - w) // 2, y), line, font=body_font, fill=tuple(int(c * 0.85) for c in ink))
        y += body_h
    img.save(out_png)
    return out_png


def kenburns(image, out_mp4, seconds, fmt="9:16", zoom=0.10):
    """Turn a still into a clip with a slow zoom and a short fade-in (CPU)."""
    W, H = FORMATS[fmt]
    frames = max(2, int(round(seconds * 30)))
    step = zoom / frames
    vf = (f"scale={W * 2}:{H * 2}:force_original_aspect_ratio=increase,crop={W * 2}:{H * 2},"
          f"zoompan=z='min(1+{step:.7f}*on,{1 + zoom})':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'"
          f":d={frames}:s={W}x{H}:fps=30,fade=t=in:st=0:d=0.3,format=yuv420p")
    run(FF + ["-i", image, "-vf", vf, "-frames:v", frames, *venc(20), "-an", out_mp4])
    return out_mp4


def card_clip(text, out_mp4, seconds, fmt="9:16", kicker=None, brand=None):
    png = os.path.splitext(out_mp4)[0] + ".png"
    card_image(text, png, fmt, kicker, brand)
    return kenburns(png, out_mp4, seconds, fmt, zoom=0.05)


YUNET = "face_detection_yunet_2023mar.onnx"   # OpenCV Zoo face detector, MIT licence, 232 KB
_face_note = []


def _face_finder(width, height):
    """A function frame -> [(x, y, w, h)] in pixels. YuNet when its model file is present, else the older Haar finder."""
    import cv2
    from common import studio_root

    model = os.environ.get("PSTUDIO_YUNET") or os.path.join(studio_root(), "models", YUNET)
    if os.path.exists(model) and hasattr(cv2, "FaceDetectorYN"):
        net = cv2.FaceDetectorYN.create(model, "", (width, height), 0.7, 0.3, 50)

        def yunet(frame):
            _, found = net.detect(frame)
            return [] if found is None else [tuple(float(v) for v in row[:4]) for row in found]
        return yunet
    if not _face_note:
        _face_note.append(log("  (face model file missing - using the less reliable built-in face finder)"))
    cascade = cv2.CascadeClassifier(os.path.join(cv2.data.haarcascades, "haarcascade_frontalface_default.xml"))

    def haar(frame):
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        return [tuple(float(v) for v in f) for f in cascade.detectMultiScale(
            gray, scaleFactor=1.1, minNeighbors=6, minSize=(int(height * 0.08),) * 2)]
    return haar


def detect_faces(src, start, seconds, samples=6):
    """Faces in a few sampled frames: [[(centre_x, centre_y, width) as 0-1 fractions, ...] per frame].

    Runs on the CPU. Returns [] if OpenCV is unavailable.
    """
    try:
        import cv2
    except ImportError:
        return []
    cap = cv2.VideoCapture(src)
    if not cap.isOpened():
        return []
    frames, finder = [], None
    for i in range(samples):
        cap.set(cv2.CAP_PROP_POS_MSEC, (start + seconds * (i + 0.5) / samples) * 1000)
        ok, frame = cap.read()
        if not ok:
            continue
        h, w = frame.shape[:2]
        scale = 640.0 / w if w > 640 else 1.0
        small = cv2.resize(frame, (int(w * scale), int(h * scale)))
        sh, sw = small.shape[:2]
        finder = finder or _face_finder(sw, sh)
        frames.append([((x + fw / 2) / sw, (y + fh / 2) / sh, fw / sw) for x, y, fw, fh in finder(small)])
    cap.release()
    return frames


def _median(values):
    values = sorted(values)
    return values[len(values) // 2]


FRAMINGS = ("auto", "stack", "side", "wide", "single", "single-left", "single-right", "speaker")
ASSUMED_HOSTS = ((0.27, 0.40), (0.73, 0.40))  # where two hosts usually sit when their faces cannot be found


def _host_pairs(frames):
    """Frames that show two plausible seated hosts: well separated, similar size, heads at a similar height.

    The basic face finder sometimes reports a face where there is none; such false faces rarely sit level
    with a real one or stay put, so these rules (and the 70% rule in the callers) filter most of them out.
    """
    with_faces = [f for f in frames if f]
    pairs = []
    for f in with_faces:
        if len(f) < 2:
            continue
        a, b = sorted(f, key=lambda face: -face[2])[:2]
        if abs(a[0] - b[0]) >= 0.25 and b[2] >= 0.35 * a[2] and abs(a[1] - b[1]) <= 0.25:
            pairs.append(sorted((a, b)))
    return pairs if len(pairs) >= 2 and len(pairs) >= 0.7 * len(with_faces) else [], with_faces


def find_hosts(frames):
    """(left, right, biggest): median face positions of two hosts side by side, and of the largest face.

    left/right are None unless two hosts show up in most frames.
    """
    pairs, with_faces = _host_pairs(frames)
    left = right = biggest = None
    if pairs:
        left = (float(_median([p[0][0] for p in pairs])), float(_median([p[0][1] for p in pairs])))
        right = (float(_median([p[1][0] for p in pairs])), float(_median([p[1][1] for p in pairs])))
    if len(with_faces) >= 2:
        big = [max(f, key=lambda face: face[2]) for f in with_faces]
        biggest = (float(_median([b[0] for b in big])), float(_median([b[1] for b in big])))
    return left, right, biggest


def find_host_boxes(frames):
    """Face boxes (centre_x, centre_y, width as 0-1) for the active-speaker model: [left, right], [one] or []."""
    pairs, with_faces = _host_pairs(frames)
    if pairs:
        return [tuple(float(_median([p[k][d] for p in pairs])) for d in range(3)) for k in (0, 1)]
    if len(with_faces) >= 2:
        big = [max(f, key=lambda face: face[2]) for f in with_faces]
        return [tuple(float(_median([b[d] for b in big])) for d in range(3))]
    return []


def plan_layout(frames, vertical=True, choice="auto"):
    """Decide how to frame footage.

    choice        result
    auto          stack when two hosts are found in a vertical video, else single, else centre
    stack         ("stack", left, right)   one host above the other
    side          ("side", left, right)    split screen, hosts next to each other
    wide          ("wide", left, right)    both hosts in one frame (left/right may be None)
    single        ("single", centre)       the larger face; ("center",) when no face is found
    single-left   ("single", left)         the host on the left
    single-right  ("single", right)        the host on the right
    When a two-host choice is asked for and two faces cannot be found, typical seat positions are assumed.
    """
    left, right, biggest = find_hosts(frames)
    if choice == "speaker":      # following the speaker is done in footage_clip; this is its fallback
        choice = "auto"
    if choice == "auto":
        if vertical and left:
            return ("stack", left, right)
        return ("single", biggest) if biggest else ("center",)
    if choice == "single":
        return ("single", biggest) if biggest else ("center",)
    if choice == "wide":
        return ("wide", left, right)
    if not left:
        left, right = ASSUMED_HOSTS
    if choice == "single-left":
        return ("single", left)
    if choice == "single-right":
        return ("single", right)
    return (choice, left, right)


def crop_offsets(src_w, src_h, W, H, center=None, zoom=1.0):
    """Scale-to-cover size and crop origin that keep `center` (0-1 fractions) in frame."""
    f = max(W / src_w, H / src_h) * zoom
    sw, sh = int(round(src_w * f / 2)) * 2, int(round(src_h * f / 2)) * 2
    cx, cy = center or (0.5, 0.5)
    if center:
        cy = min(0.5, cy + 0.1) if zoom == 1.0 else cy + 0.04  # leave headroom, keep room for captions
    x = int(min(max(cx * sw - W / 2, 0), max(sw - W, 0)))
    y = int(min(max(cy * sh - H / 2, 0), max(sh - H, 0)))
    return sw, sh, x, y


def _even(n):
    return max(2, int(n) // 2 * 2)


def _pane(src_w, src_h, pw, ph, face, show, source, name):
    """One host's box: zoomed so it shows about `show` of the original frame's width."""
    zoom = max(1.0, (pw / (show * src_w)) / max(pw / src_w, ph / src_h))
    sw, sh, x, y = crop_offsets(src_w, src_h, pw, ph, face, zoom)
    return f"[{source}]scale={sw}:{sh},crop={pw}:{ph}:{x}:{y}[{name}]"


def _backdrop(src_w, src_h, W, H, source):
    """A blurred, darkened full-frame copy to sit behind a picture that does not fill the frame."""
    sw, sh, x, y = crop_offsets(src_w, src_h, W, H)
    return f"[{source}]scale={sw}:{sh},crop={W}:{H}:{x}:{y},boxblur=24:2,eq=brightness=-0.12[bg]"


def footage_filter(src_w, src_h, W, H, layout):
    """ffmpeg filter graph ([0:v] -> [v]) for a layout from plan_layout."""
    tail = "fps=30,format=yuv420p,setsar=1[v]"
    kind = layout[0]
    if kind == "stack":
        half = H // 2
        return ("[0:v]split=2[top0][bottom0];"
                + _pane(src_w, src_h, W, half, layout[1], 0.55, "top0", "top") + ";"
                + _pane(src_w, src_h, W, half, layout[2], 0.55, "bottom0", "bottom")
                + f";[top][bottom]vstack,{tail}")
    if kind == "side":
        pw = W // 2
        ph = _even(H * 0.6) if H > W else H        # in a tall video the pair sits in a band, not two thin strips
        panes = (_pane(src_w, src_h, pw, ph, layout[1], 0.45, "l0", "l") + ";"
                 + _pane(src_w, src_h, pw, ph, layout[2], 0.45, "r0", "r"))
        if ph == H:
            return f"[0:v]split=2[l0][r0];{panes};[l][r]hstack,{tail}"
        return (f"[0:v]split=3[bg0][l0][r0];{_backdrop(src_w, src_h, W, H, 'bg0')};{panes};[l][r]hstack[fg];"
                f"[bg][fg]overlay=0:{int((H - ph) * 0.38)},{tail}")
    if kind == "wide":
        left, right = (layout[1], layout[2]) if len(layout) > 2 else (None, None)
        x0, x1 = (max(0.0, left[0] - 0.24), min(1.0, right[0] + 0.24)) if left else (0.0, 1.0)
        cw, cx = _even((x1 - x0) * src_w), int(x0 * src_w)
        h2 = _even(W * src_h / cw)
        if h2 < H:  # the two-shot is wider than the frame: show all of it over a blurred backdrop
            return (f"[0:v]split=2[bg0][fg0];{_backdrop(src_w, src_h, W, H, 'bg0')};"
                    f"[fg0]crop={cw}:{src_h}:{cx}:0,scale={W}:{h2}[fg];"
                    f"[bg][fg]overlay=0:{int((H - h2) * 0.38)},{tail}")
        layout = ("single", ((x0 + x1) / 2, (left[1] + right[1]) / 2 if left else 0.4))
    sw, sh, x, y = crop_offsets(src_w, src_h, W, H, layout[1] if layout[0] == "single" else None)
    return f"[0:v]scale={sw}:{sh},crop={W}:{H}:{x}:{y},{tail}"


# ------------------------------------------------------------------ 1080p working copies of large footage
def proxy_dir():
    from common import studio_root
    return os.environ.get("PSTUDIO_PROXIES") or os.path.join(studio_root(), "workspace", "proxies")


def _proxy_path(src):
    import hashlib
    st = os.stat(src)
    key = f"{os.path.abspath(src)}|{st.st_size}|{int(st.st_mtime)}"
    return os.path.join(proxy_dir(), hashlib.sha1(key.encode("utf-8")).hexdigest()[:16] + ".mp4")


def needs_proxy(src):
    from common import video_size
    w, h = video_size(src)
    return max(w, h) > 1920


def make_proxy(src):
    """Write a 1080p copy of footage larger than 1080p, with a keyframe every second for fast, exact seeking.

    The finished videos are 1080p at most, so nothing is lost; every later cut and face scan reads a quarter of
    the pixels. Made once per episode (when it is indexed) and reused. Returns the copy's path, or None.
    """
    if not needs_proxy(src):
        return None
    out = _proxy_path(src)
    if os.path.exists(out) and abs(duration(out) - duration(src)) < 1.0:
        return out
    os.makedirs(proxy_dir(), exist_ok=True)
    log(f"  making a 1080p working copy of {os.path.basename(src)} (one time; speeds up every later cut)")
    part = out + ".part.mp4"
    run(FF + ["-i", src, "-map", "0:v:0", "-map", "0:a:0?", "-vf",
              "scale=1920:1920:force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2",
              *venc(18), "-g", "30", "-c:a", "aac", "-b:a", "160k", "-ar", "48000", "-ac", "2", part])
    os.replace(part, out)
    return out


def working_copy(src):
    """The 1080p working copy of `src` if one has been made, else `src` itself."""
    try:
        p = _proxy_path(src)
    except OSError:
        return src
    return p if os.path.exists(p) else src


def _encode(src, start, seconds, out_mp4, graph, sound):
    run(FF + ["-ss", f"{start:.3f}", "-t", f"{seconds:.3f}", "-i", src, "-filter_complex", graph, "-map", "[v]", *sound,
              *venc(20), out_mp4])


def _speaker_cut(src, start, seconds, out_mp4, size, src_size, boxes, audio):
    """Cut between the two hosts following who is speaking; the wide/stacked shot when both or neither are."""
    import speaker

    (W, H), (src_w, src_h) = size, src_size
    left, right = (boxes[0][0], boxes[0][1]), (boxes[1][0], boxes[1][1])
    shots = speaker.timeline(src, start, seconds, boxes)
    both = ("stack", left, right) if H > W else ("wide", left, right)
    tmp = out_mp4 + ".parts"
    os.makedirs(tmp, exist_ok=True)
    names = []
    for n, (t0, t1, who) in enumerate(shots):
        t0, t1 = round(t0 * 30) / 30, round(t1 * 30) / 30
        if t1 - t0 < 1 / 30:
            continue
        layout = both if who == "both" else ("single", (left, right)[who])
        log(f"  {t0:5.1f}-{t1:5.1f}s  {'both' if who == 'both' else ('left', 'right')[who] + ' host speaking'}")
        name = f"p{n:03}.mp4"
        _encode(src, start + t0, t1 - t0, os.path.join(tmp, name), footage_filter(src_w, src_h, W, H, layout), ["-an"])
        names.append(name)
    with open(os.path.join(tmp, "list.txt"), "w", encoding="utf-8") as f:
        f.write("".join(f"file '{n}'\n" for n in names))
    joined = "joined.mp4"
    run(FF + ["-f", "concat", "-safe", "0", "-i", "list.txt", "-c", "copy", joined], cwd=tmp)
    if audio:
        run(FF + ["-i", os.path.join(tmp, joined), "-ss", f"{start:.3f}", "-t", f"{seconds:.3f}", "-i", src,
                  "-map", "0:v", "-map", "1:a?", "-c:v", "copy", "-c:a", "aac", "-ar", "48000", "-ac", "2",
                  "-shortest", out_mp4])
    else:
        os.replace(os.path.join(tmp, joined), out_mp4)
    import shutil
    shutil.rmtree(tmp, ignore_errors=True)
    return len(names)


def footage_clip(src, start, out_mp4, seconds, fmt="9:16", audio=False, layout=None, choice="auto"):
    """Cut `seconds` of real footage at `start`, framed by `choice` (see plan_layout). Muted unless `audio`.

    choice "speaker" follows whoever is talking (needs two hosts on screen and the LR-ASD model); if that
    cannot be done it falls back to "auto". Returns the framing used: speaker, stack, side, wide, single or center.
    """
    from common import video_size

    W, H = FORMATS[fmt]
    src = working_copy(src)
    total = duration(src)
    start = max(0.0, min(float(start), max(0.0, total - seconds)))
    src_w, src_h = video_size(src)
    if not src_w:
        raise RuntimeError(f"cannot read video size of {src}")
    if layout is None:
        if choice not in FRAMINGS:
            choice = "auto"
        frames = detect_faces(src, start, seconds, samples=10 if choice == "speaker" else 6)
        if choice == "speaker":
            boxes = find_host_boxes(frames)
            try:
                if len(boxes) != 2:
                    raise RuntimeError("two hosts were not found on screen")
                shots = _speaker_cut(src, start, seconds, out_mp4, (W, H), (src_w, src_h), boxes, audio)
                log(f"  framing: speaker ({shots} shot{'s' if shots != 1 else ''})")
                return "speaker"
            except Exception as e:  # noqa: BLE001 - never lose the scene over framing
                log(f"  cannot follow the speaker ({e}) - using automatic framing")
                choice = "auto"
        layout = plan_layout(frames, vertical=H > W, choice=choice)
        if choice in ("stack", "side", "single-left", "single-right") and not find_hosts(frames)[0]:
            log("  two hosts not found in this clip - using typical seat positions")
    log(f"  framing: {layout[0]}")
    sound = ["-map", "0:a?", "-c:a", "aac", "-ar", "48000", "-ac", "2"] if audio else ["-an"]
    _encode(src, start, seconds, out_mp4, footage_filter(src_w, src_h, W, H, layout), sound)
    if not audio and duration(out_mp4) < seconds - 0.5:  # source too short: freeze the last frame
        padded = out_mp4 + ".pad.mp4"
        run(FF + ["-i", out_mp4, "-vf", f"tpad=stop_mode=clone:stop_duration={seconds}", "-t", f"{seconds:.2f}",
                  "-an", *venc(20), padded])
        os.replace(padded, out_mp4)
    return layout[0]


class StillMaker:
    """Stable Diffusion 1.5 on a 4 GB GPU: fp16 + CPU offload + attention slicing.

    Some GTX 16xx cards return black images in fp16; those are detected and retried in fp32.
    """

    def __init__(self, model=SD_MODEL):
        self.model = model
        self.pipe = None
        self.dtype = None

    def _load(self, fp32=False):
        import torch
        from diffusers import StableDiffusionPipeline

        cuda = torch.cuda.is_available()
        self.dtype = torch.float32 if (fp32 or not cuda) else torch.float16
        log(f"Loading {self.model} ({self.dtype}, {'cuda' if cuda else 'cpu'})...")
        pipe = StableDiffusionPipeline.from_pretrained(self.model, torch_dtype=self.dtype, safety_checker=None)
        pipe.enable_attention_slicing()
        pipe.enable_vae_slicing()                  # decode the image in pieces: less graphics memory
        from common import free_gpu
        free_gpu()                                 # a language model left in memory would not leave room
        if cuda:
            (pipe.enable_sequential_cpu_offload if fp32 else pipe.enable_model_cpu_offload)()
        self.pipe = pipe

    def make(self, prompt, out_png, fmt="9:16", steps=22):
        import numpy as np
        import torch

        w, h = {"9:16": (448, 768), "16:9": (768, 448), "1:1": (512, 512)}[fmt]
        full = prompt + ", cinematic lighting, high detail, professional photograph"
        negative = "text, watermark, logo, blurry, deformed, low quality, extra fingers"
        for attempt in (False, True):
            if self.pipe is None or attempt:
                self._load(fp32=attempt)
            image = self.pipe(full, negative_prompt=negative, width=w, height=h,
                              num_inference_steps=steps, guidance_scale=7.0).images[0]
            if np.asarray(image).mean() > 3 or self.dtype == torch.float32:
                image.save(out_png)
                return out_png
            log("  black image in fp16 - retrying in fp32 (slower)")
        return out_png

    def peak_mb(self):
        import torch
        return int(torch.cuda.max_memory_allocated() / 2 ** 20) if torch.cuda.is_available() else 0


def main():
    ap = argparse.ArgumentParser(description="Make one visual clip")
    ap.add_argument("kind", choices=["card", "still"])
    ap.add_argument("text", help="Card text or image prompt")
    ap.add_argument("--out", required=True)
    ap.add_argument("--seconds", type=float, default=4)
    ap.add_argument("--format", default="9:16", choices=list(FORMATS))
    a = ap.parse_args()
    if a.kind == "card":
        card_clip(a.text, a.out, a.seconds, a.format)
    else:
        png = os.path.splitext(a.out)[0] + ".png"
        StillMaker().make(a.text, png, a.format)
        kenburns(png, a.out, a.seconds, a.format)
    log(f"Saved {a.out}")


if __name__ == "__main__":
    main()
'@
$files['subs.py'] = @'
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
'@
$files['brand.py'] = @'
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
'@
$files['speaker.py'] = @'
"""Who is talking? Active-speaker detection with LR-ASD (MIT licence, about 0.8 M parameters; runs on the CPU).

For a clip with two hosts in fixed seats it scores each host's face against the sound, 25 times a second,
and returns a timeline of who is speaking so the picture can cut to them.

  python speaker.py <video> --start 12 --seconds 8        prints the timeline
"""
import argparse
import os
import subprocess
import sys
import tempfile
import wave

from common import FF, log, studio_root

FPS = 25          # the model was trained on 25 fps face crops
WIDTH = 640       # frames are analysed at this width


def repo_dir():
    return os.environ.get("PSTUDIO_LRASD") or os.path.join(studio_root(), "repos", "LR-ASD")


def available():
    return os.path.exists(os.path.join(repo_dir(), "weight", "pretrain_AVA.model"))


class Detector:
    """Loads LR-ASD once; `scores(faces, mfcc)` gives one speaking score per video frame (above 0 = speaking)."""

    def __init__(self, device="cpu"):
        import torch

        repo = repo_dir()
        if not available():
            raise RuntimeError(f"LR-ASD is not installed at {repo}")
        if repo not in sys.path:
            sys.path.insert(0, repo)
        from model.Model import ASD_Model  # noqa: E402 - from the LR-ASD repository

        self.torch, self.device = torch, device
        self.model = ASD_Model().to(device).eval()
        self.fc = torch.nn.Linear(128, 2).to(device).eval()
        state = torch.load(os.path.join(repo, "weight", "pretrain_AVA.model"), map_location=device)
        clean = {k.replace("module.", ""): v for k, v in state.items()}
        self.model.load_state_dict({k[len("model."):]: v for k, v in clean.items() if k.startswith("model.")})
        self.fc.load_state_dict({k[len("lossAV.FC."):]: v for k, v in clean.items() if k.startswith("lossAV.FC.")})

    def scores(self, faces, mfcc):
        """faces: (frames, 112, 112) grey uint8 at 25 fps; mfcc: (frames * 4, 13). Returns a float array."""
        import numpy as np

        torch = self.torch
        length = min((mfcc.shape[0] - mfcc.shape[0] % 4) / 100, faces.shape[0] / FPS)
        mfcc, faces = mfcc[:int(round(length * 100))], faces[:int(round(length * FPS))]
        if len(faces) < FPS // 2:
            return np.zeros(len(faces))
        runs = []
        for seconds in (1, 2, 3, 4, 6):          # several window sizes, averaged, as in the reference script
            out = []
            with torch.no_grad():
                for i in range(int(np.ceil(length / seconds))):
                    a = torch.FloatTensor(mfcc[i * seconds * 100:(i + 1) * seconds * 100]).unsqueeze(0).to(self.device)
                    v = torch.FloatTensor(faces[i * seconds * FPS:(i + 1) * seconds * FPS]).unsqueeze(0).to(self.device)
                    if v.shape[1] == 0 or a.shape[1] < 4:
                        continue
                    emb = self.model.forward_audio_visual_backend(self.model.forward_audio_frontend(a),
                                                                  self.model.forward_visual_frontend(v))
                    out.extend(self.fc(emb.squeeze(1))[:, 1].reshape(-1).cpu().numpy())
            runs.append(np.asarray(out[:len(faces)] + [0.0] * max(0, len(faces) - len(out))))
        return np.mean(runs, axis=0)


def read_frames(src, start, seconds):
    """Grey frames at 25 fps, WIDTH wide: array (frames, height, WIDTH)."""
    import numpy as np

    from common import video_size
    w, h = video_size(src)
    if not w:
        raise RuntimeError(f"cannot read {src}")
    height = int(round(h * WIDTH / w / 2)) * 2
    raw = subprocess.run(FF[:1] + ["-v", "error", "-ss", f"{start:.2f}", "-t", f"{seconds:.2f}", "-i", src,
                                   "-vf", f"fps={FPS},scale={WIDTH}:{height},format=gray", "-f", "rawvideo", "-"],
                         capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.uint8)[:len(raw) // (WIDTH * height) * WIDTH * height].reshape(-1, height, WIDTH)


def mfcc(signal, rate=16000, numcep=13, nfilt=26, nfft=512, winlen=0.025, winstep=0.010, preemph=0.97, lifter=22):
    """13 MFCCs every 10 ms - the same numbers as python_speech_features.mfcc with its defaults.

    Written out here (numpy only) because that package no longer builds on every Python.
    """
    import numpy as np

    signal = np.asarray(signal, dtype=np.float64)
    signal = np.append(signal[:1], signal[1:] - preemph * signal[:-1])
    flen, fstep = int(round(winlen * rate)), int(round(winstep * rate))
    count = 1 if len(signal) <= flen else 1 + int(np.ceil((len(signal) - flen) / fstep))
    padded = np.concatenate([signal, np.zeros((count - 1) * fstep + flen - len(signal))])
    idx = np.arange(flen)[None, :] + (np.arange(count) * fstep)[:, None]
    power = np.abs(np.fft.rfft(padded[idx], nfft)) ** 2 / nfft
    energy = power.sum(axis=1)
    energy[energy == 0] = np.finfo(float).eps
    mel = np.linspace(0, 2595 * np.log10(1 + (rate / 2) / 700.0), nfilt + 2)
    bins = np.floor((nfft + 1) * (700 * (10 ** (mel / 2595.0) - 1)) / rate)
    bank = np.zeros((nfilt, nfft // 2 + 1))
    for j in range(nfilt):
        lo, mid, hi = int(bins[j]), int(bins[j + 1]), int(bins[j + 2])
        for i in range(lo, mid):
            bank[j, i] = (i - bins[j]) / (bins[j + 1] - bins[j])
        for i in range(mid, hi):
            bank[j, i] = (bins[j + 2] - i) / (bins[j + 2] - bins[j + 1])
    feat = power @ bank.T
    feat[feat == 0] = np.finfo(float).eps
    feat = np.log(feat)
    n = np.arange(nfilt)
    basis = np.cos(np.pi * (n[None, :] + 0.5) * np.arange(numcep)[:, None] / nfilt) * np.sqrt(2.0 / nfilt)
    basis[0] *= np.sqrt(0.5)                               # orthonormal DCT-II
    feat = feat @ basis.T
    feat *= 1 + (lifter / 2.0) * np.sin(np.pi * np.arange(numcep) / lifter)
    feat[:, 0] = np.log(energy)
    return feat


def read_mfcc(src, start, seconds):
    import numpy as np

    tmp = os.path.join(tempfile.mkdtemp(prefix="pstudio_asd_"), "a.wav")
    subprocess.run(FF + ["-ss", f"{start:.2f}", "-t", f"{seconds:.2f}", "-i", src, "-vn", "-ac", "1", "-ar", "16000",
                         "-c:a", "pcm_s16le", tmp], check=True)
    with wave.open(tmp, "rb") as w:
        audio = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    os.remove(tmp)
    return mfcc(audio)


def face_crops(frames, box):
    """Cut one host's face out of every frame the way the model expects. box = (centre_x, centre_y, width) as 0-1."""
    import cv2
    import numpy as np

    n, h, w = frames.shape
    half = max(8.0, box[2] * w / 2)                      # half the face box, in pixels
    pad = int(half * 1.8)                                # crop scale 0.40, as in the reference script
    mx, my = box[0] * w + pad, box[1] * h + pad
    y0, y1 = int(my - half), int(my + half * 1.8)
    x0, x1 = int(mx - half * 1.4), int(mx + half * 1.4)
    out = np.empty((n, 112, 112), dtype=np.uint8)
    for i in range(n):
        padded = np.pad(frames[i], pad, mode="constant", constant_values=110)
        out[i] = cv2.resize(padded[y0:y1, x0:x1], (224, 224))[56:168, 56:168]
    return out


def smooth_timeline(score_sets, seconds, hold=1.2, margin=0.3):
    """Turn per-host score arrays into [(start, end, who)] with who = index of the speaker or "both".

    A host is "speaking" when their score is above 0; when both or neither are, the wide shot ("both") is used.
    Shots shorter than `hold` seconds are merged into their neighbour so the picture does not flicker.
    """
    import numpy as np

    n = min(len(s) for s in score_sets)
    if n == 0:
        return [(0.0, seconds, "both")]
    kernel = np.ones(13) / 13                             # about half a second
    smooth = [np.convolve(s[:n], kernel, mode="same") for s in score_sets]
    labels = []
    for i in range(n):
        vals = [s[i] for s in smooth]
        top = int(np.argmax(vals))
        others = max(v for k, v in enumerate(vals) if k != top) if len(vals) > 1 else -9
        labels.append(top if vals[top] > 0 and vals[top] - others > margin else "both")
    runs = []
    for i, lab in enumerate(labels):
        if runs and runs[-1][2] == lab:
            runs[-1][1] = i + 1
        else:
            runs.append([i, i + 1, lab])
    changed = True
    while changed and len(runs) > 1:                      # absorb short shots
        changed = False
        for k, (a, b, lab) in enumerate(runs):
            if (b - a) / FPS < hold:
                # a short "both" between two speakers is a hand-over: give it to the speaker who is starting
                forward = k + 1 < len(runs) and (k == 0 or lab == "both")
                into = k + 1 if forward else k - 1
                runs[into][0], runs[into][1] = min(runs[into][0], a), max(runs[into][1], b)
                del runs[k]
                changed = True
                break
        merged = []
        for r in runs:
            if merged and merged[-1][2] == r[2]:
                merged[-1][1] = r[1]
            else:
                merged.append(r)
        runs = merged
    out = [(a / FPS, b / FPS, lab) for a, b, lab in runs]
    out[0] = (0.0, out[0][1], out[0][2])
    out[-1] = (out[-1][0], seconds, out[-1][2])
    return out


_detector = None


def timeline(src, start, seconds, boxes):
    """[(start, end, who)] for a clip, relative to its start. boxes = one (cx, cy, width) per host, left to right."""
    global _detector
    if _detector is None:
        _detector = Detector()
    frames = read_frames(src, start, seconds)
    mfcc = read_mfcc(src, start, seconds)
    scores = [_detector.scores(face_crops(frames, box), mfcc) for box in boxes]
    return smooth_timeline(scores, seconds)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--start", type=float, default=0)
    ap.add_argument("--seconds", type=float, default=10)
    a = ap.parse_args()
    import visuals
    boxes = visuals.find_host_boxes(visuals.detect_faces(a.video, a.start, a.seconds, samples=10))
    if not boxes:
        log("No faces found.")
        return
    for t0, t1, who in timeline(a.video, a.start, a.seconds, boxes):
        log(f"{t0:6.2f} - {t1:6.2f}  {'both / nobody' if who == 'both' else 'host ' + str(who + 1)}")


if __name__ == "__main__":
    main()
'@
$files['lipsync.py'] = @'
"""Optional lip-sync: make one host's mouth match the narration, using MuseTalk (MIT licence) in its own environment.

MuseTalk is installed only with the installer's -WithLipSync switch. On a 4 GB card its authors report about
five minutes for an eight-second clip, so this is slow and off by default.
"""
import os
import shutil
import subprocess
import tempfile

from common import FF, duration, free_gpu, log, studio_root, venc


def repo_dir():
    return os.environ.get("PSTUDIO_MUSETALK") or os.path.join(studio_root(), "repos", "MuseTalk")


def python_exe():
    cand = [os.environ.get("PSTUDIO_MUSETALK_PYTHON"),
            os.path.join(studio_root(), "venv-musetalk", "Scripts", "python.exe"),
            os.path.join(studio_root(), "venv-musetalk", "bin", "python")]
    return next((c for c in cand if c and os.path.exists(c)), None)


def available():
    repo = repo_dir()
    return bool(python_exe()) and os.path.exists(os.path.join(repo, "scripts", "inference.py")) and (
        os.path.exists(os.path.join(repo, "models", "musetalkV15", "unet.pth")) or bool(os.environ.get("PSTUDIO_MUSETALK_PYTHON")))


def sync(video, audio, timeout=3600):
    """Replace `video` with a version whose lips follow `audio`. Returns True if it worked; the original is kept if not."""
    if not available():
        log("  lip-sync is not installed (run the installer with -WithLipSync)")
        return False
    free_gpu()                                    # MuseTalk needs the whole 4 GB card
    repo, tmp = repo_dir(), tempfile.mkdtemp(prefix="pstudio_lip_")
    try:
        src = os.path.join(tmp, "in.mp4")       # MuseTalk expects 25 fps
        subprocess.run(FF + ["-i", video, "-vf", "fps=25", "-an", *venc(18), src], check=True)
        cfg = os.path.join(tmp, "task.yaml")
        with open(cfg, "w", encoding="utf-8") as f:
            f.write("task_0:\n"
                    f" video_path: \"{src.replace(os.sep, '/')}\"\n"
                    f" audio_path: \"{os.path.abspath(audio).replace(os.sep, '/')}\"\n"
                    " result_name: \"synced.mp4\"\n")
        ffmpeg_dir = os.path.dirname(shutil.which("ffmpeg") or "")
        cmd = [python_exe(), "-m", "scripts.inference", "--inference_config", cfg, "--result_dir", tmp,
               "--unet_model_path", os.path.join("models", "musetalkV15", "unet.pth"),
               "--unet_config", os.path.join("models", "musetalkV15", "musetalk.json"),
               "--version", "v15", "--use_float16", "--batch_size", "4", "--ffmpeg_path", ffmpeg_dir]
        log("  lip-syncing with MuseTalk (slow on a 4 GB card)...")
        done = subprocess.run(cmd, cwd=repo, capture_output=True, text=True, timeout=timeout)
        result = os.path.join(tmp, "v15", "synced.mp4")
        if done.returncode != 0 or not os.path.exists(result) or duration(result) < 0.3:
            log("  lip-sync failed - keeping the original picture: " + (done.stderr or done.stdout or "no output")[-300:].strip())
            return False
        subprocess.run(FF + ["-i", result, "-an", "-vf", "fps=30", *venc(20), video + ".sync.mp4"], check=True)
        os.replace(video + ".sync.mp4", video)
        return True
    except Exception as e:  # noqa: BLE001 - lip-sync is a bonus, never a blocker
        log(f"  lip-sync failed - keeping the original picture: {e}")
        return False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
'@
$files['tts.py'] = @'
"""Voice-cloned narration with Qwen3-TTS 0.6B (fits a 4 GB GPU in fp16)."""
import argparse
import os
import re

from common import fail, log, read_text

MODEL = "Qwen/Qwen3-TTS-12Hz-0.6B-Base"


def chunk_text(text, limit=280):
    """Split on paragraphs, then sentences, keeping chunks under `limit` chars."""
    chunks = []
    for para in [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]:
        cur = ""
        for sent in re.split(r"(?<=[.!?])\s+", para):
            if cur and len(cur) + len(sent) + 1 > limit:
                chunks.append(cur)
                cur = sent
            else:
                cur = (cur + " " + sent).strip()
        if cur:
            chunks.append(cur)
    return chunks


class Voice:
    """Loads the model once and speaks many texts in one cloned voice."""

    def __init__(self, ref_audio, ref_text=None, model=MODEL, device="cuda", language="English"):
        import torch

        self.torch = torch
        self.model_id, self.language = model, language
        self.ref_audio, self.ref_text = ref_audio, (ref_text or None)
        self.device = device if (device == "cpu" or torch.cuda.is_available()) else "cpu"
        if self.device != device:
            log("CUDA not available - using CPU (slow).")
        self._load(torch.float16 if self.device == "cuda" else torch.float32)

    def _load(self, dtype):
        from qwen_tts import Qwen3TTSModel

        log(f"Loading {self.model_id} on {self.device} ({dtype})...")
        self.dtype = dtype
        self.model = Qwen3TTSModel.from_pretrained(
            self.model_id, device_map="cuda:0" if self.device == "cuda" else "cpu", dtype=dtype)
        self.prompt = self.model.create_voice_clone_prompt(
            ref_audio=self.ref_audio, ref_text=self.ref_text, x_vector_only_mode=self.ref_text is None)

    def _generate(self, text):
        import numpy as np

        wavs, sr = self.model.generate_voice_clone(text=text, language=self.language,
                                                   voice_clone_prompt=self.prompt)
        return np.asarray(wavs[0], dtype=np.float32), sr

    def speak(self, text, out_wav, pause=0.25):
        """Synthesize `text` to `out_wav`. Falls back to fp32 if fp16 yields silence/NaN (some GTX cards)."""
        import numpy as np
        import soundfile as sf

        pieces, sr = [], 24000
        for chunk in chunk_text(text):
            wav, sr = self._generate(chunk)
            bad = (not np.isfinite(wav).all()) or float(np.abs(wav).max(initial=0)) < 1e-4
            if bad and self.dtype == self.torch.float16:
                log("  fp16 produced invalid audio - reloading in fp32")
                del self.model
                self.torch.cuda.empty_cache()
                self._load(self.torch.float32)
                wav, sr = self._generate(chunk)
            pieces += [np.nan_to_num(wav), np.zeros(int(sr * pause), dtype=np.float32)]
            if self.device == "cuda":
                self.torch.cuda.empty_cache()
        os.makedirs(os.path.dirname(os.path.abspath(out_wav)), exist_ok=True)
        sf.write(out_wav, np.concatenate(pieces), sr)
        return out_wav

    def peak_mb(self):
        t = self.torch
        return int(t.cuda.max_memory_allocated() / 2 ** 20) if t.cuda.is_available() else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", required=True, help="Text file with the narration")
    ap.add_argument("--ref-audio", required=True)
    ap.add_argument("--ref-text", help="Text file with the reference transcript (better quality)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--language", default="English")
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--device", default="cuda", choices=["cuda", "cpu"])
    a = ap.parse_args()

    text = read_text(a.script).strip()
    if not text:
        fail("Script is empty")
    ref_text = None
    if a.ref_text and os.path.exists(a.ref_text):
        ref_text = read_text(a.ref_text).strip() or None

    voice = Voice(a.ref_audio, ref_text, a.model, a.device, a.language)
    voice.speak(text, a.out)
    log(f"Saved voiceover: {a.out}  (peak VRAM {voice.peak_mb()} MiB)")


if __name__ == "__main__":
    main()
'@
$files['pipeline.py'] = @'
"""Prompt -> outline -> script + shot list -> voice -> visuals -> video -> quality gate. All local.

  python pipeline.py --project <dir> --stage outline --prompt-file prompt.txt [--seconds 45 ...]
  (edit <dir>/outline.txt, then)
  python pipeline.py --project <dir> --stage all

Every stage writes into the project folder and skips work that already exists, so a failed
run resumes where it stopped. `--force` redoes the chosen stage.
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import time

from common import (FF, FORMATS, duration, ensure_dir, fail, gpu_used_mb, log, read_json, read_text,
                    record_metric, run, write_json, write_text)

STAGES = ["outline", "script", "voice", "visuals", "render", "qa"]
WORDS_PER_SECOND = 2.5


# ------------------------------------------------------------------ project state
def load(project):
    return read_json(os.path.join(project, "project.json"), {})


def save(project, cfg):
    write_json(os.path.join(project, "project.json"), cfg)


def style_bible(project):
    """The show's style guide, with the house rules (lasting corrections) placed first so they win."""
    workspace = os.path.dirname(os.path.dirname(project))
    text = ""
    for p in (os.path.join(project, "style-bible.md"), os.path.join(workspace, "style-bible.md")):
        if os.path.exists(p):
            text = read_text(p)[:6000]
            break
    rules = os.path.join(workspace, "house-rules.md")
    if os.path.exists(rules) and read_text(rules).strip():
        text = "HOUSE RULES (always follow these):\n" + read_text(rules).strip()[:3000] + ("\n\n" + text if text else "")
    return text


def library_dir(cfg, project):
    return cfg.get("library") or os.path.join(os.path.dirname(os.path.dirname(project)), "library")


# ------------------------------------------------------------------ stage: outline
OUTLINE_SCHEMA = {"type": "object", "required": ["title", "hooks", "beats", "cta"], "properties": {
    "title": {"type": "string"},
    "hooks": {"type": "array", "items": {"type": "string"}, "minItems": 3, "maxItems": 3},
    "beats": {"type": "array", "items": {"type": "string"}},
    "cta": {"type": "string"}}}


def stage_outline(project, cfg, force):
    """Draft outline.txt plus hooks.json (three opening lines to choose from)."""
    import llm

    out = os.path.join(project, "outline.txt")
    if os.path.exists(out) and not force:
        log("outline.txt exists - keeping it (use --force to redraft)")
        return
    bible = style_bible(project)
    system = ("You plan short videos for a podcast. Be concrete and punchy. No markdown."
              + (f"\n\nSHOW STYLE GUIDE:\n{bible}" if bible else ""))
    ask = f"Plan a {cfg['seconds']}-second video about:\n{cfg['prompt']}\n\n"
    t0, hooks, text = time.time(), [], ""
    try:
        plan = llm.chat(system, ask + "Return JSON with: \"title\" (max 8 words), \"hooks\" (exactly 3 different "
                        "opening lines, each said in the first 3 seconds: one a bold claim, one a question, one a "
                        "short story opener), \"beats\" (4 to 7 one-line points), \"cta\" (closing line).",
                        cfg["model"], schema=OUTLINE_SCHEMA)
        hooks = [" ".join(str(h).split()) for h in plan.get("hooks") or [] if str(h).strip()][:3]
        beats = [" ".join(str(b).split()) for b in plan.get("beats") or [] if str(b).strip()]
        if hooks and len(beats) >= 3:
            text = (f"TITLE: {plan.get('title', '').strip()}\nHOOK: {hooks[0]}\nBEATS:\n"
                    + "\n".join(f"{n}. {b}" for n, b in enumerate(beats, 1)) + f"\nCTA: {plan.get('cta', '').strip()}")
    except Exception as e:  # noqa: BLE001 - fall back to a plain-text outline
        log(f"  structured outline failed ({e}); asking for plain text")
    if not text:
        hooks = []
        text = llm.chat(system, ask + "Use exactly this layout, plain text only:\nTITLE: <max 8 words>\n"
                        "HOOK: <the opening line, said in the first 3 seconds>\nBEATS:\n1. <one line>\n2. <one line>\n"
                        "(4 to 7 beats)\nCTA: <closing line>", cfg["model"])
    write_text(out, text.strip() + "\n")
    write_json(os.path.join(project, "hooks.json"), hooks)
    record_metric(project, "outline", seconds=round(time.time() - t0, 1), model=cfg["model"], hooks=len(hooks))
    log(f"Outline saved: {out}\n\n{text}\n")
    if len(hooks) > 1:
        log("Other hooks to choose from:\n" + "\n".join(f"  - {h}" for h in hooks[1:]))


# ------------------------------------------------------------------ stage: script
SOUNDBITE_SECONDS = 7.0
MAX_SOUNDBITES = 2
EXPLAIN = {
    "soundbite": '"soundbite" = the hosts themselves, a real clip played with its own sound (use at most 2); '
                 'give "query": words to search the episode transcripts, and set "narration" to ""',
    "footage": '"footage" = silent episode footage under the narration; give "query": words to search the transcripts',
    "card": '"card" = bold text on screen; give "card_text": max 10 words',
    "still": '"still" = a generated photo; give "image_prompt": a visual description, no text in the image',
}


def scene_schema(kinds):
    text = {"type": "string"}
    return {"type": "object", "required": ["title", "scenes"], "properties": {
        "title": text,
        "scenes": {"type": "array", "items": {"type": "object", "required": ["narration", "visual"], "properties": {
            "narration": text, "visual": {"type": "string", "enum": kinds},
            "query": text, "card_text": text, "image_prompt": text}}}}}


def clean_scenes(raw, kinds):
    """Coerce whatever the model returned into a valid scene list."""
    scenes, bites = [], 0
    for s in (raw.get("scenes") or []) if isinstance(raw, dict) else []:
        if not isinstance(s, dict):
            continue
        narration = " ".join(str(s.get("narration") or "").split())
        visual = str(s.get("visual") or "").lower().strip()
        query = " ".join(str(s.get("query") or "").split())[:200]
        if visual == "soundbite" and "soundbite" in kinds and query and bites < MAX_SOUNDBITES:
            bites += 1
        elif not narration:
            continue
        elif visual not in kinds or visual == "soundbite":
            visual = next(k for k in kinds if k != "soundbite")
        scenes.append({
            "narration": narration,
            "visual": visual,
            "query": query or narration[:200],
            "card_text": " ".join(str(s.get("card_text") or "").split())[:120],
            "image_prompt": str(s.get("image_prompt") or query or narration)[:300],
        })
    return scenes


def estimate_seconds(scenes):
    spoken = sum(len(s["narration"].split()) for s in scenes if s["visual"] != "soundbite")
    return spoken / WORDS_PER_SECOND + SOUNDBITE_SECONDS * sum(s["visual"] == "soundbite" for s in scenes)


def resolve_sources(scenes, lib):
    """Find the real clip for every footage/soundbite scene now, so later stages know each scene's type."""
    from library import pick_soundbite

    out = []
    for s in scenes:
        if s["visual"] in ("footage", "soundbite"):
            hit = lib.search(s["query"])
            if hit and s["visual"] == "soundbite":
                start, secs, segs, words = pick_soundbite(hit, s["query"])
                s["source"] = {"file": hit["file"], "start": start, "seconds": secs, "segs": segs, "words": words}
                s["narration"] = ""
            elif hit:
                s["source"] = {"file": hit["file"], "start": hit["start"]}
            elif not s["narration"]:
                continue  # a soundbite with nothing to play and nothing to say
            else:
                s["visual"] = "card"
        out.append(s)
    return out


def script_request(outline, target, kinds, bible=""):
    """The (system, user) messages that ask a model for the narration and shot list."""
    system = ("You write narration scripts and shot lists for short podcast videos. Reply with JSON only."
              + (f"\n\nSHOW STYLE GUIDE:\n{bible}" if bible else ""))
    user = (f"Turn this outline into a video of about {target:.0f} seconds. Narration is spoken at "
            f"{WORDS_PER_SECOND} words per second, so write about {int(target * WORDS_PER_SECOND)} words of narration "
            f"in total (each soundbite replaces about {int(SOUNDBITE_SECONDS * WORDS_PER_SECOND)} of those words)."
            f"\n\nOUTLINE:\n{outline}\n\n"
            "Return JSON: {\"title\": str, \"scenes\": [{\"narration\": str, \"visual\": str, "
            "\"query\": str, \"card_text\": str, \"image_prompt\": str}]}\n"
            "Rules:\n- One scene per sentence or two of narration (6 to 12 scenes).\n"
            "- The first scene is the hook. The last scene is the call to action.\n"
            "- Narration is spoken aloud: no emojis, no stage directions, no hashtags.\n"
            "- \"visual\" must be one of: " + ", ".join(kinds) + ".\n"
            + "\n".join("- " + EXPLAIN[k] for k in kinds) + "\n- Vary the visuals.")
    return system, user


def stage_script(project, cfg, force):
    import llm
    from library import Library

    out = os.path.join(project, "script.json")
    outline_path = os.path.join(project, "outline.txt")
    if not os.path.exists(outline_path):
        stage_outline(project, cfg, False)
    outline = read_text(outline_path).strip()
    digest = hashlib.sha1(outline.encode("utf-8")).hexdigest()
    old = read_json(out)
    if old and not force and old.get("outline_sha1") == digest:
        log("script.json matches the outline - keeping it")
        return
    if old:  # outline was edited: everything built from the old script is stale
        log("Outline changed - rebuilding script, voice and visuals")
        for sub in ("voice", "visuals", "scenes"):
            shutil.rmtree(os.path.join(project, sub), ignore_errors=True)

    lib = Library(library_dir(cfg, project))
    kinds = []
    if len(lib):
        if cfg.get("soundbites", True):
            kinds.append("soundbite")
        kinds.append("footage")
    kinds.append("card")
    if cfg.get("stills"):
        kinds.append("still")
    target = float(cfg["seconds"])
    system, base = script_request(outline, target, kinds, style_bible(project))
    t0, best, feedback = time.time(), None, ""
    for attempt in range(3):
        raw = llm.chat(system, base + feedback, cfg["model"], schema=scene_schema(kinds),
                       temperature=0.6 + 0.1 * attempt, keep_alive="5m")
        scenes = clean_scenes(raw, kinds)
        if len(scenes) < 3:
            log(f"  attempt {attempt + 1}: unusable script, retrying")
            continue
        est = estimate_seconds(scenes)
        title = raw.get("title") if isinstance(raw, dict) else None
        if best is None or abs(est - target) < abs(best[0] - target):
            best = (est, scenes, title)
        if abs(est - target) <= 0.25 * target:
            break
        log(f"  attempt {attempt + 1}: would run ~{est:.0f}s, target {target:.0f}s - asking for a rewrite")
        feedback = (f"\n\nYour last draft would run about {est:.0f} seconds. Rewrite it to run about {target:.0f} "
                    f"seconds by {'adding' if est < target else 'cutting'} narration.")
    llm.unload(cfg["model"])
    if best is None:
        fail("The local model did not produce a usable script. Try another model in the Create tab.")
    est, scenes, title = best
    scenes = resolve_sources(scenes, lib)
    if len(scenes) < 2 or not any(s["narration"] for s in scenes):
        fail("The script has too few usable scenes. Press step 2 again or try another model.")
    title = str(title or outline.splitlines()[0].replace("TITLE:", "").strip())[:80]
    write_json(out, {"title": title, "outline_sha1": digest, "scenes": scenes})
    write_text(os.path.join(project, "script.txt"),
               "\n\n".join(s["narration"] or f"[soundbite: {s['query']}]" for s in scenes) + "\n")
    kinds_used = {k: sum(s["visual"] == k for s in scenes) for k in kinds}
    record_metric(project, "script", seconds=round(time.time() - t0, 1), scenes=len(scenes),
                  estimated_seconds=round(estimate_seconds(scenes), 1), **kinds_used)
    log(f"Script saved: {len(scenes)} scenes, ~{estimate_seconds(scenes):.0f}s, {kinds_used}")


# ------------------------------------------------------------------ stage: voice
def repair_voice(voice, lines, threshold=0.6, tries=2):
    """Listen back to each new line (speech-to-text on the CPU) and re-make garbled ones, keeping the best take."""
    from common import speech_match

    retried, still_bad = [], []
    try:
        for i, s, wav in lines:
            best = speech_match(wav, s["narration"], device="cpu")
            for attempt in range(tries):
                if best >= threshold:
                    break
                log(f"  line {i} sounds wrong ({best:.0%} of words heard) - re-making, try {attempt + 1}")
                if i not in retried:
                    retried.append(i)
                backup = wav + ".prev"
                os.replace(wav, backup)
                voice.speak(s["narration"], wav, pause=0.15)
                score = speech_match(wav, s["narration"], device="cpu")
                if score > best:
                    best = score
                    os.remove(backup)
                else:
                    os.replace(backup, wav)
            if best < threshold:
                still_bad.append(i)
    except Exception as e:  # noqa: BLE001 - the check is a bonus, never a blocker
        log(f"  voice check skipped ({e})")
    if retried:
        log(f"Voice check: re-made lines {retried}; still unclear: {still_bad or 'none'}")
    return retried, still_bad


def stage_voice(project, cfg, force):
    script = read_json(os.path.join(project, "script.json"))
    if not script:
        fail("No script.json - run the script stage first.")
    vdir = ensure_dir(os.path.join(project, "voice"))
    todo = []
    for i, s in enumerate(script["scenes"], 1):
        wav = os.path.join(vdir, f"scene_{i:02}.wav")
        if s["visual"] != "soundbite" and (force or not os.path.exists(wav) or duration(wav) < 0.2):
            todo.append((i, s, wav))
    if not todo:
        log("All voice lines exist - skipping")
        return
    ref = cfg.get("voice")
    if not ref or not os.path.exists(ref):
        fail("No reference voice set. Make one in the Voice clone tab, then pick it in Create.")
    ref_text = None
    txt = cfg.get("voice_text") or os.path.splitext(ref)[0] + ".txt"
    if os.path.exists(txt):
        ref_text = read_text(txt).strip() or None

    from common import free_gpu
    from tts import Voice
    free_gpu()            # the voice model needs the graphics card; a language model left loaded would not fit
    t0, before = time.time(), gpu_used_mb()
    voice = Voice(ref, ref_text, device=cfg.get("device", "cuda"), language=cfg.get("language", "English"))
    for i, s, wav in todo:
        log(f"[voice {i}/{len(script['scenes'])}] {s['narration'][:70]}")
        voice.speak(s["narration"], wav, pause=0.15)
    retried, still_bad = repair_voice(voice, todo) if cfg.get("voice_check", True) else ([], [])
    record_metric(project, "voice", seconds=round(time.time() - t0, 1), torch_peak_mb=voice.peak_mb(),
                  gpu_used_before_mb=before, gpu_used_after_mb=gpu_used_mb(), dtype=str(voice.dtype),
                  lines_retried=retried, lines_still_unclear=still_bad)
    log(f"Voice done. Peak VRAM (torch): {voice.peak_mb()} MiB")


# ------------------------------------------------------------------ stage: visuals
def stage_visuals(project, cfg, force):
    import brand
    import lipsync
    import visuals

    script = read_json(os.path.join(project, "script.json"))
    if not script:
        fail("No script.json - run the script stage first.")
    kit = brand.load(project)
    fmt = cfg["format"]
    vdir = ensure_dir(os.path.join(project, "visuals"))
    stills, t0 = None, time.time()
    counts = {"soundbite": 0, "footage": 0, "card": 0, "still": 0}
    for i, s in enumerate(script["scenes"], 1):
        out = os.path.join(vdir, f"scene_{i:02}.mp4")
        kind, src = s["visual"], s.get("source")
        if kind == "soundbite":
            secs = src["seconds"]
        else:
            wav = os.path.join(project, "voice", f"scene_{i:02}.wav")
            if not os.path.exists(wav):
                fail(f"Missing voice line {wav} - run the voice stage first.")
            secs = duration(wav) + 0.05
        choice = s.get("layout") or cfg.get("framing", "auto")
        want_sync = bool(cfg.get("lipsync")) and kind == "footage"
        same_framing = kind not in ("soundbite", "footage") or (
            s.get("framing_choice") == choice and bool(s.get("lipsync")) == (want_sync and lipsync.available()))
        if os.path.exists(out) and not force and same_framing and abs(duration(out) - secs) < 0.6:
            counts[kind] += 1
            continue
        log(f"[visual {i}/{len(script['scenes'])}] {kind} ({secs:.1f}s)")
        try:
            if kind in ("soundbite", "footage"):
                if not src or not os.path.exists(src["file"]):
                    raise RuntimeError("source footage is missing")
                log(f"  {os.path.basename(src['file'])} @ {src['start']}s")
                s["framing"] = visuals.footage_clip(src["file"], src["start"], out, secs, fmt,
                                                    audio=kind == "soundbite", choice=choice)
                s["framing_choice"] = choice
                s["lipsync"] = False
                if want_sync and s["framing"] == "single":
                    s["lipsync"] = lipsync.sync(out, wav)
                elif want_sync:
                    log("  lip-sync skipped: it needs one person on screen (set the framing to a single person)")
            elif kind == "still":
                stills = stills or visuals.StillMaker()
                png = os.path.splitext(out)[0] + ".png"
                stills.make(s["image_prompt"], png, fmt)
                visuals.kenburns(png, out, secs, fmt)
            else:
                raise LookupError
        except Exception as e:
            if kind == "soundbite":
                fail(f"Could not cut the soundbite for scene {i}: {e}")
            if not isinstance(e, LookupError):
                log(f"  {kind} failed ({e}) - using a text card instead")
            kind = s["visual"] = "card"
            text = s["card_text"] or " ".join(s["narration"].split()[:10])
            visuals.card_clip(text, out, secs, fmt, kicker=script.get("title") if i == 1 else None, brand=kit)
        counts[kind] += 1
    write_json(os.path.join(project, "script.json"), script)
    record_metric(project, "visuals", seconds=round(time.time() - t0, 1), gpu_used_after_mb=gpu_used_mb(),
                  torch_peak_mb=stills.peak_mb() if stills else 0, **counts)
    log(f"Visuals done: {counts}")


# ------------------------------------------------------------------ stage: render
def stage_render(project, cfg, force):
    import brand
    import subs

    script = read_json(os.path.join(project, "script.json"))
    if not script:
        fail("No script.json.")
    kit = brand.load(project)
    sdir = ensure_dir(os.path.join(project, "scenes"))
    W, H = FORMATS[cfg["format"]]
    from common import enc_tag, probe, venc
    enc = ["-r", "30", *venc(18), "-c:a", "aac", "-ar", "48000", "-ac", "2"]
    sound = ["-c:a", "aac", "-ar", "48000", "-ac", "2"]
    copied = 0

    def reusable(vis, secs):
        """The picture was written by this app at the final size and is long enough: copy it, don't re-encode."""
        info = probe(vis)
        v = info.get("video")
        return (info["tag"] == enc_tag() and v is not None and v[2:6] == (W, H, "yuv420p", "30/1")
                and info["duration"] >= secs - 0.02)
    clips, words, offset = [], [], 0.0
    for i, s in enumerate(script["scenes"], 1):
        vis = os.path.join(project, "visuals", f"scene_{i:02}.mp4")
        out = os.path.join(sdir, f"scene_{i:02}.mp4")
        if not os.path.exists(vis):
            fail(f"Missing {vis} - run the visuals stage first.")
        wav = os.path.join(project, "voice", f"scene_{i:02}.wav")
        inputs = [vis] if s["visual"] == "soundbite" else [vis, wav]
        fresh = (not force and os.path.exists(out) and all(os.path.exists(p) for p in inputs)
                 and os.path.getmtime(out) >= max(os.path.getmtime(p) for p in inputs))
        if fresh:
            pass
        elif s["visual"] == "soundbite":
            secs = duration(vis)
            fades = f"loudnorm=I=-16:TP=-1.5,afade=t=in:d=0.03,afade=t=out:st={max(0, secs - 0.08):.3f}:d=0.08"
            if reusable(vis, secs):
                run(FF + ["-i", vis, "-filter_complex", f"[0:a]{fades}[a]", "-map", "0:v", "-map", "[a]",
                          "-t", f"{secs:.3f}", "-c:v", "copy", *sound, "-metadata", f"comment={enc_tag()}", out])
                copied += 1
            else:
                run(FF + ["-i", vis, "-filter_complex", f"[0:v]scale={W}:{H},setsar=1[v];[0:a]{fades}[a]",
                          "-map", "[v]", "-map", "[a]", "-t", f"{secs:.3f}", *enc, out])
        else:
            if not os.path.exists(wav):
                fail(f"Missing {wav} - run the voice stage first.")
            secs = duration(wav)
            fades = f"loudnorm=I=-16:TP=-1.5,afade=t=in:d=0.02,afade=t=out:st={max(0, secs - 0.04):.3f}:d=0.04"
            if reusable(vis, secs):
                run(FF + ["-i", vis, "-i", wav, "-filter_complex", f"[1:a]{fades}[a]", "-map", "0:v", "-map", "[a]",
                          "-t", f"{secs:.3f}", "-c:v", "copy", *sound, "-metadata", f"comment={enc_tag()}", out])
                copied += 1
            else:
                # hold the last frame if the picture is shorter than the voice line, then cut to the voice
                run(FF + ["-i", vis, "-i", wav, "-filter_complex",
                          f"[0:v]scale={W}:{H},setsar=1,tpad=stop_mode=clone:stop_duration=2[v];[1:a]{fades}[a]",
                          "-map", "[v]", "-map", "[a]", "-t", f"{secs:.3f}", *enc, out])
        real = duration(out)
        if s["visual"] == "soundbite":
            exact = s["source"].get("words")
            if exact:  # word timing measured from the recording
                words += [(w, offset + a, offset + min(b, real)) for a, b, w in exact if a < real]
            else:
                for a, b, text in s["source"]["segs"]:
                    words += subs.word_times(text, offset + a, offset + min(b, real))
        else:
            words += subs.word_times(s["narration"], offset + 0.05, offset + max(0.3, real - 0.2))
        offset += real
        clips.append(out)

    final = os.path.join(project, "final.mp4")
    cmd = [sys.executable, "-u", os.path.join(os.path.dirname(os.path.abspath(__file__)), "assemble.py"),
           "--clips", *clips, "--format", cfg["format"], "--out", final]
    covered = 0.0
    if cfg.get("captions", True):
        ass = os.path.join(project, "captions.ass")
        covered = subs.build_ass(words, W, H, ass, font=brand.caption_font(kit),
                                 highlight=brand.ass_colour(kit["caption_highlight"]),
                                 uppercase=bool(kit["caption_uppercase"]))
        cmd += ["--ass", ass]
    if kit["logo"] and os.path.exists(kit["logo"]):
        cmd += ["--logo", kit["logo"], "--logo-position", kit["logo_position"]]
    music = cfg.get("music") or kit.get("music")
    if music and os.path.exists(music):
        cmd += ["--music", music]
    run(cmd)
    got = duration(final)
    ok = abs(got - offset) < 1.5
    if copied:
        log(f"{copied} scene(s) joined to their sound without re-encoding the picture")
    record_metric(project, "render", final_seconds=round(got, 2), expected_seconds=round(offset, 2), scenes_copied=copied,
                  duration_ok=ok, caption_seconds=round(covered, 2))
    log(f"{'OK' if ok else 'WARNING: length mismatch'} - final video {got:.1f}s (scenes total {offset:.1f}s)")
    log(f"FINAL: {final}")


# ------------------------------------------------------------------ stage: qa
def stage_qa(project, cfg, force):
    cmd = [sys.executable, "-u", os.path.join(os.path.dirname(os.path.abspath(__file__)), "qa.py"),
           "--project", project]
    if not cfg.get("qa_listen", True):
        cmd.append("--no-listen")
    if subprocess.run(cmd).returncode != 0:
        fail("The quality gate found a hard failure - see qa.json in the project folder.")


RUN = {"outline": stage_outline, "script": stage_script, "voice": stage_voice,
       "visuals": stage_visuals, "render": stage_render, "qa": stage_qa}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True)
    ap.add_argument("--stage", default="all", choices=STAGES + ["all"])
    ap.add_argument("--prompt")
    ap.add_argument("--prompt-file")
    ap.add_argument("--seconds", type=int)
    ap.add_argument("--format", choices=list(FORMATS))
    ap.add_argument("--model")
    ap.add_argument("--voice")
    ap.add_argument("--voice-text")
    ap.add_argument("--language")
    ap.add_argument("--library")
    ap.add_argument("--music")
    ap.add_argument("--device", choices=["cuda", "cpu"])
    ap.add_argument("--framing", choices=["auto", "stack", "side", "wide", "single", "single-left", "single-right", "speaker"],
                    help="How episode footage is framed (a scene's own 'layout' overrides this)")
    ap.add_argument("--stills", choices=["on", "off"])
    ap.add_argument("--captions", choices=["on", "off"])
    ap.add_argument("--soundbites", choices=["on", "off"])
    ap.add_argument("--qa-listen", choices=["on", "off"], dest="qa_listen")
    ap.add_argument("--voice-check", choices=["on", "off"], dest="voice_check")
    ap.add_argument("--lipsync", choices=["on", "off"], help="Re-sync a single host's lips to the narration (MuseTalk)")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()

    project = ensure_dir(os.path.abspath(a.project))
    cfg = {"seconds": 45, "format": "9:16", "model": "gemma3:4b", "language": "English",
           "device": "cuda", "stills": False, "captions": True, "framing": "auto"}
    cfg.update(load(project))
    if a.prompt_file:
        cfg["prompt"] = read_text(a.prompt_file).strip()
    for key in ("prompt", "seconds", "format", "model", "voice", "voice_text", "language", "library", "music", "device",
                "framing"):
        if getattr(a, key) is not None:
            cfg[key] = getattr(a, key)
    for key in ("stills", "captions", "soundbites", "qa_listen", "voice_check", "lipsync"):
        if getattr(a, key) is not None:
            cfg[key] = getattr(a, key) == "on"
    if not cfg.get("prompt"):
        fail("No prompt. Pass --prompt or --prompt-file.")
    save(project, cfg)

    if a.stage != "all":
        RUN[a.stage](project, cfg, a.force)
        return
    # Each stage runs in its own process so GPU memory is fully released between models.
    for stage in STAGES[1:]:
        log(f"\n===== {stage.upper()} =====")
        cmd = [sys.executable, "-u", os.path.abspath(__file__), "--project", project, "--stage", stage]
        if subprocess.run(cmd).returncode != 0:
            fail(f"Stage '{stage}' failed. Fix the problem and run it again (step 2 in the Create tab) - finished work is kept.")
    log("\nAll stages complete.")


if __name__ == "__main__":
    main()
'@
$files['scenes.py'] = @'
"""Scene editor backend: change, re-make, add or delete one scene without redoing the rest.

  python scenes.py set    --project P --index 3 --fields-file edit.json   (fields: narration, visual, query,
                                                                           card_text, image_prompt, layout)
  python scenes.py remake --project P --index 3        (new voice take / next best footage / new still)
  python scenes.py add    --project P --index 3        (insert a card scene after scene 3)
  python scenes.py delete --project P --index 3
Then run pipeline.py --stage all: only the missing pieces are rebuilt.
"""
import argparse
import os

from common import fail, log, read_json, write_json, write_text

KINDS = ("soundbite", "footage", "card", "still")
FRAMINGS = ("auto", "stack", "side", "wide", "single", "single-left", "single-right", "speaker")
PARTS = (("voice", ".wav"), ("visuals", ".mp4"), ("visuals", ".png"), ("scenes", ".mp4"))


def _path(project, folder, n, ext):
    return os.path.join(project, folder, f"scene_{n:02}{ext}")


def invalidate(project, n, voice=True):
    for folder, ext in PARTS:
        if folder == "voice" and not voice:
            continue
        for p in (_path(project, folder, n, ext), _path(project, folder, n, ext) + ".txt"):
            if os.path.exists(p):
                os.remove(p)
    final = os.path.join(project, "final.mp4")
    if os.path.exists(final):
        os.remove(final)


def renumber(project, old, new):
    for folder, ext in PARTS:
        for tail in ("", ".txt"):
            a, b = _path(project, folder, old, ext) + tail, _path(project, folder, new, ext) + tail
            if os.path.exists(a):
                os.replace(a, b)


def find_source(project, cfg, scenes, i, skip_current=False):
    """Pick episode footage for scene i that no other scene is using."""
    import pipeline
    from library import Library, pick_soundbite

    s = scenes[i]
    lib = Library(pipeline.library_dir(cfg, project))
    if not len(lib):
        fail("No footage library. Use 'Index footage' in the Create tab first.")
    for j, other in enumerate(scenes):
        if other.get("source") and (j != i or skip_current):
            lib.mark_used(other["source"]["file"], other["source"]["start"])
    hit = lib.search(s["query"])
    if not hit:
        fail("No other matching footage found for those search words.")
    if s["visual"] == "soundbite":
        start, secs, segs, words = pick_soundbite(hit, s["query"])
        s["source"] = {"file": hit["file"], "start": start, "seconds": secs, "segs": segs, "words": words}
        s["narration"] = ""
    else:
        s["source"] = {"file": hit["file"], "start": hit["start"]}
    log(f"Scene {i + 1} now uses {os.path.basename(hit['file'])} @ {s['source']['start']}s")


def save(project, script):
    write_json(os.path.join(project, "script.json"), script)
    write_text(os.path.join(project, "script.txt"),
               "\n\n".join(s["narration"] or f"[soundbite: {s['query']}]" for s in script["scenes"]) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["set", "remake", "add", "delete"])
    ap.add_argument("--project", required=True)
    ap.add_argument("--index", type=int, required=True, help="Scene number, starting at 1")
    ap.add_argument("--fields-file", help="JSON with narration, visual, query, card_text, image_prompt")
    a = ap.parse_args()

    project = os.path.abspath(a.project)
    script = read_json(os.path.join(project, "script.json"))
    cfg = read_json(os.path.join(project, "project.json"), {})
    if not script:
        fail("This project has no script yet. Make the video first (Create tab, step 2).")
    scenes, n = script["scenes"], a.index
    if not 1 <= n <= len(scenes):
        fail(f"Scene {n} does not exist (there are {len(scenes)}).")
    s = scenes[n - 1]

    if a.action == "set":
        new = read_json(a.fields_file) or {}
        before = dict(s)
        for key in ("narration", "query", "card_text", "image_prompt"):
            if key in new:
                s[key] = " ".join(str(new[key] or "").split())
        if "layout" in new:
            layout = str(new["layout"] or "").lower()
            if layout and layout not in FRAMINGS:
                fail(f"Unknown framing '{layout}'.")
            if layout:
                s["layout"] = layout
            else:
                s.pop("layout", None)   # back to the project's framing
        visual = str(new.get("visual") or s["visual"]).lower()
        if visual not in KINDS:
            fail(f"Unknown scene type '{visual}'.")
        s["visual"] = visual
        if visual == "soundbite" and not s["query"]:
            fail("A soundbite needs search words.")
        if visual != "soundbite" and not s["narration"]:
            fail("This scene type needs narration text.")
        if visual in ("soundbite", "footage"):
            if visual != before["visual"] or s["query"] != before["query"] or "source" not in s:
                s["query"] = s["query"] or s["narration"][:200]
                find_source(project, cfg, scenes, n - 1)
            if visual == "soundbite":
                s["narration"] = ""
        else:
            s.pop("source", None)
        voice_changed = s["narration"] != before["narration"] or (visual == "soundbite") != (before["visual"] == "soundbite")
        if s != before:
            invalidate(project, n, voice=voice_changed)
            log(f"Scene {n} updated" + (" (voice will be re-made)" if voice_changed else " (voice kept)"))
        else:
            log(f"Scene {n}: nothing changed")
    elif a.action == "remake":
        if s["visual"] in ("soundbite", "footage"):
            find_source(project, cfg, scenes, n - 1, skip_current=True)
        invalidate(project, n)
        log(f"Scene {n} will be re-made")
    elif a.action == "add":
        for k in range(len(scenes), n, -1):
            renumber(project, k, k + 1)
        scenes.insert(n, {"narration": "New scene.", "visual": "card", "query": "", "card_text": "New scene",
                          "image_prompt": ""})
        invalidate(project, n + 1)
        log(f"Added scene {n + 1}")
    else:
        if len(scenes) <= 2:
            fail("A video needs at least two scenes.")
        invalidate(project, n)
        del scenes[n - 1]
        for k in range(n + 1, len(scenes) + 2):
            renumber(project, k, k - 1)
        log(f"Deleted scene {n}")
    script["edited"] = True
    save(project, script)


if __name__ == "__main__":
    main()
'@
$files['highlights.py'] = @'
"""Find the best moments in an episode and cut them into finished short videos. No narration: the hosts' own words.

  python highlights.py --lib <workspace>/library --episode <video file> --out <workspace>/highlights
                       [--count 5 --min 20 --max 45 --format 9:16 --framing speaker --model gemma3:4b]

The episode must be in the footage index (Create tab > Index footage). For each clip it writes clip_NN.mp4
and lists them, best first, in highlights.json.
"""
import argparse
import os
import re
import subprocess
import sys
import time

from common import FORMATS, duration, ensure_dir, fail, log, read_json, write_json

BATCH = 8
MAX_CANDIDATES = 64
SCHEMA = {"type": "object", "required": ["ratings"], "properties": {"ratings": {"type": "array", "items": {
    "type": "object", "required": ["id", "score", "title"],
    "properties": {"id": {"type": "integer"}, "score": {"type": "integer"}, "title": {"type": "string"}}}}}}


def passages(chunks, min_s=20.0, max_s=45.0):
    """Candidate passages built from whole transcript sentences: [{"start", "end", "text", "words"}]."""
    segs, words = [], []
    for c in sorted(chunks, key=lambda c: c["start"]):
        segs += c.get("segs") or [[c["start"], c["end"], c["text"]]]
        words += c.get("words") or []
    out, step = [], max(1, len(segs) // 200 + 1)
    for i in range(0, len(segs), step):
        start, end, text = segs[i][0], segs[i][1], [segs[i][2]]
        for seg in segs[i + 1:]:
            if seg[1] - start > max_s or (seg[0] - end) > 3.0:     # too long, or a long pause
                break
            end = seg[1]
            text.append(seg[2])
            if end - start >= (min_s + max_s) / 2 and re.search(r"[.!?]$", seg[2].strip()):
                break                                              # stop at a sentence end once long enough
        if end - start >= min_s:
            out.append({"start": round(start, 2), "end": round(end, 2), "text": " ".join(text),
                        "words": [w for w in words if w[0] >= start - 0.05 and w[1] <= end + 0.05]})
    if len(out) > MAX_CANDIDATES:                                  # keep the model's workload bounded
        keep = [round(k * (len(out) - 1) / (MAX_CANDIDATES - 1)) for k in range(MAX_CANDIDATES)]
        out = [out[k] for k in sorted(set(keep))]
    return out


def rate(cands, model, bible=""):
    """Ask the local model to score each passage 0-100 and give it a headline. Adds "score" and "title"."""
    import llm

    system = ("You pick moments from a podcast that work as standalone short videos. Reply with JSON only."
              + (f"\n\nSHOW STYLE GUIDE:\n{bible[:3000]}" if bible else ""))
    for at in range(0, len(cands), BATCH):
        batch = cands[at:at + BATCH]
        listing = "\n\n".join(f"[{at + k}] {c['text'][:900]}" for k, c in enumerate(batch))
        user = ("Rate each passage from 0 to 100 as a standalone short video. High scores need: a strong first "
                "sentence, one clear point, a story, surprise or strong opinion, and no missing context. "
                "Rambling, greetings and housekeeping score low. Give each a headline of at most 7 words.\n\n"
                f"{listing}\n\nReturn JSON: {{\"ratings\": [{{\"id\": <number in brackets>, \"score\": 0-100, \"title\": str}}]}}")
        try:
            got = llm.chat(system, user, model, schema=SCHEMA, temperature=0.2, keep_alive="5m",
                           reply_tokens=900).get("ratings") or []
        except Exception as e:  # noqa: BLE001 - one bad batch should not stop the run
            log(f"  rating failed for passages {at}-{at + len(batch) - 1} ({e})")
            got = []
        for r in got:
            try:
                i = int(r["id"])
                if at <= i < at + len(batch):
                    cands[i]["score"] = max(0, min(100, int(r["score"])))
                    cands[i]["title"] = " ".join(str(r.get("title") or "").split())[:60]
            except (KeyError, TypeError, ValueError):
                continue
        log(f"  rated {min(at + BATCH, len(cands))}/{len(cands)} passages")
    llm.unload(model)          # free the graphics card before cutting clips
    for c in cands:
        c.setdefault("score", 0)
        c.setdefault("title", "")
    return cands


def choose(cands, count):
    """The top `count` passages that do not overlap each other by more than a fifth."""
    picked = []
    for c in sorted(cands, key=lambda c: -c["score"]):
        clash = any(min(c["end"], p["end"]) - max(c["start"], p["start"]) > 0.2 * (c["end"] - c["start"]) for p in picked)
        if not clash:
            picked.append(c)
        if len(picked) == count:
            break
    return picked


def render(episode, clip, out_mp4, fmt, framing, kit, title=True):
    """One finished clip: framed footage with its own sound, word captions, headline, logo, loudness."""
    import brand
    import subs
    import visuals

    W, H = FORMATS[fmt]
    start, secs = max(0.0, clip["start"] - 0.15), clip["end"] - clip["start"] + 0.35
    raw = os.path.splitext(out_mp4)[0] + ".raw.mp4"
    used = visuals.footage_clip(episode, start, raw, secs, fmt, audio=True, choice=framing)
    real = duration(raw)
    if clip["words"]:
        words = [(w, a - start, min(b - start, real)) for a, b, w in clip["words"] if a - start < real]
    else:
        words = subs.word_times(clip["text"], 0.15, max(0.5, real - 0.2))
    ass = os.path.splitext(out_mp4)[0] + ".ass"
    subs.build_ass(words, W, H, ass, font=brand.caption_font(kit), highlight=brand.ass_colour(kit["caption_highlight"]),
                   uppercase=bool(kit["caption_uppercase"]),
                   title=(clip["title"], min(3.5, real)) if title and clip.get("title") else None)
    cmd = [sys.executable, "-u", os.path.join(os.path.dirname(os.path.abspath(__file__)), "assemble.py"),
           "--clips", raw, "--format", fmt, "--ass", ass, "--out", out_mp4]
    if kit["logo"] and os.path.exists(kit["logo"]):
        cmd += ["--logo", kit["logo"], "--logo-position", kit["logo_position"]]
    subprocess.run(cmd, check=True, capture_output=True)
    os.remove(raw)
    return used


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True)
    ap.add_argument("--episode", required=True, help="An indexed episode video file")
    ap.add_argument("--out", required=True, help="Folder for the clips (a sub-folder per episode is made)")
    ap.add_argument("--count", type=int, default=5)
    ap.add_argument("--min", type=float, default=20, dest="min_s")
    ap.add_argument("--max", type=float, default=45, dest="max_s")
    ap.add_argument("--format", default="9:16", choices=list(FORMATS))
    ap.add_argument("--framing", default="speaker")
    ap.add_argument("--model", default="gemma3:4b")
    ap.add_argument("--no-title", action="store_true", help="Do not show the headline at the top of each clip")
    a = ap.parse_args()

    import brand
    index = read_json(os.path.join(a.lib, "index.json"), {"chunks": []})
    episode = os.path.abspath(a.episode)
    chunks = [c for c in index["chunks"] if os.path.abspath(c["file"]) == episode]
    if not chunks:
        fail("That episode is not in the footage index yet. Use 'Index footage' in the Create tab first.")
    if a.min_s >= a.max_s:
        fail("The shortest length must be below the longest length.")
    t0 = time.time()
    cands = passages(chunks, a.min_s, a.max_s)
    if not cands:
        fail("No passage of that length was found in this episode. Try a shorter minimum length.")
    log(f"{len(cands)} candidate passages in {os.path.basename(episode)}; rating them with {a.model}...")
    workspace = os.path.dirname(os.path.abspath(a.lib))
    bible_path = os.path.join(workspace, "style-bible.md")
    bible = open(bible_path, encoding="utf-8-sig").read() if os.path.exists(bible_path) else ""
    picked = choose(rate(cands, a.model, bible), a.count)

    out_dir = ensure_dir(os.path.join(a.out, re.sub(r"[^\w\-]+", "-", os.path.splitext(os.path.basename(episode))[0]).strip("-")))
    kit = brand.load(os.path.join(workspace, "projects", "_"))
    report = []
    for n, clip in enumerate(picked, 1):
        out = os.path.join(out_dir, f"clip_{n:02}.mp4")
        log(f"[clip {n}/{len(picked)}] score {clip['score']}  {clip['start']:.0f}s-{clip['end']:.0f}s  {clip['title']}")
        try:
            used = render(episode, clip, out, a.format, a.framing, kit, title=not a.no_title)
        except Exception as e:  # noqa: BLE001
            log(f"  could not make this clip: {e}")
            continue
        report.append({"file": out, "score": clip["score"], "title": clip["title"], "start": clip["start"],
                       "end": clip["end"], "seconds": round(duration(out), 1), "framing": used, "text": clip["text"]})
    write_json(os.path.join(out_dir, "highlights.json"),
               {"episode": episode, "made": time.strftime("%Y-%m-%d %H:%M"), "seconds": round(time.time() - t0, 1),
                "clips": report})
    if not report:
        fail("No clips could be made.")
    log(f"Made {len(report)} clips in {out_dir}")
    log(f"HIGHLIGHTS: {out_dir}")


if __name__ == "__main__":
    main()
'@
$files['assemble.py'] = @'
"""Stitch clips, lay voiceover + music (ducked under speech), burn captions, normalise loudness, export MP4."""
import argparse
import os
import shutil
import subprocess
import tempfile

from common import FF, FORMATS, duration, fail, joinable, log, run, transcribe, venc, write_srt

LOUDNESS = "loudnorm=I=-14:TP=-1.5:LRA=11"


def has_audio(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries",
                          "stream=index", "-of", "csv=p=0", path], capture_output=True, text=True)
    return bool(out.stdout.strip())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clips", nargs="+", required=True)
    ap.add_argument("--voice", help="Voiceover WAV; replaces clip audio")
    ap.add_argument("--music", help="Background music (looped, lowered while someone speaks)")
    ap.add_argument("--music-volume", type=float, default=0.25)
    ap.add_argument("--format", default="9:16", choices=list(FORMATS))
    ap.add_argument("--captions", action="store_true", help="Transcribe and burn in plain captions")
    ap.add_argument("--ass", help="Burn in this prepared ASS caption file instead of transcribing")
    ap.add_argument("--logo", help="PNG shown in a corner of the whole video")
    ap.add_argument("--logo-position", default="top-right", choices=["top-right", "top-left"])
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    for c in a.clips + [p for p in (a.voice, a.music, a.ass, a.logo) if p]:
        if not os.path.exists(c):
            fail(f"Missing file: {c}")
    W, H = FORMATS[a.format]
    tmp = tempfile.mkdtemp(prefix="pstudio_")
    try:
        # 1. normalise every clip (size, fps, audio) so concat is safe - unless this app already wrote them that way
        norm = []
        if joinable(a.clips, W, H):
            log(f"{len(a.clips)} clips already match - joining without re-encoding")
            norm = [os.path.abspath(c) for c in a.clips]
        for i, c in enumerate([] if norm else a.clips):
            o = os.path.join(tmp, f"n{i:03}.mp4")
            vf = (f"scale={W}:{H}:force_original_aspect_ratio=decrease,"
                  f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:color=black,fps=30,format=yuv420p,setsar=1")
            cmd = FF + ["-i", c]
            if not has_audio(c):
                cmd += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-shortest"]
            cmd += ["-vf", vf, *venc(18), "-c:a", "aac", "-ar", "48000", "-ac", "2", o]
            log(f"Normalising {os.path.basename(c)}")
            run(cmd)
            norm.append(o)
        with open(os.path.join(tmp, "list.txt"), "w", encoding="utf-8") as f:
            for n in norm:
                f.write("file '" + n.replace(os.sep, "/").replace("'", "'\\''") + "'\n")
        run(FF + ["-f", "concat", "-safe", "0", "-i", "list.txt", "-c", "copy", "joined.mp4"], cwd=tmp)
        joined = os.path.join(tmp, "joined.mp4")

        # 2. captions file (ffmpeg runs inside tmp so the filter needs no Windows path escaping)
        vfilter = None
        if a.ass:
            shutil.copy(a.ass, os.path.join(tmp, "subs.ass"))
            vfilter = "ass=subs.ass"
        elif a.captions:
            write_srt(transcribe(a.voice or joined), os.path.join(tmp, "subs.srt"))
            shutil.copy(os.path.join(tmp, "subs.srt"), os.path.splitext(a.out)[0] + ".srt")
            # libass lays SRT out on a 288-line canvas, so size and margin are in those units
            style = (f"FontName=Arial,FontSize={16 if H > W else 12},Bold=1,PrimaryColour=&H00FFFFFF,"
                     f"OutlineColour=&H00000000,Outline=3,Shadow=0,Alignment=2,MarginV={28 if H > W else 20}")
            vfilter = f"subtitles=subs.srt:force_style='{style}'"

        # 3. one final pass: captions + voice/music mix + loudness
        cmd = list(FF)
        if a.voice and duration(a.voice) > duration(joined):
            cmd += ["-stream_loop", "-1"]  # loop the picture under a longer voiceover
        cmd += ["-i", "joined.mp4"]
        speech, n = "[0:a]", 1
        if a.voice:
            cmd += ["-i", os.path.abspath(a.voice)]
            speech, n = f"[{n}:a]", n + 1
        graph = []
        if a.music:
            cmd += ["-stream_loop", "-1", "-i", os.path.abspath(a.music)]
            music = n
            n += 1
            graph += [f"{speech}aresample=48000,asplit=2[sp][key]",
                      f"[{music}:a]aresample=48000,volume={a.music_volume}[mu]",
                      "[mu][key]sidechaincompress=threshold=0.03:ratio=10:attack=15:release=350[duck]",
                      f"[sp][duck]amix=inputs=2:duration=first:dropout_transition=0:normalize=0,{LOUDNESS}[aout]"]
        else:
            graph.append(f"{speech}{LOUDNESS}[aout]")
        picture = "[0:v]"
        if vfilter:
            graph.append(f"{picture}{vfilter}[capt]")
            picture = "[capt]"
        if a.logo:
            cmd += ["-i", os.path.abspath(a.logo)]
            pad = int(W * 0.04)
            x = pad if a.logo_position == "top-left" else f"W-w-{pad}"
            graph += [f"[{n}:v]scale={int(W * 0.16)}:-1[logo]", f"{picture}[logo]overlay={x}:{pad}[branded]"]
            picture = "[branded]"
        if picture != "[0:v]":
            cmd += ["-filter_complex", ";".join(graph), "-map", picture, "-map", "[aout]", *venc(20)]
        else:
            cmd += ["-filter_complex", ";".join(graph), "-map", "0:v", "-map", "[aout]", "-c:v", "copy"]
        cmd += ["-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2"]
        if a.voice:
            cmd += ["-shortest"]
        else:
            cmd += ["-t", f"{duration(joined):.3f}"]
        cmd += ["-movflags", "+faststart", "final.mp4"]
        run(cmd, cwd=tmp)

        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        shutil.copy(os.path.join(tmp, "final.mp4"), a.out)
        log(f"Rendered: {a.out}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
'@
$files['qa.py'] = @'
"""Quality gate for a finished project. Writes <project>/qa.json and exits 1 on a hard failure.

  python qa.py --project <dir> [--no-listen]
"""
import argparse
import os
import re
import subprocess
import sys

from common import FORMATS, duration, log, read_json, video_size, write_json

checks = []


def add(name, status, detail):
    checks.append({"check": name, "status": status, "detail": detail})
    log(f"  [{status:4}] {name}: {detail}")


def ffmpeg_report(path, *filters):
    out = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, *filters, "-f", "null", "-"],
                         capture_output=True, text=True)
    return out.stderr


def listen(project, script):
    """Transcribe each voice line and compare it with the script (catches garbled speech)."""
    from common import speech_match
    bad, scores = [], []
    for i, s in enumerate(script["scenes"], 1):
        wav = os.path.join(project, "voice", f"scene_{i:02}.wav")
        if s["visual"] == "soundbite" or not os.path.exists(wav):
            continue
        score = speech_match(wav, s["narration"])
        scores.append(score)
        if score < 0.6:
            bad.append(f"scene {i} ({score:.0%})")
    if not scores:
        return add("voice matches script", "skip", "no voice lines")
    avg = sum(scores) / len(scores)
    add("voice matches script", "warn" if bad else "pass",
        f"average {avg:.0%} of script words heard" + (f"; re-make in the Scenes tab: {', '.join(bad)}" if bad else ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True)
    ap.add_argument("--no-listen", action="store_true", help="Skip the speech-to-text check of the voice")
    a = ap.parse_args()
    project = os.path.abspath(a.project)
    cfg = read_json(os.path.join(project, "project.json"), {})
    script = read_json(os.path.join(project, "script.json"), {"scenes": []})
    metrics = read_json(os.path.join(project, "metrics.json"), {})
    final = os.path.join(project, "final.mp4")
    if not os.path.exists(final):
        add("final video exists", "FAIL", "final.mp4 is missing")
    else:
        d = duration(final)
        expected = metrics.get("render", {}).get("expected_seconds", d)
        add("length matches scenes", "pass" if abs(d - expected) < 1.5 else "FAIL", f"{d:.1f}s (scenes total {expected:.1f}s)")
        target = float(cfg.get("seconds", d))
        off = abs(d - target) / target if target else 0
        add("length near target", "pass" if off <= 0.25 else "warn", f"{d:.0f}s vs {target:.0f}s asked ({off:.0%} off)")
        want = FORMATS.get(cfg.get("format", "9:16"))
        got = video_size(final)
        add("resolution", "pass" if got == want else "FAIL", f"{got[0]}x{got[1]}")

        rep = ffmpeg_report(final, "-vf", "blackdetect=d=0.5:pix_th=0.10", "-af",
                            "silencedetect=noise=-45dB:d=1.5,ebur128")
        if "Stream #0" not in rep or "Audio:" not in rep:
            add("has audio", "FAIL", "no audio stream")
        else:
            m = re.findall(r"I:\s+(-?[\d.]+) LUFS", rep)
            if m:
                lufs = float(m[-1])
                add("loudness", "pass" if -17 <= lufs <= -11 else "warn", f"{lufs:.1f} LUFS (target -14)")
            black = [float(x) for x in re.findall(r"black_duration:([\d.]+)", rep)]
            add("no black frames", "pass" if not black else "warn",
                "none" if not black else f"{len(black)} stretch(es), {sum(black):.1f}s")
            silent = [float(x) for x in re.findall(r"silence_duration: ([\d.]+)", rep)]
            add("no long silences", "pass" if not silent else "warn",
                "none" if not silent else f"{len(silent)} gap(s), longest {max(silent):.1f}s")
        cov = metrics.get("render", {}).get("caption_seconds")
        if cov is not None and d:
            add("caption coverage", "pass" if cov / d >= 0.8 else "warn", f"{cov / d:.0%} of the video")

    kinds = [s["visual"] for s in script["scenes"]]
    if kinds:
        top = max(kinds.count(k) for k in set(kinds)) / len(kinds)
        add("visual variety", "pass" if (top < 0.8 or len(kinds) < 4) else "warn",
            ", ".join(f"{k} x{kinds.count(k)}" for k in sorted(set(kinds))))
    if not a.no_listen and script["scenes"]:
        try:
            listen(project, script)
        except Exception as e:  # noqa: BLE001
            add("voice matches script", "skip", f"speech-to-text unavailable ({e})")

    failed = [c for c in checks if c["status"] == "FAIL"]
    warned = [c for c in checks if c["status"] == "warn"]
    verdict = "FAIL" if failed else ("PASS WITH WARNINGS" if warned else "PASS")
    write_json(os.path.join(project, "qa.json"), {"verdict": verdict, "checks": checks})
    log(f"QUALITY GATE: {verdict}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
'@
$files['stylebible.py'] = @'
"""Build style-bible.md on this PC from the indexed episodes: transcripts + measured pacing, written by the local model.

  python stylebible.py --lib <workspace>/library --out <workspace>/style-bible.md [--model gemma3:4b]
"""
import argparse
import os
import re
import subprocess

from common import duration, fail, log, read_json, write_text


def cut_rate(video, seconds=180):
    """Scene cuts per minute over the first few minutes (ffmpeg scene detection)."""
    span = min(seconds, duration(video))
    if span < 5:
        return None
    out = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-t", str(span), "-i", video, "-an",
                          "-vf", "scale=320:-2,select='gt(scene,0.30)',showinfo", "-f", "null", "-"],
                         capture_output=True, text=True)
    return len(re.findall(r"pts_time:", out.stderr)) / (span / 60.0)


def measure(index):
    files = [f for f in index["files"] if os.path.exists(f)]
    lengths = [duration(f) for f in files]
    words = secs = 0.0
    for c in index["chunks"]:
        for a, b, t in c.get("segs") or [[c["start"], c["end"], c["text"]]]:
            words += len(t.split())
            secs += max(0.0, b - a)
    cuts = [r for r in (cut_rate(f) for f in sorted(files, key=duration)[:4]) if r is not None]
    shorts = [x for x in lengths if x <= 180]
    return {
        "videos": len(files),
        "short_videos": len(shorts),
        "typical_short_seconds": round(sorted(shorts)[len(shorts) // 2]) if shorts else None,
        "speaking_words_per_second": round(words / secs, 2) if secs else None,
        "cuts_per_minute": round(sum(cuts) / len(cuts), 1) if cuts else None,
    }


def sample_text(index, budget=7000):
    """Evenly spaced transcript excerpts, plus the opening lines of each video (the hooks)."""
    by_file = {}
    for c in index["chunks"]:
        by_file.setdefault(c["file"], []).append(c)
    hooks = [f"- {os.path.basename(f)}: {cs[0]['text'][:220]}" for f, cs in list(by_file.items())[:25]]
    chunks = index["chunks"]
    step = max(1, len(chunks) // 20)
    body = [c["text"] for c in chunks[::step]]
    text = "OPENING LINES:\n" + "\n".join(hooks) + "\n\nEXCERPTS:\n" + "\n---\n".join(body)
    return text[:budget]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--model", default="gemma3:4b")
    a = ap.parse_args()

    index = read_json(os.path.join(a.lib, "index.json"))
    if not index or not index.get("chunks"):
        fail("No footage library yet. Use 'Index footage' in the Create tab first.")
    log("Measuring pacing (cut rate, speaking speed, lengths)...")
    stats = measure(index)
    log(f"  {stats}")

    import llm
    system = ("You are a video producer writing a style guide for a podcast's short videos. "
              "Base every statement on the transcript excerpts and measurements given. "
              "If something cannot be known from them, say 'not observed'. Plain markdown.")
    user = (f"MEASUREMENTS:\n{stats}\n\n{sample_text(index)}\n\n"
            "Write the style guide with exactly these sections:\n"
            "## Voice and tone\n## Recurring topics\n## Hook patterns (with 8 example hooks in this voice)\n"
            "## Pacing and length\n## Vocabulary and phrases to use\n## Things to avoid\n## Call-to-action style")
    text = llm.chat(system, user, a.model, temperature=0.4)
    header = ("# Style bible\n\n_Built locally from the indexed episodes._\n\n## Measured\n"
              + "\n".join(f"- {k.replace('_', ' ')}: {v}" for k, v in stats.items() if v is not None) + "\n\n")
    write_text(a.out, header + text.strip() + "\n")
    log(f"Saved {a.out}")


if __name__ == "__main__":
    main()
'@
$files['modelbench.py'] = @'
"""Compare the local language models on this app's real job (writing a script and shot list) and pick the best.

  python modelbench.py --workspace <workspace> [--save] [--try phi4-mini gemma3:4b ...]

Each installed chat model writes the same two scripts. Scoring (0-100): a usable script 50, length close to the
target 30, speed 20. With --save the winner becomes the default model (workspace/settings.json).
"""
import argparse
import os
import subprocess
import time

from common import log, read_json, write_json

OUTLINES = [
    (40, "TITLE: The meeting that should have been an email\nHOOK: Half your meetings are costing you a full day a week.\n"
         "BEATS:\n1. Most meetings have no decision to make\n2. Count the people times the minutes\n"
         "3. One rule: no agenda, no meeting\n4. What to send instead\nCTA: Try it for one week and tell us what happened."),
    (30, "TITLE: Price it higher\nHOOK: You are not too expensive. You are too vague.\n"
         "BEATS:\n1. Buyers pay for certainty\n2. Say exactly what happens and when\n3. Raise the price after you add proof\n"
         "CTA: Follow for more plain talk about running a business."),
]
CANDIDATES = ["phi4-mini", "gemma3:4b", "qwen3:4b", "llama3.2:3b"]


def trial(model, target, outline, kinds):
    """One script attempt. Returns (points 0-100, seconds, note)."""
    import llm
    import pipeline

    system, user = pipeline.script_request(outline, target, kinds)
    t0 = time.time()
    try:
        raw = llm.chat(system, user, model, schema=pipeline.scene_schema(kinds), temperature=0.6, keep_alive="5m")
    except Exception as e:  # noqa: BLE001
        return 0.0, time.time() - t0, f"error: {str(e)[:60]}"
    took = time.time() - t0
    scenes = pipeline.clean_scenes(raw, kinds)
    if len(scenes) < 3:
        return 0.0, took, "unusable script"
    est = pipeline.estimate_seconds(scenes)
    off = abs(est - target) / target
    points = 50 + 30 * max(0.0, 1 - off / 0.5) + 20 * max(0.0, min(1.0, (120 - took) / 100))
    return points, took, f"{len(scenes)} scenes, ~{est:.0f}s for a {target}s target"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--save", action="store_true", help="Make the winner the default model")
    ap.add_argument("--try", nargs="*", default=None, dest="pull",
                    help="Also download and test these models (default: a short list of small models)")
    a = ap.parse_args()

    import llm
    llm.ensure_server()
    for name in (CANDIDATES if a.pull is None else a.pull):
        if not llm._installed(name, llm.models()):
            log(f"Trying to download {name}...")
            try:
                ok = subprocess.run(["ollama", "pull", name], capture_output=True).returncode == 0
            except OSError:
                ok = False
            if not ok:
                log(f"  {name} is not available - skipped")
    models = [m for m in llm.models() if "embed" not in m]
    if not models:
        raise SystemExit("ERROR: no local chat model is installed. Run: ollama pull gemma3:4b")
    kinds = ["footage", "card"]
    rows = []
    for m in models:
        log(f"Testing {m}...")
        trial(m, *OUTLINES[1], kinds)               # warm-up: loading the model should not count against its speed
        runs = [trial(m, target, outline, kinds) for target, outline in OUTLINES]
        llm.unload(m)
        for points, took, note in runs:
            log(f"   {points:5.1f} points in {took:5.1f}s  ({note})")
        rows.append({"model": m, "score": round(sum(r[0] for r in runs) / len(runs), 1),
                     "seconds": round(sum(r[1] for r in runs) / len(runs), 1), "notes": [r[2] for r in runs]})
    rows.sort(key=lambda r: (-r["score"], r["seconds"]))
    log("\nModel                      Score   Avg seconds")
    for r in rows:
        log(f"{r['model']:<26} {r['score']:5.1f}   {r['seconds']:6.1f}")
    best = rows[0]
    write_json(os.path.join(a.workspace, "model-comparison.json"), {"when": time.strftime("%Y-%m-%d %H:%M"), "results": rows})
    if best["score"] <= 0:
        raise SystemExit("ERROR: no model produced a usable script.")
    if a.save:
        path = os.path.join(a.workspace, "settings.json")
        settings = read_json(path, {}) or {}
        settings["model"] = best["model"]
        write_json(path, settings)
        log(f"\nDefault model is now {best['model']}.")
    log(f"BEST MODEL: {best['model']}")


if __name__ == "__main__":
    main()
'@
$files['publish.py'] = @'
"""Publish a finished project to YouTube, with a title and description written by the local model.

  python publish.py pack   --project P [--model gemma3:4b]   writes publish.json (title, description, tags) + thumbnail.jpg
  python publish.py upload --project P --secrets client_secret.json [--token token.json]

Upload uses the YouTube Data API with your own Google sign-in. Nothing is uploaded until you run `upload`,
and the video is private unless publish.json says otherwise. Scheduling ("publish_at") needs privacy "private".
"""
import argparse
import datetime
import os
import subprocess

from common import FF, fail, log, read_json, read_text, write_json

SCOPES = ["https://www.googleapis.com/auth/youtube.upload"]
PACK_SCHEMA = {"type": "object", "required": ["title", "description", "tags"], "properties": {
    "title": {"type": "string"}, "description": {"type": "string"},
    "tags": {"type": "array", "items": {"type": "string"}}}}
DEFAULTS = {"title": "", "description": "", "tags": "", "privacy": "private", "publish_at": ""}


def load(project):
    data = dict(DEFAULTS)
    data.update(read_json(os.path.join(project, "publish.json"), {}) or {})
    return data


def pack(project, model):
    """Write a title, description and tags from the script, and cut a thumbnail from the video."""
    import llm

    script_path = os.path.join(project, "script.txt")
    if not os.path.exists(script_path):
        fail("This project has no script yet. Make the video first.")
    script = read_text(script_path)[:4000]
    title = (read_json(os.path.join(project, "script.json"), {}) or {}).get("title", "")
    got = llm.chat("You write YouTube titles and descriptions for short podcast videos. Reply with JSON only. "
                   "Be specific and honest: no clickbait the video does not deliver, no emojis.",
                   f"Working title: {title}\n\nWhat is said in the video:\n{script}\n\n"
                   "Return JSON: \"title\" (under 70 characters), \"description\" (2 to 4 short sentences, then a blank "
                   "line, then 3 to 5 hashtags), \"tags\" (5 to 10 short search phrases, no # sign).",
                   model, schema=PACK_SCHEMA, temperature=0.5)
    data = load(project)
    data["title"] = " ".join(str(got.get("title") or title).split())[:100]
    data["description"] = str(got.get("description") or "").strip()[:4900]
    tags = [" ".join(str(t).replace("#", "").split()) for t in (got.get("tags") or []) if str(t).strip()]
    data["tags"] = ", ".join(tags[:15])
    write_json(os.path.join(project, "publish.json"), data)
    final = os.path.join(project, "final.mp4")
    if os.path.exists(final):
        subprocess.run(FF + ["-ss", "1", "-i", final, "-frames:v", "1", "-q:v", "2",
                             os.path.join(project, "thumbnail.jpg")], check=False)
    log(f"Title: {data['title']}\nTags: {data['tags']}\n\n{data['description']}")
    return data


def schedule_time(text):
    """'2026-12-01 09:30' (your local time) or an ISO time -> RFC 3339 UTC, or '' when empty."""
    text = (text or "").strip()
    if not text:
        return ""
    try:
        when = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        fail("Schedule time must look like 2026-12-01 09:30")
    if when.tzinfo is None:
        when = when.astimezone()                 # treat as this PC's local time
    if when <= datetime.datetime.now(datetime.timezone.utc):
        fail("The schedule time is in the past.")
    return when.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def request_body(data):
    """The YouTube videos.insert body for these publish settings (validated)."""
    title = data["title"].strip()
    if not title:
        fail("Add a title first.")
    if len(title) > 100:
        fail("The title is over YouTube's 100-character limit.")
    privacy = (data.get("privacy") or "private").lower()
    if privacy not in ("private", "unlisted", "public"):
        fail(f"Unknown privacy setting '{privacy}'.")
    status = {"privacyStatus": privacy, "selfDeclaredMadeForKids": False}
    at = schedule_time(data.get("publish_at"))
    if at:
        if privacy != "private":
            fail("A scheduled video must be set to private; YouTube makes it public at the scheduled time.")
        status["publishAt"] = at
    tags = [t.strip() for t in str(data.get("tags") or "").split(",") if t.strip()]
    return {"snippet": {"title": title, "description": data.get("description", ""), "tags": tags, "categoryId": "22"},
            "status": status}


def upload(project, service, media):
    """Send final.mp4 with the publish settings. `service` is a YouTube API client, `media` the upload object."""
    data = load(project)
    body = request_body(data)
    log(f"Uploading '{body['snippet']['title']}' as {body['status']['privacyStatus']}"
        + (f", scheduled for {body['status']['publishAt']}" if "publishAt" in body["status"] else "") + "...")
    request = service.videos().insert(part="snippet,status", body=body, media_body=media)
    response = None
    while response is None:
        progress, response = request.next_chunk()
        if progress:
            log(f"  {int(progress.progress() * 100)}%")
    data["video_id"] = response["id"]
    data["url"] = f"https://youtu.be/{response['id']}"
    data["uploaded"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    write_json(os.path.join(project, "publish.json"), data)
    log(f"UPLOADED: {data['url']}")
    return data


def youtube_service(secrets, token):
    """Sign in (a browser window opens the first time) and return a YouTube API client."""
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build

    creds = None
    if os.path.exists(token):
        creds = Credentials.from_authorized_user_file(token, SCOPES)
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            if not os.path.exists(secrets):
                fail("YouTube sign-in file not found. In the Publish tab press 'YouTube sign-in file...' "
                     "and choose the client_secret JSON from your Google Cloud project.")
            log("Opening your browser to sign in to YouTube...")
            creds = InstalledAppFlow.from_client_secrets_file(secrets, SCOPES).run_local_server(port=0)
        with open(token, "w", encoding="utf-8") as f:
            f.write(creds.to_json())
    return build("youtube", "v3", credentials=creds)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["pack", "upload"])
    ap.add_argument("--project", required=True)
    ap.add_argument("--model", default="gemma3:4b")
    ap.add_argument("--secrets", help="Google OAuth client_secret JSON (desktop app)")
    ap.add_argument("--token", help="Where the sign-in is remembered")
    a = ap.parse_args()
    project = os.path.abspath(a.project)
    if a.action == "pack":
        pack(project, a.model)
        return
    final = os.path.join(project, "final.mp4")
    if not os.path.exists(final):
        fail("This project has no finished video yet.")
    request_body(load(project))                       # check the settings before asking anyone to sign in
    workspace = os.path.dirname(os.path.dirname(project))
    secrets = a.secrets or os.path.join(workspace, "youtube_client_secret.json")
    token = a.token or os.path.join(workspace, "youtube_token.json")
    from googleapiclient.http import MediaFileUpload
    upload(project, youtube_service(secrets, token), MediaFileUpload(final, chunksize=8 * 1024 * 1024, resumable=True))


if __name__ == "__main__":
    main()
'@
$files['recording.py'] = @'
"""Edit a raw recording, the hybrid way: this PC prepares it, Claude Code edits it with the Herk Edit Kit.

  python recording.py prepare --recording take.mp4 --slug my-take [--tighten]
        copy into the kit, transcribe locally (and optionally remove pauses here), write the prompts for Claude Code
  python recording.py split   --recording long.mp4 --slug my-talk --minutes 8 [--tighten]
        cut a long recording into parts at natural pauses; each part becomes its own kit project
  python recording.py join    --slug my-talk                       join the edited parts into one video
  python recording.py tighten --recording take.mp4 --out tight.mp4  quick local silence trim, no AI
  python recording.py render  --video in.mp4 --keep keep.json --out out.mp4
        render a list of kept time ranges piece by piece (memory-safe; Claude Code is told to use this)

The Herk Edit Kit (MIT, by Nate Herk) lives in <PodcastStudio>/repos/herk-edit-kit. Its skills run inside
Claude Code, which is a cloud model: the transcript and editing decisions go to Claude; the video files stay here.

Memory: cutting many pieces out of one video with a single ffmpeg filter graph (trim/atrim + concat) keeps
decoded frames for every later piece in memory. Measured on a 10-minute 1080p file with 60 cuts it passed
13 GB and was killed. Everything here renders one piece at a time instead (under 0.5 GB).
"""
import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

from common import (FF, FORMATS, duration, ensure_dir, fail, log, read_json, studio_root, transcribe_words, venc,
                    video_size, write_json, write_text)

SLUG = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
SKILLS = {"short": "short-form-edit", "long": "edit-video"}
APP = os.path.dirname(os.path.abspath(__file__))


def kit_dir():
    return os.environ.get("PSTUDIO_KIT") or os.path.join(studio_root(), "repos", "herk-edit-kit")


def make_slug(name):
    return re.sub(r"[^a-z0-9]+", "-", os.path.splitext(os.path.basename(name))[0].lower()).strip("-") or "recording"


def kit_transcript(segments, seconds):
    """Our word-level transcript in the kit's format: {"text", "audio_duration_secs", "words": [{"text", "start", "end"}]}."""
    words = [{"text": w, "start": a, "end": b} for seg in segments for a, b, w in seg["words"]]
    return {"text": " ".join(seg["text"] for seg in segments).strip(), "audio_duration_secs": round(seconds, 3),
            "words": words}


def prompt(slug, kind, workspace, tightened=False):
    """What the app asks Claude Code to do, as plain text the user can read and change."""
    rules = os.path.join(workspace, "house-rules.md")
    brand = os.path.join(workspace, "brand.json")
    bible = os.path.join(workspace, "style-bible.md")
    render = os.path.join(APP, "recording.py")
    py = sys.executable
    if tightened:
        source = (f"- Source: video-projects/{slug}/assets/silenced.mp4 with its transcript silenced.json. Pauses were "
                  "already removed on this PC, so skip the cut-silences render and start with mistakes. raw.mp4 and "
                  "raw.json are the untouched original; keep them.\n")
    else:
        source = (f"- Source: video-projects/{slug}/assets/raw.mp4. Keep it untouched. Transcript: "
                  f"video-projects/{slug}/assets/raw.json, made on this PC in this kit's word-level format.\n")
    return (
        f"Use the {SKILLS[kind]} skill to edit the recording in video-projects/{slug}.\n\n"
        + source +
        "- Do not call ElevenLabs, Kie.ai or any other paid or cloud service, and do not upload the footage anywhere.\n"
        "- Follow the kit's order: cut silences, then mistakes, then the story and motion graphics.\n"
        "- This PC has 16 GB of memory and a 4 GB graphics card. Do not render cuts with one ffmpeg filter graph of "
        "many trim/atrim filters: it keeps frames for every later piece in memory and runs out on long recordings. "
        f"To render a list of kept ranges, write them as JSON [[start, end], ...] in seconds and run:\n"
        f"  \"{py}\" \"{render}\" render --video <input.mp4> --keep <keep.json> --out <output.mp4>\n"
        "  It renders one piece at a time and joins them. If a HyperFrames render runs out of memory, render the "
        "composition in shorter sections and join them the same way.\n"
        f"- House rules: read {rules} if it exists and follow every rule. When I give you a note about the edit, "
        "apply it and add it to that file as one short rule so the next edit follows it too.\n"
        f"- Brand: use the colours, font and logo in {brand} if it exists. Show style: {bible} if it exists.\n"
        "- Show me the planned cuts before rendering, then render the final video into this project's renders folder "
        "and tell me its path.\n")


def _kit_project(slug):
    """Create (or reuse) video-projects/<slug> inside the kit. Returns its folder."""
    kit = kit_dir()
    if not os.path.exists(os.path.join(kit, "CLAUDE.md")):
        fail(f"The Herk Edit Kit is not installed at {kit}. Re-run Setup-PodcastStudio.ps1.")
    if not SLUG.match(slug):
        fail("The project name must be lowercase letters, digits and dashes, like my-first-take.")
    project = os.path.join(kit, "video-projects", slug)
    if not os.path.exists(project):
        made = False
        if os.path.exists(os.path.join(kit, "node_modules", "gsap")):
            done = subprocess.run(["node", os.path.join("scripts", "new-video.mjs"), slug], cwd=kit,
                                  capture_output=True, text=True, shell=os.name == "nt")
            made = done.returncode == 0 and os.path.exists(project)
            if not made:
                log("  the kit could not create its starter project: " + (done.stderr or done.stdout)[-200:].strip())
        else:
            log("  the kit's packages are not installed (npm ci) - making a bare project; Claude Code can finish the setup")
        if not made:
            for sub in ("assets", "compositions", "renders"):
                ensure_dir(os.path.join(project, sub))
    ensure_dir(os.path.join(project, "assets"))
    return project


def _finish_project(project, slug, workspace, words, total, tighten):
    """Write raw.json (and silenced.mp4/.json when tightening) and the two prompts."""
    assets = os.path.join(project, "assets")
    write_json(os.path.join(assets, "raw.json"), kit_transcript_from_words(words, total))
    if tighten:
        silenced = os.path.join(assets, "silenced.mp4")
        ranges = keep_ranges(words, total)
        if not os.path.exists(silenced) or abs(duration(silenced) - sum(b - a for a, b in ranges)) > 0.5:
            log("Removing pauses on this PC...")
            render_pieces(os.path.join(assets, "raw.mp4"), ranges, silenced)
        moved = retime(words, ranges)
        write_json(os.path.join(assets, "silenced.json"), kit_transcript_from_words(moved, duration(silenced)))
    for kind in SKILLS:
        write_text(os.path.join(project, f"prompt-{kind}.txt"), prompt(slug, kind, workspace, tightened=tighten))


def kit_transcript_from_words(words, seconds):
    return {"text": " ".join(w for _, _, w in words), "audio_duration_secs": round(seconds, 3),
            "words": [{"text": w, "start": a, "end": b} for a, b, w in words]}


def _words(recording, whisper, cache):
    segs = transcribe_words(recording, whisper, cache=cache)
    words = [w for seg in segs for w in seg["words"]]
    if not words:
        fail("No speech was found in this recording.")
    return words


def prepare(recording, slug, workspace, whisper="small", tighten=False):
    if not os.path.exists(recording):
        fail(f"Recording not found: {recording}")
    project = _kit_project(slug)
    assets = os.path.join(project, "assets")
    raw = os.path.join(assets, "raw.mp4")
    if not os.path.exists(raw) or abs(duration(raw) - duration(recording)) > 0.5:
        if recording.lower().endswith(".mp4"):
            shutil.copy2(recording, raw)
        else:
            log("Converting the recording to MP4...")
            subprocess.run(FF + ["-i", recording, *venc(18), "-c:a", "aac", "-b:a", "192k", raw], check=True)
    cached = os.path.join(assets, "raw.words.json")
    if os.path.exists(cached):
        words = [tuple(w) for w in read_json(cached)]
    else:
        log("Transcribing on this PC (word-level)...")
        words = _words(raw, whisper, os.path.join(assets, "raw.partial.json"))
        write_json(cached, words)
        if os.path.exists(os.path.join(assets, "raw.partial.json")):
            os.remove(os.path.join(assets, "raw.partial.json"))
    total = duration(raw)
    _finish_project(project, slug, workspace, [list(w) for w in words], total, tighten)
    log(f"Ready: {project}\n  raw.mp4 ({total:.0f}s), raw.json ({len(words)} words)"
        + (", silenced.mp4" if tighten else "") + ", prompt-short.txt, prompt-long.txt")
    log(f"RECORDING PROJECT: {project}")
    return project


def split_points(words, total, minutes):
    """Where to cut a long recording into parts of about `minutes`: at the longest pause within a minute of
    each target time, so no sentence is cut in half. Returns [(start, end), ...] covering the whole recording."""
    size = minutes * 60.0
    if total <= size * 1.25:
        return [(0.0, round(total, 3))]
    cuts, target = [], size
    while target < total - size * 0.25:
        best, width = None, 0.0
        for (_, b0, _), (a1, _, _) in zip(words, words[1:]):
            mid = (b0 + a1) / 2
            if abs(mid - target) <= 60 and a1 - b0 > width:
                best, width = mid, a1 - b0
        cut = best if best is not None else target
        cuts.append(round(cut, 3))
        target = cut + size
    edges = [0.0] + cuts + [round(total, 3)]
    return list(zip(edges, edges[1:]))


def split(recording, slug, workspace, minutes=8.0, whisper="small", tighten=False):
    """Cut a long recording into parts at natural pauses, one kit project per part, so each edit and render
    stays small enough for a 16 GB PC."""
    if not os.path.exists(recording):
        fail(f"Recording not found: {recording}")
    if not SLUG.match(slug):
        fail("The project name must be lowercase letters, digits and dashes, like my-first-take.")
    if minutes < 2:
        fail("Parts must be at least 2 minutes long.")
    total = duration(recording)
    cache_dir = ensure_dir(os.path.join(os.path.dirname(recording), ".pstudio"))
    cached = os.path.join(cache_dir, make_slug(recording) + ".words.json")
    if os.path.exists(cached) and (read_json(cached) or {}).get("total") == round(total, 2):
        words = [list(w) for w in read_json(cached)["words"]]
    else:
        log("Transcribing on this PC (word-level, in 10-minute pieces)...")
        words = _words(recording, whisper, os.path.join(cache_dir, make_slug(recording) + ".partial.json"))
        write_json(cached, {"total": round(total, 2), "words": words})
    parts = split_points(words, total, minutes)
    if len(parts) == 1:
        log(f"This recording is only {total / 60:.1f} minutes - no need to split it. Preparing it as one project.")
        return [prepare(recording, slug, workspace, whisper, tighten)]
    log(f"Splitting {total / 60:.1f} minutes into {len(parts)} parts at natural pauses...")
    projects = []
    for n, (a, b) in enumerate(parts, 1):
        part_slug = f"{slug}-part-{n:02}"
        project = _kit_project(part_slug)
        raw = os.path.join(project, "assets", "raw.mp4")
        if not os.path.exists(raw) or abs(duration(raw) - (b - a)) > 0.5:
            render_pieces(recording, [(a, b)], raw)
        mine = [[round(s - a, 2), round(e - a, 2), w] for s, e, w in words if s >= a - 0.01 and e <= b + 0.01]
        _finish_project(project, part_slug, workspace, mine, duration(raw), tighten)
        log(f"  part {n}: {a / 60:5.1f}-{b / 60:5.1f} min -> video-projects/{part_slug}")
        projects.append(project)
    log(f"PARTS: {len(projects)}")
    return projects


def join(slug):
    """Join the newest render of every part of `slug` into video-projects/<slug>-joined.mp4."""
    kit = kit_dir()
    parts = sorted(glob.glob(os.path.join(kit, "video-projects", f"{slug}-part-[0-9][0-9]")))
    if not parts:
        fail(f"No parts named {slug}-part-01, -02 ... were found. Use 'Split into parts' first.")
    clips, missing = [], []
    for p in parts:
        renders = sorted(glob.glob(os.path.join(p, "renders", "*.mp4")), key=os.path.getmtime)
        (clips.append(renders[-1]) if renders else missing.append(os.path.basename(p)))
    if missing:
        fail("These parts have not been rendered yet: " + ", ".join(missing))
    w, h = video_size(clips[0])
    fmt = next((k for k, v in FORMATS.items() if v == (w, h)), "16:9" if w >= h else "9:16")
    out = os.path.join(kit, "video-projects", f"{slug}-joined.mp4")
    log(f"Joining {len(clips)} parts ({fmt})...")
    subprocess.run([sys.executable, "-u", os.path.join(APP, "assemble.py"), "--clips", *clips, "--format", fmt,
                    "--out", out], check=True)
    log(f"JOINED: {out}")
    return out


def keep_ranges(words, total, gap=0.55, head=0.22, tail=0.34):
    """Parts of a recording to keep once dead air is trimmed, using the rules documented in the kit's cut-silences
    skill: pauses under `gap` stay; longer ones shrink to a natural breath (0.24 s after a 2 s+ pause, 0.20 s after
    a sentence, 0.14 s otherwise); silence before the first and after the last word is trimmed to `head`/`tail`."""
    if not words:
        return [(0.0, total)]
    ranges, start = [], max(0.0, words[0][0] - head)
    for (a0, b0, w0), (a1, b1, w1) in zip(words, words[1:]):
        pause = a1 - b0
        if pause >= gap:
            breath = 0.24 if pause >= 2.0 else 0.20 if w0.rstrip()[-1:] in ".!?" else 0.14
            ranges.append((start, b0 + breath * 0.6))
            start = a1 - breath * 0.4
    ranges.append((start, min(total, words[-1][1] + tail)))
    return [(round(a, 3), round(b, 3)) for a, b in ranges if b - a > 0.02]


def retime(words, ranges):
    """Word timings moved onto the trimmed timeline."""
    out, shift = [], 0.0
    for a, b in ranges:
        out += [[round(s - a + shift, 2), round(e - a + shift, 2), w] for s, e, w in words if s >= a - 0.01 and e <= b + 0.01]
        shift += b - a
    return out


def render_pieces(src, ranges, out_mp4):
    """Render the kept time ranges of `src` one at a time and join them: memory stays under about 0.5 GB however
    long the recording is. Pieces keep their sound uncompressed until the end, so the joins have no gaps."""
    ranges = [(float(a), float(b)) for a, b in ranges if float(b) - float(a) > 0.02]
    if not ranges:
        fail("Nothing to keep.")
    tmp = tempfile.mkdtemp(prefix="pstudio_cut_")
    try:
        names = []
        for n, (a, b) in enumerate(ranges):
            name = f"p{n:04}.mkv"
            subprocess.run(FF + ["-ss", f"{a:.3f}", "-i", src, "-t", f"{b - a:.3f}", "-map", "0:v:0", "-map", "0:a:0?",
                                 *venc(18), "-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2", os.path.join(tmp, name)],
                           check=True)
            names.append(name)
            if len(ranges) > 20 and (n + 1) % 20 == 0:
                log(f"  rendered {n + 1} of {len(ranges)} pieces")
        with open(os.path.join(tmp, "list.txt"), "w", encoding="utf-8") as f:
            f.write("".join(f"file '{x}'\n" for x in names))
        os.makedirs(os.path.dirname(os.path.abspath(out_mp4)), exist_ok=True)
        subprocess.run(FF + ["-f", "concat", "-safe", "0", "-i", "list.txt", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                             "-movflags", "+faststart", os.path.abspath(out_mp4)], cwd=tmp, check=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return out_mp4


def read_keep(path):
    """Kept ranges from JSON: [[start, end], ...], [{"start", "end"}, ...], or {"keep": either of those}."""
    data = read_json(path)
    if isinstance(data, dict):
        data = data.get("keep") or data.get("keepRanges") or data.get("ranges") or []
    out = []
    for r in data or []:
        if isinstance(r, dict):
            r = (r.get("start", r.get("from")), r.get("end", r.get("to")))
        try:
            a, b = float(r[0]), float(r[1])
        except (TypeError, ValueError, IndexError):
            fail(f"Could not read the range {r!r} in {path}.")
        if b > a:
            out.append((a, b))
    if not out:
        fail(f"No kept ranges found in {path}.")
    return sorted(out)


def tighten(recording, out_mp4, whisper="small"):
    """Trim dead air from a recording on this PC (no AI decisions): writes the video and its re-timed words."""
    if not os.path.exists(recording):
        fail(f"Recording not found: {recording}")
    total = duration(recording)
    words = [w for seg in transcribe_words(recording, whisper, cache=out_mp4 + ".partial.json") for w in seg["words"]]
    if os.path.exists(out_mp4 + ".partial.json"):
        os.remove(out_mp4 + ".partial.json")
    if not words:
        fail("No speech was found in this recording.")
    ranges = keep_ranges(words, total)
    render_pieces(recording, ranges, out_mp4)
    kept = duration(out_mp4)
    write_json(os.path.splitext(out_mp4)[0] + ".words.json", retime(words, ranges))
    log(f"Trimmed {total - kept:.1f}s of dead air ({(total - kept) / total:.0%}): {total:.1f}s -> {kept:.1f}s in {len(ranges)} pieces")
    log(f"TIGHTENED: {out_mp4}")
    return ranges


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["prepare", "split", "join", "tighten", "render"])
    ap.add_argument("--recording")
    ap.add_argument("--slug")
    ap.add_argument("--workspace", default=os.path.join(studio_root(), "workspace"))
    ap.add_argument("--out")
    ap.add_argument("--whisper", default="small")
    ap.add_argument("--tighten", action="store_true", help="Remove pauses on this PC before handing over to Claude Code")
    ap.add_argument("--minutes", type=float, default=8.0, help="Length of each part when splitting")
    ap.add_argument("--video", help="render: the input video")
    ap.add_argument("--keep", help="render: JSON list of [start, end] ranges to keep")
    a = ap.parse_args()
    need = {"prepare": "recording", "split": "recording", "tighten": "recording", "join": "slug"}
    if a.action in need and not getattr(a, need[a.action]):
        fail(f"--{need[a.action]} is required for {a.action}.")
    if a.action == "prepare":
        prepare(os.path.abspath(a.recording), a.slug or make_slug(a.recording), os.path.abspath(a.workspace),
                a.whisper, a.tighten)
    elif a.action == "split":
        split(os.path.abspath(a.recording), a.slug or make_slug(a.recording), os.path.abspath(a.workspace),
              a.minutes, a.whisper, a.tighten)
    elif a.action == "join":
        join(a.slug)
    elif a.action == "render":
        if not (a.video and a.keep and a.out):
            fail("render needs --video, --keep and --out.")
        ranges = read_keep(a.keep)
        render_pieces(os.path.abspath(a.video), ranges, os.path.abspath(a.out))
        log(f"RENDERED: {a.out} ({len(ranges)} pieces, {duration(a.out):.1f}s)")
    else:
        out = a.out or os.path.splitext(a.recording)[0] + ".tight.mp4"
        tighten(os.path.abspath(a.recording), os.path.abspath(out), a.whisper)


if __name__ == "__main__":
    main()
'@
$files['repurpose.py'] = @'
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
'@
$files['ytimport.py'] = @'
"""Download your own YouTube videos into the episode folder and add them to the footage index.

  python ytimport.py --url <video, playlist or channel link> --dest <workspace>/episodes --lib <workspace>/library [--max 5]

Only use this for videos you own or have permission to reuse.
"""
import argparse
import os
import shutil
import subprocess

from common import ensure_dir, fail, log


def command(url, dest, limit):
    """The yt-dlp command: best MP4 up to 1080p, skipping anything already downloaded."""
    return ["yt-dlp", "--no-warnings", "--ignore-errors", "--playlist-end", str(limit),
            "-f", "bv*[height<=1080][ext=mp4]+ba[ext=m4a]/b[height<=1080][ext=mp4]/b[height<=1080]/b",
            "--merge-output-format", "mp4", "--restrict-filenames",
            "--download-archive", os.path.join(dest, "downloaded.txt"),
            "-o", os.path.join(dest, "%(upload_date)s-%(title).80s-%(id)s.%(ext)s"), url]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--dest", required=True)
    ap.add_argument("--lib", required=True)
    ap.add_argument("--max", type=int, default=5, dest="limit", help="Most videos to take from a playlist or channel")
    ap.add_argument("--no-index", action="store_true")
    a = ap.parse_args()
    if not a.url.lower().startswith("http"):
        fail("Paste a full YouTube link.")
    if not shutil.which("yt-dlp"):
        fail("yt-dlp is not installed. Re-run Setup-PodcastStudio.ps1.")
    dest = ensure_dir(os.path.abspath(a.dest))
    before = {f for f in os.listdir(dest) if f.lower().endswith(".mp4")}
    log(f"Downloading up to {a.limit} video(s) into {dest} ...")
    subprocess.run(command(a.url, dest, max(1, a.limit)))
    new = sorted({f for f in os.listdir(dest) if f.lower().endswith(".mp4")} - before)
    if not new and not before:
        fail("Nothing was downloaded. Check the link, and that the video is public or unlisted.")
    log(f"{len(new)} new video(s): " + (", ".join(new) if new else "none (already downloaded)"))
    if not a.no_index:
        import library
        library.index(dest, os.path.abspath(a.lib))
    log(f"EPISODES: {dest}")


if __name__ == "__main__":
    main()
'@
$files['captions.py'] = @'
"""Transcribe a video/audio file to .srt and .txt with faster-whisper."""
import argparse
import os

from common import log, transcribe, write_srt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("--out", help="Output base path (no extension)")
    ap.add_argument("--model", default="small", help="tiny/base/small/medium")
    ap.add_argument("--max-words", type=int, default=7)
    a = ap.parse_args()

    base = a.out or os.path.splitext(a.source)[0]
    segs = transcribe(a.source, a.model)
    write_srt(segs, base + ".srt", a.max_words)
    with open(base + ".txt", "w", encoding="utf-8") as f:
        for s, _, t in segs:
            f.write(f"[{int(s // 60):02}:{int(s % 60):02}] {t}\n")
    log(f"Saved {base}.srt and {base}.txt")


if __name__ == "__main__":
    main()
'@
$files['extract_voice.py'] = @'
"""Cut a clean reference voice sample (and its transcript) from a YouTube URL or local file."""
import argparse
import glob
import hashlib
import os

from common import ensure_dir, fail, log, run, transcribe


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", help="YouTube URL or local audio/video file")
    ap.add_argument("--start", default="0", help="Start time (SS, MM:SS or HH:MM:SS)")
    ap.add_argument("--duration", type=float, default=12, help="Seconds (3-20 works best)")
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--name", default="ref")
    a = ap.parse_args()

    out = ensure_dir(a.outdir)
    src = a.source
    if src.lower().startswith("http"):
        cache = ensure_dir(os.path.join(out, "_downloads"))
        key = hashlib.sha1(src.encode()).hexdigest()[:10]
        hits = glob.glob(os.path.join(cache, key + ".*"))
        if hits:
            src = hits[0]
            log(f"Using cached download {src}")
        else:
            run(["yt-dlp", "-f", "bestaudio/best", "-x", "--audio-format", "wav",
                 "-o", os.path.join(cache, key + ".%(ext)s"), a.source])
            hits = glob.glob(os.path.join(cache, key + ".*"))
            if not hits:
                fail("yt-dlp produced no file")
            src = hits[0]
    elif not os.path.exists(src):
        fail(f"File not found: {src}")

    wav = os.path.join(out, a.name + ".wav")
    # 24 kHz mono, light denoise + loudness normalisation for cloning
    run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-ss", a.start, "-t", str(a.duration),
         "-i", src, "-ac", "1", "-ar", "24000",
         "-af", "highpass=f=70,afftdn=nf=-25,loudnorm=I=-18:TP=-2", wav])

    segs = transcribe(wav)
    text = " ".join(t for _, _, t in segs).strip()
    with open(os.path.join(out, a.name + ".txt"), "w", encoding="utf-8") as f:
        f.write(text)
    log(f"Reference audio: {wav}")
    log(f"Reference text : {text}")


if __name__ == "__main__":
    main()
'@
$files['fal_generate.py'] = @'
"""Run any fal.ai model (Wan image-to-video, Wan-Animate, LatentSync lip-sync...) and download the video.

Local files are uploaded automatically. Needs the FAL_KEY environment variable.
"""
import argparse
import json
import os
import urllib.request

from common import fail, log


def find_video_url(obj):
    if isinstance(obj, dict):
        for k in ("video", "output", "result"):
            if k in obj:
                u = find_video_url(obj[k])
                if u:
                    return u
        if isinstance(obj.get("url"), str):
            return obj["url"]
        for v in obj.values():
            u = find_video_url(v)
            if u:
                return u
    elif isinstance(obj, list):
        for v in obj:
            u = find_video_url(v)
            if u:
                return u
    elif isinstance(obj, str) and obj.startswith("http") and obj.split("?")[0].lower().endswith((".mp4", ".webm", ".mov")):
        return obj
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", required=True, help="e.g. fal-ai/latentsync")
    ap.add_argument("--prompt")
    ap.add_argument("--image", help="Reference image (file or URL) -> image_url")
    ap.add_argument("--video", help="Video (file or URL) -> video_url")
    ap.add_argument("--audio", help="Audio (file or URL) -> audio_url")
    ap.add_argument("--extra", default="{}", help="Extra JSON arguments for the model")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    if not os.environ.get("FAL_KEY"):
        fail("FAL_KEY is not set. Use Settings > fal.ai key in the app.")
    import fal_client

    args = {}
    if a.prompt:
        args["prompt"] = a.prompt
    for key, val in (("image_url", a.image), ("video_url", a.video), ("audio_url", a.audio)):
        if not val:
            continue
        if val.startswith("http"):
            args[key] = val
        else:
            if not os.path.exists(val):
                fail(f"File not found: {val}")
            log(f"Uploading {os.path.basename(val)}...")
            args[key] = fal_client.upload_file(val)
    try:
        args.update(json.loads(a.extra or "{}"))
    except json.JSONDecodeError as e:
        fail(f"Extra JSON is invalid: {e}")

    def on_update(update):
        if isinstance(update, fal_client.InProgress):
            for entry in update.logs or []:
                log("  " + str(entry.get("message", entry)))
        else:
            log(f"  status: {type(update).__name__}")

    log(f"Submitting to {a.endpoint} with keys: {', '.join(args)}")
    result = fal_client.subscribe(a.endpoint, arguments=args, with_logs=True, on_queue_update=on_update)

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(os.path.splitext(a.out)[0] + ".json", "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2)
    url = find_video_url(result)
    if not url:
        fail("No video URL in result - see the .json next to the output.")
    log(f"Downloading {url}")
    urllib.request.urlretrieve(url, a.out)
    log(f"Saved clip: {a.out}")


if __name__ == "__main__":
    main()
'@
$files['selftest.py'] = @'
"""Check this PC end to end and write logs/selftest.json.

  python selftest.py --root <PodcastStudio folder>            quick: tools, imports, GPU, render
  python selftest.py --root <...> --full [--voice ref.wav]    also: local LLM, speech-to-text, voice clone, VRAM
"""
import argparse
import importlib
import os
import shutil
import subprocess
import sys
import tempfile
import time

from common import FF, duration, gpu_used_mb, log, read_text, studio_root, whisperx_exe, write_json

results = []


def check(name, fn, required=True):
    t0 = time.time()
    try:
        detail = fn()
        status = "pass"
    except Exception as e:  # noqa: BLE001 - report everything
        detail, status = f"{type(e).__name__}: {e}", ("FAIL" if required else "warn")
    results.append({"check": name, "status": status, "detail": str(detail or ""), "seconds": round(time.time() - t0, 1)})
    log(f"  [{status:4}] {name}: {detail or ''}")
    return status == "pass"


def tool(name):
    def fn():
        path = shutil.which(name)
        if not path:
            raise FileNotFoundError(f"{name} is not on PATH")
        return path
    return fn


def module(name):
    def fn():
        return getattr(importlib.import_module(name), "__version__", "ok")
    return fn


def torch_gpu():
    import torch
    if not torch.cuda.is_available():
        raise RuntimeError(f"torch {torch.__version__} sees no CUDA GPU (voice and stills will be slow on CPU)")
    p = torch.cuda.get_device_properties(0)
    return f"{p.name}, {p.total_memory / 2 ** 30:.1f} GB, torch {torch.__version__}"


def video_encoder():
    from common import encoder
    kind, _ = encoder()
    return ("NVENC: video is encoded on the graphics card's encoder chip, leaving the CPU free" if kind == "nvenc"
            else "CPU (x264). NVENC is not available or not working; set \"encoder\": \"nvenc\" in settings.json to retry")


def face_model():
    import cv2
    import numpy as np
    import visuals
    path = os.path.join(studio_root(), "models", visuals.YUNET)
    if not os.path.exists(path):
        raise FileNotFoundError(f"{path} is missing - re-run the installer")
    finder = visuals._face_finder(320, 180)
    if finder.__name__ != "yunet":
        raise RuntimeError("OpenCV cannot load the face model")
    return f"loaded, {len(finder(np.zeros((180, 320, 3), dtype=np.uint8)))} faces in a blank frame (OpenCV {cv2.__version__})"


def speaker_model():
    import numpy as np
    import speaker
    if not speaker.available():
        raise FileNotFoundError(f"LR-ASD is missing at {speaker.repo_dir()} - re-run the installer")
    t0 = time.time()
    scores = speaker.Detector().scores(np.zeros((50, 112, 112), dtype=np.uint8), np.zeros((200, 13)))
    return f"loaded; scored 2 s of blank video in {time.time() - t0:.1f}s (mean {scores.mean():+.1f}, below 0 = not speaking)"


def ollama_ready(model):
    def fn():
        import llm
        llm.ensure_server()
        have = llm.models()
        missing = [m for m in (model, llm.EMBED_MODEL) if not any(h.split(":")[0] == m.split(":")[0] for h in have)]
        if missing:
            raise RuntimeError(f"missing models: {missing} (have {have}). Run: ollama pull <name>")
        return ", ".join(have)
    return fn


def render_test(tmp):
    def fn():
        import visuals
        clips = []
        for i, text in enumerate(["Podcast Studio self-test", "Render path works"], 1):
            vis = os.path.join(tmp, f"v{i}.mp4")
            wav = os.path.join(tmp, f"a{i}.wav")
            out = os.path.join(tmp, f"s{i}.mp4")
            visuals.card_clip(text, vis, 2.0, "9:16")
            subprocess.run(FF + ["-f", "lavfi", "-i", "sine=f=330:d=2", wav], check=True)
            subprocess.run(FF + ["-i", vis, "-i", wav, "-map", "0:v", "-map", "1:a", "-c:v", "libx264",
                                 "-preset", "veryfast", "-c:a", "aac", "-shortest", out], check=True)
            clips.append(out)
        final = os.path.join(tmp, "final.mp4")
        here = os.path.dirname(os.path.abspath(__file__))
        subprocess.run([sys.executable, os.path.join(here, "assemble.py"), "--clips", *clips,
                        "--format", "9:16", "--out", final], check=True, capture_output=True)
        d = duration(final)
        if not 3.5 < d < 4.6:
            raise RuntimeError(f"expected ~4s, got {d:.2f}s")
        return f"{d:.1f}s 1080x1920 video rendered"
    return fn


def llm_test(model):
    def fn():
        import llm
        before = gpu_used_mb()
        out = llm.chat("Reply with JSON only.", 'Return {"ok": true, "hook": "<a 6 word video hook about coffee>"}',
                       model, as_json=True)
        if "hook" not in out:
            raise RuntimeError(f"unexpected reply: {out}")
        return f"{out['hook']!r} (GPU in use before: {before} MiB)"
    return fn


def voice_test(ref, tmp):
    def fn():
        from tts import Voice
        txt = os.path.splitext(ref)[0] + ".txt"
        ref_text = read_text(txt).strip() if os.path.exists(txt) else None
        v = Voice(ref, ref_text)
        out = os.path.join(tmp, "voice.wav")
        v.speak("This is a short test of the cloned voice.", out)
        return f"{duration(out):.1f}s audio, {v.dtype}, peak VRAM {v.peak_mb()} MiB -> {out}"
    return fn


def whisper_test(wav):
    def fn():
        from common import transcribe
        segs = transcribe(wav)
        return f"heard: {' '.join(t for _, _, t in segs)[:80]!r}; GPU in use after: {gpu_used_mb()} MiB"
    return fn


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--model", default="gemma3:4b")
    ap.add_argument("--full", action="store_true")
    ap.add_argument("--voice", help="Reference WAV for the voice clone test (full mode)")
    a = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="pstudio_test_")
    log("Tools")
    for t in ("ffmpeg", "ffprobe", "ollama"):
        check(t, tool(t))
    for t in ("yt-dlp", "nvidia-smi", "node"):
        check(t, tool(t), required=False)
    log("Python packages")
    for m in ("torch", "faster_whisper", "qwen_tts", "PIL", "soundfile"):
        check(m, module(m))
    for m in ("cv2", "diffusers", "fal_client", "googleapiclient", "google_auth_oauthlib"):
        check(m, module(m), required=False)
    check("GPU", torch_gpu, required=False)
    log("Speed")
    check("video encoder", video_encoder, required=False)
    log("Faces and speakers")
    check("face detector model", face_model)
    check("active-speaker model (LR-ASD)", speaker_model, required=False)
    log("Optional extras")
    check("WhisperX (exact word timing)", lambda: whisperx_exe() or "not installed (built-in word timing is used)", required=False)
    check("MuseTalk (lip-sync)", lambda: "installed" if __import__("lipsync").available() else "not installed (lip-sync is off)",
          required=False)
    log("Local language model")
    check("ollama models", ollama_ready(a.model))
    log("Render")
    check("card + assemble", render_test(tmp))

    if a.full:
        log("Full checks (loads models)")
        check("LLM JSON reply", llm_test(a.model))
        voice = a.voice
        if not voice:
            vdir = os.path.join(a.root, "workspace", "voice")
            wavs = [os.path.join(vdir, f) for f in os.listdir(vdir)] if os.path.isdir(vdir) else []
            voice = next((w for w in wavs if w.lower().endswith(".wav")), None)
        if voice:
            if check("voice clone", voice_test(voice, tmp)):
                check("speech-to-text", whisper_test(os.path.join(tmp, "voice.wav")))
        else:
            results.append({"check": "voice clone", "status": "skip", "detail": "no reference WAV in workspace\\voice yet"})
            log("  [skip] voice clone: make a sample in the Voice clone tab, then re-run")

    failed = [r for r in results if r["status"] == "FAIL"]
    report = os.path.join(a.root, "logs", "selftest.json")
    os.makedirs(os.path.dirname(report), exist_ok=True)
    write_json(report, {"when": time.strftime("%Y-%m-%d %H:%M:%S"), "passed": not failed, "results": results})
    log(f"\n{'SELF-TEST PASSED' if not failed else 'SELF-TEST FAILED: ' + ', '.join(r['check'] for r in failed)}")
    log(f"Report: {report}")
    shutil.rmtree(tmp, ignore_errors=True) if not a.full else log(f"Test files kept in {tmp}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
'@
$files['CLAUDE.md'] = @'
# Podcast Studio workspace

Local pipeline that turns a prompt into a short video in the podcast's style.
Hardware: 4 GB GeForce GPU, 16 GB RAM. The Create flow makes no cloud calls.

## Layout
- `projects/<name>/` - one folder per video: `project.json`, `outline.txt`, `script.json`, `voice/`, `visuals/`, `scenes/`, `captions.ass`, `final.mp4`, `metrics.json`, `qa.json`
- `library/index.json` - searchable transcript index of the episode footage
- `voice/` - reference voice samples (`*.wav` + matching `*.txt` transcript)
- `analysis/` - frames + transcripts from the watch skill and faster-whisper
- `style-bible.md` - the show's distilled style; the outline and script stages read it when present
- `house-rules.md` - lasting corrections. Read it before any script, edit or post and follow every rule. When the user gives a note about an edit, add it here as one short rule.
- `brand.json` - colours, font, logo and optional music bed for cards, captions and the corner logo (a project can hold its own copy)

## Tools (Python = `..\venv\Scripts\python.exe`, scripts in `..\app\`)
- Whole pipeline: `python ..\app\pipeline.py --project projects\x --stage outline --prompt "..."`, edit `outline.txt`, then `--stage all`
- One stage: `--stage script|voice|visuals|render|qa` (add `--force` to redo it)
- Style bible: `python ..\app\stylebible.py --lib library --out style-bible.md`
- Quality gate: `python ..\app\qa.py --project projects\x`
- Prepare a raw recording for the Herk Edit Kit: `python ..\app\recording.py prepare --recording take.mp4 --slug my-take` (kit lives in `..\repos\herk-edit-kit`; edit there with its `short-form-edit` or `edit-video` skill)
- Quick silence trim, no AI: `python ..\app\recording.py tighten --recording take.mp4`
- Social posts from a project: `python ..\app\repurpose.py --project projects\x` (drafts in `projects\x\social`)
- Import your own YouTube videos: `python ..\app\ytimport.py --url <link> --dest episodes --lib library`
- Highlights (clips cut straight from an episode): `python ..\app\highlights.py --lib library --episode <file> --out highlights --count 5 --framing speaker`
- Who is speaking: `python ..\app\speaker.py <video> --start 10 --seconds 8` (LR-ASD, CPU)
- Compare local models and set the default: `python ..\app\modelbench.py --workspace . --save`
- Publish: `python ..\app\publish.py pack --project projects\x`, then `upload` (needs `youtube_client_secret.json` in the workspace)
- Edit one scene: `python ..\app\scenes.py set|remake|add|delete --project projects\x --index N [--fields-file edit.json]`, then `--stage all`
- Index footage: `python ..\app\library.py index <folder> --lib library`
- Voice sample: `python ..\app\extract_voice.py <url|file> --start MM:SS --duration 12 --outdir voice --name host`
- One visual: `python ..\app\visuals.py card "Text" --out clips\c.mp4 --seconds 4`
- Assemble by hand: `python ..\app\assemble.py --clips a.mp4 b.mp4 --voice v.wav --format 9:16 --captions --out output\final.mp4`
- Self-test: `powershell -File ..\app\Test-PodcastStudio.ps1 [-Full] [-NoGui]` (includes the invisible app smoke test: `PodcastStudio.ps1 -SmokeTest`)
- Optional cloud clip (off by default): `python ..\app\fal_generate.py --endpoint <fal id> ...`

## Memory (this PC: 16 GB RAM, 4 GB graphics card)
- Never render cuts with one ffmpeg filter graph of many trim/atrim filters: it ran out of memory on a 10-minute
  1080p test. Use `python ..\app\recording.py render --video in.mp4 --keep keep.json --out out.mp4`
  (keep.json = [[start, end], ...] in seconds); it renders one piece at a time.
- Split recordings longer than about 15 minutes: `recording.py split --recording x.mp4 --slug name --minutes 8`,
  edit each part, then `recording.py join --slug name`.
- Only one GPU model at a time: Ollama is unloaded before the voice model, AI stills or lip-sync start.
- `workspace\settings.json`: `"encoder": "auto|cpu|nvenc"`, `"proxies": true|false`, `"model": "<default model>"`.

## Rules
- Only clone voices of people who have consented.
- Nothing is uploaded anywhere unless `publish.py upload` is run; uploads default to private.
- `script.json` scenes: `narration`, `visual` (soundbite | footage | card | still), `query`, `card_text`, `image_prompt`, `source`.
- A soundbite plays a real episode clip with its own sound (max 2 per video); other scenes use the cloned voice.
- Captions are built from the script and measured timings, not from speech recognition.
- The outline step writes `hooks.json` (three opening lines); the `HOOK:` line in `outline.txt` is the one used.
- New voice lines are listened back to on the CPU and re-made up to twice if garbled (`--voice-check off` to skip).
- Footage framing: `--framing auto|stack|side|wide|single|single-left|single-right|speaker` for the video, or a scene's `layout` to override it. auto = stacked when two hosts are found in a vertical video, else one person.
- `speaker` cuts to whoever is talking (two hosts on screen needed); it falls back to auto if that fails.
- Faces are found with the YuNet model in `..\models`; the footage index stores word-level timing (`words`).
- `--lipsync on` re-syncs a single host's lips to the narration with MuseTalk when it is installed (slow).
- If two faces cannot be found for a two-host framing, typical seat positions (27% and 73% of the width) are assumed.
- Models run one at a time (each stage is its own process) so 4 GB of VRAM is enough.
'@
$binaries = [ordered]@{}
$binaries['models\face_detection_yunet_2023mar.onnx'] = @'
CAYSB3B5dG9yY2gaAzEuNzrzmA4KggEKBWlucHV0CgM0MjAKAzQyMRIDNDE5GgZDb252XzAiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgB
oAECKhUKDGtlcm5lbF9zaGFwZUADQAOgAQcqEQoEcGFkc0ABQAFAAUABoAEHKhAKB3N0cmlkZXNAAkACoAEHChgKAzQxORIDMTg0GgZSZWx1XzEiBFJlbHUK
vAEKAzE4NAoiYmFja2JvbmUubW9kZWwwLmNvbnYyLmNvbnYxLndlaWdodAogYmFja2JvbmUubW9kZWwwLmNvbnYyLmNvbnYxLmJpYXMSAzE4NRoGQ29udl8y
IgRDb252KhIKCWRpbGF0aW9uc0ABQAGgAQcqDAoFZ3JvdXAYAaABAioVCgxrZXJuZWxfc2hhcGVAAUABoAEHKhEKBHBhZHNAAEAAQABAAKABByoQCgdzdHJp
ZGVzQAFAAaABBwqAAQoDMTg1CgM0MjMKAzQyNBIDNDIyGgZDb252XzMiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgQoAECKhUKDGtlcm5l
bF9zaGFwZUADQAOgAQcqEQoEcGFkc0ABQAFAAUABoAEHKhAKB3N0cmlkZXNAAUABoAEHChgKAzQyMhIDMTg4GgZSZWx1XzQiBFJlbHUKbAoDMTg4EgMxODka
CU1heFBvb2xfNSIHTWF4UG9vbCoQCgljZWlsX21vZGUYAKABAioVCgxrZXJuZWxfc2hhcGVAAkACoAEHKhEKBHBhZHNAAEAAQABAAKABByoQCgdzdHJpZGVz
QAJAAqABBwq8AQoDMTg5CiJiYWNrYm9uZS5tb2RlbDEuY29udjEuY29udjEud2VpZ2h0CiBiYWNrYm9uZS5tb2RlbDEuY29udjEuY29udjEuYmlhcxIDMTkw
GgZDb252XzYiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AAQABAAEAAoAEH
KhAKB3N0cmlkZXNAAUABoAEHCoABCgMxOTAKAzQyNgoDNDI3EgM0MjUaBkNvbnZfNyIEQ29udioSCglkaWxhdGlvbnNAAUABoAEHKgwKBWdyb3VwGBCgAQIq
FQoMa2VybmVsX3NoYXBlQANAA6ABByoRCgRwYWRzQAFAAUABQAGgAQcqEAoHc3RyaWRlc0ABQAGgAQcKGAoDNDI1EgMxOTMaBlJlbHVfOCIEUmVsdQq8AQoD
MTkzCiJiYWNrYm9uZS5tb2RlbDEuY29udjIuY29udjEud2VpZ2h0CiBiYWNrYm9uZS5tb2RlbDEuY29udjIuY29udjEuYmlhcxIDMTk0GgZDb252XzkiBENv
bnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNA
AUABoAEHCoEBCgMxOTQKAzQyOQoDNDMwEgM0MjgaB0NvbnZfMTAiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBggoAECKhUKDGtlcm5lbF9z
aGFwZUADQAOgAQcqEQoEcGFkc0ABQAFAAUABoAEHKhAKB3N0cmlkZXNAAUABoAEHChkKAzQyOBIDMTk3GgdSZWx1XzExIgRSZWx1Cr0BCgMxOTcKImJhY2ti
b25lLm1vZGVsMi5jb252MS5jb252MS53ZWlnaHQKIGJhY2tib25lLm1vZGVsMi5jb252MS5jb252MS5iaWFzEgMxOTgaB0NvbnZfMTIiBENvbnYqEgoJZGls
YXRpb25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNAAUABoAEHCoEB
CgMxOTgKAzQzMgoDNDMzEgM0MzEaB0NvbnZfMTMiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBggoAECKhUKDGtlcm5lbF9zaGFwZUADQAOg
AQcqEQoEcGFkc0ABQAFAAUABoAEHKhAKB3N0cmlkZXNAAUABoAEHChkKAzQzMRIDMjAxGgdSZWx1XzE0IgRSZWx1Cr0BCgMyMDEKImJhY2tib25lLm1vZGVs
Mi5jb252Mi5jb252MS53ZWlnaHQKIGJhY2tib25lLm1vZGVsMi5jb252Mi5jb252MS5iaWFzEgMyMDIaB0NvbnZfMTUiBENvbnYqEgoJZGlsYXRpb25zQAFA
AaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNAAUABoAEHCoEBCgMyMDIKAzQz
NQoDNDM2EgM0MzQaB0NvbnZfMTYiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBhAoAECKhUKDGtlcm5lbF9zaGFwZUADQAOgAQcqEQoEcGFk
c0ABQAFAAUABoAEHKhAKB3N0cmlkZXNAAUABoAEHChkKAzQzNBIDMjA1GgdSZWx1XzE3IgRSZWx1Cm0KAzIwNRIDMjA2GgpNYXhQb29sXzE4IgdNYXhQb29s
KhAKCWNlaWxfbW9kZRgAoAECKhUKDGtlcm5lbF9zaGFwZUACQAKgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNAAkACoAEHCr0BCgMyMDYKImJh
Y2tib25lLm1vZGVsMy5jb252MS5jb252MS53ZWlnaHQKIGJhY2tib25lLm1vZGVsMy5jb252MS5jb252MS5iaWFzEgMyMDcaB0NvbnZfMTkiBENvbnYqEgoJ
ZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNAAUABoAEH
CoEBCgMyMDcKAzQzOAoDNDM5EgM0MzcaB0NvbnZfMjAiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBhAoAECKhUKDGtlcm5lbF9zaGFwZUAD
QAOgAQcqEQoEcGFkc0ABQAFAAUABoAEHKhAKB3N0cmlkZXNAAUABoAEHChkKAzQzNxIDMjEwGgdSZWx1XzIxIgRSZWx1Cr0BCgMyMTAKImJhY2tib25lLm1v
ZGVsMy5jb252Mi5jb252MS53ZWlnaHQKIGJhY2tib25lLm1vZGVsMy5jb252Mi5jb252MS5iaWFzEgMyMTEaB0NvbnZfMjIiBENvbnYqEgoJZGlsYXRpb25z
QAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNAAUABoAEHCoEBCgMyMTEK
AzQ0MQoDNDQyEgM0NDAaB0NvbnZfMjMiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBhAoAECKhUKDGtlcm5lbF9zaGFwZUADQAOgAQcqEQoE
cGFkc0ABQAFAAUABoAEHKhAKB3N0cmlkZXNAAUABoAEHChkKAzQ0MBIDMjE0GgdSZWx1XzI0IgRSZWx1Cm0KAzIxNBIDMjE1GgpNYXhQb29sXzI1IgdNYXhQ
b29sKhAKCWNlaWxfbW9kZRgAoAECKhUKDGtlcm5lbF9zaGFwZUACQAKgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNAAkACoAEHCr0BCgMyMTUK
ImJhY2tib25lLm1vZGVsNC5jb252MS5jb252MS53ZWlnaHQKIGJhY2tib25lLm1vZGVsNC5jb252MS5jb252MS5iaWFzEgMyMTYaB0NvbnZfMjYiBENvbnYq
EgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNAAUAB
oAEHCoEBCgMyMTYKAzQ0NAoDNDQ1EgM0NDMaB0NvbnZfMjciBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBhAoAECKhUKDGtlcm5lbF9zaGFw
ZUADQAOgAQcqEQoEcGFkc0ABQAFAAUABoAEHKhAKB3N0cmlkZXNAAUABoAEHChkKAzQ0MxIDMjE5GgdSZWx1XzI4IgRSZWx1Cr0BCgMyMTkKImJhY2tib25l
Lm1vZGVsNC5jb252Mi5jb252MS53ZWlnaHQKIGJhY2tib25lLm1vZGVsNC5jb252Mi5jb252MS5iaWFzEgMyMjAaB0NvbnZfMjkiBENvbnYqEgoJZGlsYXRp
b25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNAAUABoAEHCoEBCgMy
MjAKAzQ0NwoDNDQ4EgM0NDYaB0NvbnZfMzAiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBhAoAECKhUKDGtlcm5lbF9zaGFwZUADQAOgAQcq
EQoEcGFkc0ABQAFAAUABoAEHKhAKB3N0cmlkZXNAAUABoAEHChkKAzQ0NhIDMjIzGgdSZWx1XzMxIgRSZWx1Cm0KAzIyMxIDMjI0GgpNYXhQb29sXzMyIgdN
YXhQb29sKhAKCWNlaWxfbW9kZRgAoAECKhUKDGtlcm5lbF9zaGFwZUACQAKgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNAAkACoAEHCr0BCgMy
MjQKImJhY2tib25lLm1vZGVsNS5jb252MS5jb252MS53ZWlnaHQKIGJhY2tib25lLm1vZGVsNS5jb252MS5jb252MS5iaWFzEgMyMjUaB0NvbnZfMzMiBENv
bnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNA
AUABoAEHCoEBCgMyMjUKAzQ1MAoDNDUxEgM0NDkaB0NvbnZfMzQiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBhAoAECKhUKDGtlcm5lbF9z
aGFwZUADQAOgAQcqEQoEcGFkc0ABQAFAAUABoAEHKhAKB3N0cmlkZXNAAUABoAEHChkKAzQ0ORIDMjI4GgdSZWx1XzM1IgRSZWx1Cr0BCgMyMjgKImJhY2ti
b25lLm1vZGVsNS5jb252Mi5jb252MS53ZWlnaHQKIGJhY2tib25lLm1vZGVsNS5jb252Mi5jb252MS5iaWFzEgMyMjkaB0NvbnZfMzYiBENvbnYqEgoJZGls
YXRpb25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNAAUABoAEHCoEB
CgMyMjkKAzQ1MwoDNDU0EgM0NTIaB0NvbnZfMzciBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBhAoAECKhUKDGtlcm5lbF9zaGFwZUADQAOg
AQcqEQoEcGFkc0ABQAFAAUABoAEHKhAKB3N0cmlkZXNAAUABoAEHChkKAzQ1MhIDMjMyGgdSZWx1XzM4IgRSZWx1CrsBCgMyMzIKIW5lY2subGF0ZXJhbF9j
b252cy4yLmNvbnYxLndlaWdodAofbmVjay5sYXRlcmFsX2NvbnZzLjIuY29udjEuYmlhcxIDMjMzGgdDb252XzM5IgRDb252KhIKCWRpbGF0aW9uc0ABQAGg
AQcqDAoFZ3JvdXAYAaABAioVCgxrZXJuZWxfc2hhcGVAAUABoAEHKhEKBHBhZHNAAEAAQABAAKABByoQCgdzdHJpZGVzQAFAAaABBwqBAQoDMjMzCgM0NTYK
AzQ1NxIDNDU1GgdDb252XzQwIgRDb252KhIKCWRpbGF0aW9uc0ABQAGgAQcqDAoFZ3JvdXAYQKABAioVCgxrZXJuZWxfc2hhcGVAA0ADoAEHKhEKBHBhZHNA
AUABQAFAAaABByoQCgdzdHJpZGVzQAFAAaABBwoZCgM0NTUSAzIzNhoHUmVsdV80MSIEUmVsdQqfAQoDMjM2CgMyNDAKAzQ2NBIDMjQxGglSZXNpemVfNDMi
BlJlc2l6ZSovCh5jb29yZGluYXRlX3RyYW5zZm9ybWF0aW9uX21vZGUiCmFzeW1tZXRyaWOgAQMqFwoNY3ViaWNfY29lZmZfYRUAAEC/oAEBKhIKBG1vZGUi
B25lYXJlc3SgAQMqGAoMbmVhcmVzdF9tb2RlIgVmbG9vcqABAwocCgMyMjMKAzI0MRIDMjQyGgZBZGRfNDQiA0FkZAq7AQoDMjQyCiFuZWNrLmxhdGVyYWxf
Y29udnMuMS5jb252MS53ZWlnaHQKH25lY2subGF0ZXJhbF9jb252cy4xLmNvbnYxLmJpYXMSAzI0MxoHQ29udl80NSIEQ29udioSCglkaWxhdGlvbnNAAUAB
oAEHKgwKBWdyb3VwGAGgAQIqFQoMa2VybmVsX3NoYXBlQAFAAaABByoRCgRwYWRzQABAAEAAQACgAQcqEAoHc3RyaWRlc0ABQAGgAQcKgQEKAzI0MwoDNDU5
CgM0NjASAzQ1OBoHQ29udl80NiIEQ29udioSCglkaWxhdGlvbnNAAUABoAEHKgwKBWdyb3VwGECgAQIqFQoMa2VybmVsX3NoYXBlQANAA6ABByoRCgRwYWRz
QAFAAUABQAGgAQcqEAoHc3RyaWRlc0ABQAGgAQcKGQoDNDU4EgMyNDYaB1JlbHVfNDciBFJlbHUKnwEKAzI0NgoDMjQwCgM0NjUSAzI1MRoJUmVzaXplXzQ5
IgZSZXNpemUqLwoeY29vcmRpbmF0ZV90cmFuc2Zvcm1hdGlvbl9tb2RlIgphc3ltbWV0cmljoAEDKhcKDWN1YmljX2NvZWZmX2EVAABAv6ABASoSCgRtb2Rl
IgduZWFyZXN0oAEDKhgKDG5lYXJlc3RfbW9kZSIFZmxvb3KgAQMKHAoDMjE0CgMyNTESAzI1MhoGQWRkXzUwIgNBZGQKuwEKAzI1MgohbmVjay5sYXRlcmFs
X2NvbnZzLjAuY29udjEud2VpZ2h0Ch9uZWNrLmxhdGVyYWxfY29udnMuMC5jb252MS5iaWFzEgMyNTMaB0NvbnZfNTEiBENvbnYqEgoJZGlsYXRpb25zQAFA
AaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNAAUABoAEHCoEBCgMyNTMKAzQ2
MgoDNDYzEgM0NjEaB0NvbnZfNTIiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBhAoAECKhUKDGtlcm5lbF9zaGFwZUADQAOgAQcqEQoEcGFk
c0ABQAFAAUABoAEHKhAKB3N0cmlkZXNAAUABoAEHChkKAzQ2MRIDMjU2GgdSZWx1XzUzIgRSZWx1CskBCgMyNTYKKGJib3hfaGVhZC5tdWx0aV9sZXZlbF9j
bHMuMC5jb252MS53ZWlnaHQKJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9jbHMuMC5jb252MS5iaWFzEgMyNTcaB0NvbnZfNTQiBENvbnYqEgoJZGlsYXRpb25z
QAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNAAUABoAEHCskBCgMyNTcK
KGJib3hfaGVhZC5tdWx0aV9sZXZlbF9jbHMuMC5jb252Mi53ZWlnaHQKJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9jbHMuMC5jb252Mi5iaWFzEgMyNTgaB0Nv
bnZfNTUiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUADQAOgAQcqEQoEcGFkc0ABQAFAAUABoAEHKhAK
B3N0cmlkZXNAAUABoAEHCskBCgMyNDYKKGJib3hfaGVhZC5tdWx0aV9sZXZlbF9jbHMuMS5jb252MS53ZWlnaHQKJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9j
bHMuMS5jb252MS5iaWFzEgMyNTkaB0NvbnZfNTYiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGg
AQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNAAUABoAEHCskBCgMyNTkKKGJib3hfaGVhZC5tdWx0aV9sZXZlbF9jbHMuMS5jb252Mi53ZWlnaHQK
JmJib3hfaGVhZC5tdWx0aV9sZXZlbF9jbHMuMS5jb252Mi5iaWFzEgMyNjAaB0NvbnZfNTciBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgB
oAECKhUKDGtlcm5lbF9zaGFwZUADQAOgAQcqEQoEcGFkc0ABQAFAAUABoAEHKhAKB3N0cmlkZXNAAUABoAEHCskBCgMyMzYKKGJib3hfaGVhZC5tdWx0aV9s
ZXZlbF9jbHMuMi5jb252MS53ZWlnaHQKJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9jbHMuMi5jb252MS5iaWFzEgMyNjEaB0NvbnZfNTgiBENvbnYqEgoJZGls
YXRpb25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNAAUABoAEHCskB
CgMyNjEKKGJib3hfaGVhZC5tdWx0aV9sZXZlbF9jbHMuMi5jb252Mi53ZWlnaHQKJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9jbHMuMi5jb252Mi5iaWFzEgMy
NjIaB0NvbnZfNTkiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUADQAOgAQcqEQoEcGFkc0ABQAFAAUAB
oAEHKhAKB3N0cmlkZXNAAUABoAEHCssBCgMyNTYKKWJib3hfaGVhZC5tdWx0aV9sZXZlbF9iYm94LjAuY29udjEud2VpZ2h0CidiYm94X2hlYWQubXVsdGlf
bGV2ZWxfYmJveC4wLmNvbnYxLmJpYXMSAzI2MxoHQ29udl82MCIEQ29udioSCglkaWxhdGlvbnNAAUABoAEHKgwKBWdyb3VwGAGgAQIqFQoMa2VybmVsX3No
YXBlQAFAAaABByoRCgRwYWRzQABAAEAAQACgAQcqEAoHc3RyaWRlc0ABQAGgAQcKywEKAzI2MwopYmJveF9oZWFkLm11bHRpX2xldmVsX2Jib3guMC5jb252
Mi53ZWlnaHQKJ2Jib3hfaGVhZC5tdWx0aV9sZXZlbF9iYm94LjAuY29udjIuYmlhcxIDMjY0GgdDb252XzYxIgRDb252KhIKCWRpbGF0aW9uc0ABQAGgAQcq
DAoFZ3JvdXAYBKABAioVCgxrZXJuZWxfc2hhcGVAA0ADoAEHKhEKBHBhZHNAAUABQAFAAaABByoQCgdzdHJpZGVzQAFAAaABBwrLAQoDMjQ2CiliYm94X2hl
YWQubXVsdGlfbGV2ZWxfYmJveC4xLmNvbnYxLndlaWdodAonYmJveF9oZWFkLm11bHRpX2xldmVsX2Jib3guMS5jb252MS5iaWFzEgMyNjUaB0NvbnZfNjIi
BENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlk
ZXNAAUABoAEHCssBCgMyNjUKKWJib3hfaGVhZC5tdWx0aV9sZXZlbF9iYm94LjEuY29udjIud2VpZ2h0CidiYm94X2hlYWQubXVsdGlfbGV2ZWxfYmJveC4x
LmNvbnYyLmJpYXMSAzI2NhoHQ29udl82MyIEQ29udioSCglkaWxhdGlvbnNAAUABoAEHKgwKBWdyb3VwGASgAQIqFQoMa2VybmVsX3NoYXBlQANAA6ABByoR
CgRwYWRzQAFAAUABQAGgAQcqEAoHc3RyaWRlc0ABQAGgAQcKywEKAzIzNgopYmJveF9oZWFkLm11bHRpX2xldmVsX2Jib3guMi5jb252MS53ZWlnaHQKJ2Ji
b3hfaGVhZC5tdWx0aV9sZXZlbF9iYm94LjIuY29udjEuYmlhcxIDMjY3GgdDb252XzY0IgRDb252KhIKCWRpbGF0aW9uc0ABQAGgAQcqDAoFZ3JvdXAYAaAB
AioVCgxrZXJuZWxfc2hhcGVAAUABoAEHKhEKBHBhZHNAAEAAQABAAKABByoQCgdzdHJpZGVzQAFAAaABBwrLAQoDMjY3CiliYm94X2hlYWQubXVsdGlfbGV2
ZWxfYmJveC4yLmNvbnYyLndlaWdodAonYmJveF9oZWFkLm11bHRpX2xldmVsX2Jib3guMi5jb252Mi5iaWFzEgMyNjgaB0NvbnZfNjUiBENvbnYqEgoJZGls
YXRpb25zQAFAAaABByoMCgVncm91cBgEoAECKhUKDGtlcm5lbF9zaGFwZUADQAOgAQcqEQoEcGFkc0ABQAFAAUABoAEHKhAKB3N0cmlkZXNAAUABoAEHCskB
CgMyNTYKKGJib3hfaGVhZC5tdWx0aV9sZXZlbF9vYmouMC5jb252MS53ZWlnaHQKJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9vYmouMC5jb252MS5iaWFzEgMy
NjkaB0NvbnZfNjYiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AAQABAAEAA
oAEHKhAKB3N0cmlkZXNAAUABoAEHCskBCgMyNjkKKGJib3hfaGVhZC5tdWx0aV9sZXZlbF9vYmouMC5jb252Mi53ZWlnaHQKJmJib3hfaGVhZC5tdWx0aV9s
ZXZlbF9vYmouMC5jb252Mi5iaWFzEgMyNzAaB0NvbnZfNjciBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFw
ZUADQAOgAQcqEQoEcGFkc0ABQAFAAUABoAEHKhAKB3N0cmlkZXNAAUABoAEHCskBCgMyNDYKKGJib3hfaGVhZC5tdWx0aV9sZXZlbF9vYmouMS5jb252MS53
ZWlnaHQKJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9vYmouMS5jb252MS5iaWFzEgMyNzEaB0NvbnZfNjgiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVn
cm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNAAUABoAEHCskBCgMyNzEKKGJib3hfaGVhZC5t
dWx0aV9sZXZlbF9vYmouMS5jb252Mi53ZWlnaHQKJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9vYmouMS5jb252Mi5iaWFzEgMyNzIaB0NvbnZfNjkiBENvbnYq
EgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUADQAOgAQcqEQoEcGFkc0ABQAFAAUABoAEHKhAKB3N0cmlkZXNAAUAB
oAEHCskBCgMyMzYKKGJib3hfaGVhZC5tdWx0aV9sZXZlbF9vYmouMi5jb252MS53ZWlnaHQKJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9vYmouMi5jb252MS5i
aWFzEgMyNzMaB0NvbnZfNzAiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AA
QABAAEAAoAEHKhAKB3N0cmlkZXNAAUABoAEHCskBCgMyNzMKKGJib3hfaGVhZC5tdWx0aV9sZXZlbF9vYmouMi5jb252Mi53ZWlnaHQKJmJib3hfaGVhZC5t
dWx0aV9sZXZlbF9vYmouMi5jb252Mi5iaWFzEgMyNzQaB0NvbnZfNzEiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5l
bF9zaGFwZUADQAOgAQcqEQoEcGFkc0ABQAFAAUABoAEHKhAKB3N0cmlkZXNAAUABoAEHCskBCgMyNTYKKGJib3hfaGVhZC5tdWx0aV9sZXZlbF9rcHMuMC5j
b252MS53ZWlnaHQKJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9rcHMuMC5jb252MS5iaWFzEgMyNzUaB0NvbnZfNzIiBENvbnYqEgoJZGlsYXRpb25zQAFAAaAB
ByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNAAUABoAEHCskBCgMyNzUKKGJib3hf
aGVhZC5tdWx0aV9sZXZlbF9rcHMuMC5jb252Mi53ZWlnaHQKJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9rcHMuMC5jb252Mi5iaWFzEgMyNzYaB0NvbnZfNzMi
BENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgKoAECKhUKDGtlcm5lbF9zaGFwZUADQAOgAQcqEQoEcGFkc0ABQAFAAUABoAEHKhAKB3N0cmlk
ZXNAAUABoAEHCskBCgMyNDYKKGJib3hfaGVhZC5tdWx0aV9sZXZlbF9rcHMuMS5jb252MS53ZWlnaHQKJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9rcHMuMS5j
b252MS5iaWFzEgMyNzcaB0NvbnZfNzQiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoE
cGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNAAUABoAEHCskBCgMyNzcKKGJib3hfaGVhZC5tdWx0aV9sZXZlbF9rcHMuMS5jb252Mi53ZWlnaHQKJmJib3hf
aGVhZC5tdWx0aV9sZXZlbF9rcHMuMS5jb252Mi5iaWFzEgMyNzgaB0NvbnZfNzUiBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgKoAECKhUK
DGtlcm5lbF9zaGFwZUADQAOgAQcqEQoEcGFkc0ABQAFAAUABoAEHKhAKB3N0cmlkZXNAAUABoAEHCskBCgMyMzYKKGJib3hfaGVhZC5tdWx0aV9sZXZlbF9r
cHMuMi5jb252MS53ZWlnaHQKJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9rcHMuMi5jb252MS5iaWFzEgMyNzkaB0NvbnZfNzYiBENvbnYqEgoJZGlsYXRpb25z
QAFAAaABByoMCgVncm91cBgBoAECKhUKDGtlcm5lbF9zaGFwZUABQAGgAQcqEQoEcGFkc0AAQABAAEAAoAEHKhAKB3N0cmlkZXNAAUABoAEHCskBCgMyNzkK
KGJib3hfaGVhZC5tdWx0aV9sZXZlbF9rcHMuMi5jb252Mi53ZWlnaHQKJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9rcHMuMi5jb252Mi5iaWFzEgMyODAaB0Nv
bnZfNzciBENvbnYqEgoJZGlsYXRpb25zQAFAAaABByoMCgVncm91cBgKoAECKhUKDGtlcm5lbF9zaGFwZUADQAOgAQcqEQoEcGFkc0ABQAFAAUABoAEHKhAK
B3N0cmlkZXNAAUABoAEHCjYKAzI1OBIDMjgxGgxUcmFuc3Bvc2VfNzgiCVRyYW5zcG9zZSoRCgRwZXJtQABAAkADQAGgAQcKJAoDMjgxCgMyOTASAzI5MRoK
UmVzaGFwZV84NCIHUmVzaGFwZQohCgMyOTESBWNsc184GgpTaWdtb2lkXzg1IgdTaWdtb2lkCjYKAzI2MBIDMjkzGgxUcmFuc3Bvc2VfODYiCVRyYW5zcG9z
ZSoRCgRwZXJtQABAAkADQAGgAQcKJAoDMjkzCgMyOTASAzMwMxoKUmVzaGFwZV85MiIHUmVzaGFwZQoiCgMzMDMSBmNsc18xNhoKU2lnbW9pZF85MyIHU2ln
bW9pZAo2CgMyNjISAzMwNRoMVHJhbnNwb3NlXzk0IglUcmFuc3Bvc2UqEQoEcGVybUAAQAJAA0ABoAEHCiUKAzMwNQoDMjkwEgMzMTUaC1Jlc2hhcGVfMTAw
IgdSZXNoYXBlCiMKAzMxNRIGY2xzXzMyGgtTaWdtb2lkXzEwMSIHU2lnbW9pZAo3CgMyNzASAzMxNxoNVHJhbnNwb3NlXzEwMiIJVHJhbnNwb3NlKhEKBHBl
cm1AAEACQANAAaABBwolCgMzMTcKAzI5MBIDMzI3GgtSZXNoYXBlXzEwOCIHUmVzaGFwZQoiCgMzMjcSBW9ial84GgtTaWdtb2lkXzEwOSIHU2lnbW9pZAo3
CgMyNzISAzMyORoNVHJhbnNwb3NlXzExMCIJVHJhbnNwb3NlKhEKBHBlcm1AAEACQANAAaABBwolCgMzMjkKAzI5MBIDMzM5GgtSZXNoYXBlXzExNiIHUmVz
aGFwZQojCgMzMzkSBm9ial8xNhoLU2lnbW9pZF8xMTciB1NpZ21vaWQKNwoDMjc0EgMzNDEaDVRyYW5zcG9zZV8xMTgiCVRyYW5zcG9zZSoRCgRwZXJtQABA
AkADQAGgAQcKJQoDMzQxCgMyOTASAzM1MRoLUmVzaGFwZV8xMjQiB1Jlc2hhcGUKIwoDMzUxEgZvYmpfMzIaC1NpZ21vaWRfMTI1IgdTaWdtb2lkCjcKAzI2
NBIDMzUzGg1UcmFuc3Bvc2VfMTI2IglUcmFuc3Bvc2UqEQoEcGVybUAAQAJAA0ABoAEHCigKAzM1MwoDMzYyEgZiYm94XzgaC1Jlc2hhcGVfMTMyIgdSZXNo
YXBlCjcKAzI2NhIDMzY0Gg1UcmFuc3Bvc2VfMTMzIglUcmFuc3Bvc2UqEQoEcGVybUAAQAJAA0ABoAEHCikKAzM2NAoDMzYyEgdiYm94XzE2GgtSZXNoYXBl
XzEzOSIHUmVzaGFwZQo3CgMyNjgSAzM3NRoNVHJhbnNwb3NlXzE0MCIJVHJhbnNwb3NlKhEKBHBlcm1AAEACQANAAaABBwopCgMzNzUKAzM2MhIHYmJveF8z
MhoLUmVzaGFwZV8xNDYiB1Jlc2hhcGUKNwoDMjc2EgMzODYaDVRyYW5zcG9zZV8xNDciCVRyYW5zcG9zZSoRCgRwZXJtQABAAkADQAGgAQcKJwoDMzg2CgMz
OTUSBWtwc184GgtSZXNoYXBlXzE1MyIHUmVzaGFwZQo3CgMyNzgSAzM5NxoNVHJhbnNwb3NlXzE1NCIJVHJhbnNwb3NlKhEKBHBlcm1AAEACQANAAaABBwoo
CgMzOTcKAzM5NRIGa3BzXzE2GgtSZXNoYXBlXzE2MCIHUmVzaGFwZQo3CgMyODASAzQwOBoNVHJhbnNwb3NlXzE2MSIJVHJhbnNwb3NlKhEKBHBlcm1AAEAC
QANAAaABBwooCgM0MDgKAzM5NRIGa3BzXzMyGgtSZXNoYXBlXzE2NyIHUmVzaGFwZRIQdG9yY2gtaml0LWV4cG9ydCrSDQgQCAMIAwgDEAFCAzQyMErADS91
nzr87gi6lvR5uiak0jpq5oO6N3TiupJnMjqmJSm6jS4BO+BZHDv4bjO6vmwNuxtWNzsmC6+6Z3hWuxXQ2jqbToC6YHIqOibKDTte5EC6gRQDuzeBIzsdtbC6
anM6uwdg4zq87TS6zqqrOugUWLqKelu6ONQCupLrprmLbG+6yPBbuaCXSLq3CNy6UZoPusWOrrkcGKC5pXE+uU+AXzm9AbW5aNtJOf/OHLo1J8C6+6zuua/r
Tjok1kQ6Ob4qOgLr3DpEKYw6UW20OvJcYDo87/u4nCAuOqXYizn1S3s6HgUcOg+eGTo3wqA6csdWOmt/Hjpky1s61PUUOp34UzmKD0I6C8PYOdpYwTnZn146
jOn8Of8ABzpesho6U1O9Od9mqbotLXy6AiWgujQZp7qjL4S6AjysugX5lLo1fKa6Wx69umlJEDdupd4522VLOsuzGjpnsWe6Ym/vumagpTqujwY6AaVouu9E
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
vZ1gMryGiWK8xzgAPeqDuryZMNE6l5kFvgh0iD7Hs4+74tvKu/A4PLocvEy923bQO7h5fr5ww/W9WaWLPpdSV72nV7m5W4K8PV+cD70Pfx89iNoTveyLkjzF
iZs6yjD2vF5z0j05e+U6MN+ZPF3lfTuhcZI8UVGCPHbUZb+rFoi7V3uSPd+wpLvaFAC8/oDHO082TbwxPBw9/9buvXH3Ob7m6Mc853WbO/TsfrwxY7c86UoJ
vqehlT2CBkK7DhTgPMIlDTxN9uU8hkx2O7hdtjuBQyC+HccxPE4jeb3RWIy7vbQePVJjs7yLHpw9LuJZPiwOW7zdyuc7mVKePinGJj3Eq0Q95wPSPHpPCbwL
Z8A+dE6IPjQc+z2UuOe9EKHuPJEYlj0fsdC84Go/PQ0h3Lu5DWw+By2TPZkFLz0rPdM9FOKOvG/EUr5oWYK7HpYSvktJhT3USca9z5f/vCo/CAQQAUInYmJv
eF9oZWFkLm11bHRpX2xldmVsX2Jib3guMi5jb252Mi5iaWFzShBl4Zw+79aIPoe3qT+nosA/KsgBCAQIAQgDCAMQAUIpYmJveF9oZWFkLm11bHRpX2xldmVs
X2Jib3guMi5jb252Mi53ZWlnaHRKkAG1P609+vo6PthUrz3c7Dk+h8AGP3UPSD7QWYQ9NXDGPrCbtT3+Loa9bSSBvloCDr1LMoG+WZ0Nv1tknb6lP3i9cqqw
vkV2y7wi7Y29vw7QvVIKgr2OFBC+nF+WvqH0PL6axIS903Y7vokJk72kA2k9g+IzPjYN6DyTA+c9f4yePvN/Dz6CjD89OoZaPpZDBz0qMggBEAFCJmJib3hf
aGVhZC5tdWx0aV9sZXZlbF9jbHMuMC5jb252MS5iaWFzSgSjFKc+KrcCCAEIQAgBCAEQAUIoYmJveF9oZWFkLm11bHRpX2xldmVsX2Nscy4wLmNvbnYxLndl
aWdodEqAAiMIijoCuPK8BXx/PUiKlrxxV/I8luALvY5r173dd1G9iFyyPZhaIL57Vjo+NrxCvduTjbzdMiW8RiGMPBqVPb6jOIy+GZfYPWUo6T0IlI48jQJw
vSMrfbx2+4Y9yRZSPnngkj0S9pk9/4MIPit647zGIF8+0ralPfkhjj3XqRi9/ZQSPSwwlL2i3b29FL28PUBxvjtYmqg9oPEhPv9LBD6/Pp496x68PY0kELxV
HYg+yYPcvXe+2j1g/9263yQvvFD+qD3/zre8P2akvEdpSb7D8vG7E8kqvOSLXz3P5cO91L3OPAkqTr2/uly9yJCivRcCFrzF0Wq82EaCvUgqwzwqMggBEAFC
JmJib3hfaGVhZC5tdWx0aV9sZXZlbF9jbHMuMC5jb252Mi5iaWFzSgRsJnI+KloIAQgBCAMIAxABQihiYm94X2hlYWQubXVsdGlfbGV2ZWxfY2xzLjAuY29u
djIud2VpZ2h0SiSGxRc+7lqLPg9bHT7++JY+IdCdPuolgz62x0Q+17OePpQOFj4qMggBEAFCJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9jbHMuMS5jb252MS5i
aWFzSgRqqZ69KrcCCAEIQAgBCAEQAUIoYmJveF9oZWFkLm11bHRpX2xldmVsX2Nscy4xLmNvbnYxLndlaWdodEqAAnMoHD3ywSo96gx2Pfjwhzs7hUi8y5Eh
vMmlIrvF4tA60/p1vbINwTqn3Nc8ZPoAvTQ/IjlvOrO8E00JvcwjGDvB0eg6J+6bvPpJvr0LETs8/aDmPdvmST2pi6299JFpPEMVQzxzTiE76eyJvXqtVDxx
/xM9XqzGvPKb9DxDFx47KuHoORNExDwtn7Y8FlnpPJYCMTxmgCw+rwoPPX4h7T2ZVQA9xg4kPBxVkr5uLYW8dguQPIq1oLx9hYm+3QyKvYA1HL5fTA07bhrB
PHwmej0MW0W8T8vLOzNaOL5E8wu9VGlSvXjpOz4zPBa+AjIkPOz0V7r6T1M8z70avI39mrsqMggBEAFCJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9jbHMuMS5j
b252Mi5iaWFzSgSJ3n89KloIAQgBCAMIAxABQihiYm94X2hlYWQubXVsdGlfbGV2ZWxfY2xzLjEuY29udjIud2VpZ2h0SiS/SX+9/B2qvvP55LyOHqG9EtD+
vlk+hrx+Bek7/l/evaZQKLoqMggBEAFCJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9jbHMuMi5jb252MS5iaWFzSgR68JK+KrcCCAEIQAgBCAEQAUIoYmJveF9o
ZWFkLm11bHRpX2xldmVsX2Nscy4yLmNvbnYxLndlaWdodEqAAi/4ijxrHr+9nGidPB+wj7vfare8OeN6vYtjE72rGrQ+yOezve/BlT0Kt9K91RPHvUy+ML2K
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
/dK+L2kHv8Xhjr7HgGs9TL5OPkoPPj4oPo4+FjYVP0lm1j4fUIU++10xPxC1yz6qZo298S6tvv0hFb3thJ++bD4qv/BP7r5Qo7u+HIAIv760o74qMggBEAFC
JmJib3hfaGVhZC5tdWx0aV9sZXZlbF9vYmouMC5jb252MS5iaWFzSgT6i20/KrcCCAEIQAgBCAEQAUIoYmJveF9oZWFkLm11bHRpX2xldmVsX29iai4wLmNv
bnYxLndlaWdodEqAAqEk575R/UK+67qYvXNHPr4sUam7z8Gwvnre7r0OYSe/QEgLv1icGr6SlQW/Iqpevmiar7zERBK/FoENvfksY766KZq+b5n2Pm1KJb8m
5Bi/Qf8dv6EEiz0N2Jw9nvocv9ztnbzWTZo+ZLAfv6iZ7L71wPC+3suJv+JX6LsG6u++8Brovp+vBL6fsRu+XQs9PY1hZT42Mfc8p+NJv/f/B7889rO+YYWL
v1iW2L4Jzkk/gUX/vlzOl78ch9O9klrHvUHu0L1NFBC/TwiNPp23zjxrTAK/F8mivj+PBL/bi2y+to+Tvr8znr7fv7Y8IegOvyTOCTxy+Ym8TP+bvhjVJb8q
MggBEAFCJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9vYmouMC5jb252Mi5iaWFzSgRdsvS/KloIAQgBCAMIAxABQihiYm94X2hlYWQubXVsdGlfbGV2ZWxfb2Jq
LjAuY29udjIud2VpZ2h0SiTto5m88VvDvGHIsroJdy6+/HlQQNkAR76KlUe9vi8yvp+S7rwqMggBEAFCJmJib3hfaGVhZC5tdWx0aV9sZXZlbF9vYmouMS5j
b252MS5iaWFzSgTcwI85KrcCCAEIQAgBCAEQAUIoYmJveF9oZWFkLm11bHRpX2xldmVsX29iai4xLmNvbnYxLndlaWdodEqAAr8dGb/rWaW+W9HxvQXJ8r0v
Nky/EwwjvuLN0ryPv8K8YLYKPo0qez7/MWS+aACcvo66sLw6kym+DBPuvOc+6r0Ghwi+fXWvvLnzfD5OBXu+9HXUPTGgc759NKy9l8rTvqnbCT7t2Uq9CT5Y
vaTT6bweWTK/ZNdLvllJXb1VSOG9w10IvGE24L5lkaM9wpwovgTQdT0AqCu/OAC5u8UYMr95ZXW/sxyivFLP7T6OmKa+EzG2vuuCmL1D/58+/dWBvspusr6R
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
Ym94XzE2EhMKEQgBEg0KAggBCgMIwAwKAggEYh4KB2Jib3hfMzISEwoRCAESDQoCCAEKAwiQAwoCCARiHAoFa3BzXzgSEwoRCAESDQoCCAEKAwiAMgoCCApi
HQoGa3BzXzE2EhMKEQgBEg0KAggBCgMIwAwKAggKYh0KBmtwc18zMhITChEIARINCgIIAQoDCJADCgIICmofCgM0MTkSGAoWCAESEgoCCAEKAggQCgMIwAIK
AwjAAmofCgMxODQSGAoWCAESEgoCCAEKAggQCgMIwAIKAwjAAmofCgMxODUSGAoWCAESEgoCCAEKAggQCgMIwAIKAwjAAmofCgM0MjISGAoWCAESEgoCCAEK
AggQCgMIwAIKAwjAAmofCgMxODgSGAoWCAESEgoCCAEKAggQCgMIwAIKAwjAAmofCgMxODkSGAoWCAESEgoCCAEKAggQCgMIoAEKAwigAWofCgMxOTASGAoW
CAESEgoCCAEKAggQCgMIoAEKAwigAWofCgM0MjUSGAoWCAESEgoCCAEKAggQCgMIoAEKAwigAWofCgMxOTMSGAoWCAESEgoCCAEKAggQCgMIoAEKAwigAWof
CgMxOTQSGAoWCAESEgoCCAEKAgggCgMIoAEKAwigAWofCgM0MjgSGAoWCAESEgoCCAEKAgggCgMIoAEKAwigAWofCgMxOTcSGAoWCAESEgoCCAEKAgggCgMI
oAEKAwigAWofCgMxOTgSGAoWCAESEgoCCAEKAgggCgMIoAEKAwigAWofCgM0MzESGAoWCAESEgoCCAEKAgggCgMIoAEKAwigAWofCgMyMDESGAoWCAESEgoC
CAEKAgggCgMIoAEKAwigAWofCgMyMDISGAoWCAESEgoCCAEKAghACgMIoAEKAwigAWofCgM0MzQSGAoWCAESEgoCCAEKAghACgMIoAEKAwigAWofCgMyMDUS
GAoWCAESEgoCCAEKAghACgMIoAEKAwigAWodCgMyMDYSFgoUCAESEAoCCAEKAghACgIIUAoCCFBqHQoDMjA3EhYKFAgBEhAKAggBCgIIQAoCCFAKAghQah0K
AzQzNxIWChQIARIQCgIIAQoCCEAKAghQCgIIUGodCgMyMTASFgoUCAESEAoCCAEKAghACgIIUAoCCFBqHQoDMjExEhYKFAgBEhAKAggBCgIIQAoCCFAKAghQ
ah0KAzQ0MBIWChQIARIQCgIIAQoCCEAKAghQCgIIUGodCgMyMTQSFgoUCAESEAoCCAEKAghACgIIUAoCCFBqHQoDMjE1EhYKFAgBEhAKAggBCgIIQAoCCCgK
Aggoah0KAzIxNhIWChQIARIQCgIIAQoCCEAKAggoCgIIKGodCgM0NDMSFgoUCAESEAoCCAEKAghACgIIKAoCCChqHQoDMjE5EhYKFAgBEhAKAggBCgIIQAoC
CCgKAggoah0KAzIyMBIWChQIARIQCgIIAQoCCEAKAggoCgIIKGodCgM0NDYSFgoUCAESEAoCCAEKAghACgIIKAoCCChqHQoDMjIzEhYKFAgBEhAKAggBCgII
QAoCCCgKAggoah0KAzIyNBIWChQIARIQCgIIAQoCCEAKAggUCgIIFGodCgMyMjUSFgoUCAESEAoCCAEKAghACgIIFAoCCBRqHQoDNDQ5EhYKFAgBEhAKAggB
CgIIQAoCCBQKAggUah0KAzIyOBIWChQIARIQCgIIAQoCCEAKAggUCgIIFGodCgMyMjkSFgoUCAESEAoCCAEKAghACgIIFAoCCBRqHQoDNDUyEhYKFAgBEhAK
AggBCgIIQAoCCBQKAggUah0KAzIzMhIWChQIARIQCgIIAQoCCEAKAggUCgIIFGodCgMyMzMSFgoUCAESEAoCCAEKAghACgIIFAoCCBRqHQoDNDU1EhYKFAgB
EhAKAggBCgIIQAoCCBQKAggUah0KAzIzNhIWChQIARIQCgIIAQoCCEAKAggUCgIIFGodCgMyNDESFgoUCAESEAoCCAEKAghACgIIKAoCCChqHQoDMjQyEhYK
FAgBEhAKAggBCgIIQAoCCCgKAggoah0KAzI0MxIWChQIARIQCgIIAQoCCEAKAggoCgIIKGodCgM0NTgSFgoUCAESEAoCCAEKAghACgIIKAoCCChqHQoDMjQ2
EhYKFAgBEhAKAggBCgIIQAoCCCgKAggoah0KAzI1MRIWChQIARIQCgIIAQoCCEAKAghQCgIIUGodCgMyNTISFgoUCAESEAoCCAEKAghACgIIUAoCCFBqHQoD
MjUzEhYKFAgBEhAKAggBCgIIQAoCCFAKAghQah0KAzQ2MRIWChQIARIQCgIIAQoCCEAKAghQCgIIUGodCgMyNTYSFgoUCAESEAoCCAEKAghACgIIUAoCCFBq
HQoDMjU3EhYKFAgBEhAKAggBCgIIAQoCCFAKAghQah0KAzI1OBIWChQIARIQCgIIAQoCCAEKAghQCgIIUGodCgMyNTkSFgoUCAESEAoCCAEKAggBCgIIKAoC
CChqHQoDMjYwEhYKFAgBEhAKAggBCgIIAQoCCCgKAggoah0KAzI2MRIWChQIARIQCgIIAQoCCAEKAggUCgIIFGodCgMyNjISFgoUCAESEAoCCAEKAggBCgII
FAoCCBRqHQoDMjYzEhYKFAgBEhAKAggBCgIIBAoCCFAKAghQah0KAzI2NBIWChQIARIQCgIIAQoCCAQKAghQCgIIUGodCgMyNjUSFgoUCAESEAoCCAEKAggE
CgIIKAoCCChqHQoDMjY2EhYKFAgBEhAKAggBCgIIBAoCCCgKAggoah0KAzI2NxIWChQIARIQCgIIAQoCCAQKAggUCgIIFGodCgMyNjgSFgoUCAESEAoCCAEK
AggECgIIFAoCCBRqHQoDMjY5EhYKFAgBEhAKAggBCgIIAQoCCFAKAghQah0KAzI3MBIWChQIARIQCgIIAQoCCAEKAghQCgIIUGodCgMyNzESFgoUCAESEAoC
CAEKAggBCgIIKAoCCChqHQoDMjcyEhYKFAgBEhAKAggBCgIIAQoCCCgKAggoah0KAzI3MxIWChQIARIQCgIIAQoCCAEKAggUCgIIFGodCgMyNzQSFgoUCAES
EAoCCAEKAggBCgIIFAoCCBRqHQoDMjc1EhYKFAgBEhAKAggBCgIICgoCCFAKAghQah0KAzI3NhIWChQIARIQCgIIAQoCCAoKAghQCgIIUGodCgMyNzcSFgoU
CAESEAoCCAEKAggKCgIIKAoCCChqHQoDMjc4EhYKFAgBEhAKAggBCgIICgoCCCgKAggoah0KAzI3ORIWChQIARIQCgIIAQoCCAoKAggUCgIIFGodCgMyODAS
FgoUCAESEAoCCAEKAggKCgIIFAoCCBRqHQoDMjgxEhYKFAgBEhAKAggBCgIIUAoCCFAKAggBahoKAzI5MRITChEIARINCgIIAQoDCIAyCgIIAWodCgMyOTMS
FgoUCAESEAoCCAEKAggoCgIIKAoCCAFqGgoDMzAzEhMKEQgBEg0KAggBCgMIwAwKAggBah0KAzMwNRIWChQIARIQCgIIAQoCCBQKAggUCgIIAWoaCgMzMTUS
EwoRCAESDQoCCAEKAwiQAwoCCAFqHQoDMzE3EhYKFAgBEhAKAggBCgIIUAoCCFAKAggBahoKAzMyNxITChEIARINCgIIAQoDCIAyCgIIAWodCgMzMjkSFgoU
CAESEAoCCAEKAggoCgIIKAoCCAFqGgoDMzM5EhMKEQgBEg0KAggBCgMIwAwKAggBah0KAzM0MRIWChQIARIQCgIIAQoCCBQKAggUCgIIAWoaCgMzNTESEwoR
CAESDQoCCAEKAwiQAwoCCAFqHQoDMzUzEhYKFAgBEhAKAggBCgIIUAoCCFAKAggEah0KAzM2NBIWChQIARIQCgIIAQoCCCgKAggoCgIIBGodCgMzNzUSFgoU
CAESEAoCCAEKAggUCgIIFAoCCARqHQoDMzg2EhYKFAgBEhAKAggBCgIIUAoCCFAKAggKah0KAzM5NxIWChQIARIQCgIIAQoCCCgKAggoCgIICmodCgM0MDgS
FgoUCAESEAoCCAEKAggUCgIIFAoCCApCBAoAEAs=
'@
foreach ($name in $binaries.Keys) {
    $target = Join-Path $Root $name
    [System.IO.File]::WriteAllBytes($target, [Convert]::FromBase64String(($binaries[$name] -replace '\s', '')))
    Ok $name
}
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
Save-Log
Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$gui`""

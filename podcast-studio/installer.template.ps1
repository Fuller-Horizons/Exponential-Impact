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
           -WithCodex     optional: OpenAI Codex as a second editor (signs in with your ChatGPT plan).
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
    [switch]$WithLipSync,
    [switch]$WithCodex
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

if ($WithCodex) {
    Step 'Codex (optional second editor, uses your ChatGPT plan)'
    if (Has 'npm') {
        if (Native 'npm i -g @openai/codex' { & npm install -g '@openai/codex' --silent } -Soft) {
            Refresh-Path
            Ok 'Codex installed. Run "codex" once and choose "Sign in with ChatGPT".'
        } else { Warn 'Codex did not install. Claude Code stays the editor.' }
    } else { Warn 'npm is missing, so Codex was not installed.' }
}

# ------------------------------------------------------------------ 8. app files
Step 'Writing Podcast Studio app'
$appDir = Join-Path $Root 'app'
$files = [ordered]@{}
#__FILES__
$binaries = [ordered]@{}
#__BINARIES__
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
$guide = Join-Path $appDir 'guide.html'
if (Test-Path $guide) {
    $gl = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Podcast Studio Guide.lnk'))
    $gl.TargetPath = $guide
    $gl.IconLocation = 'shell32.dll,23'
    $gl.Save()
    Ok 'Desktop shortcut: Podcast Studio Guide'
}

# ------------------------------------------------------------------ 10. self-test
Step 'Self-test (syntax, tools, packages, GPU, local model, render)'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $appDir 'Test-PodcastStudio.ps1') -Model $Model
if ($LASTEXITCODE -eq 0) { Ok 'self-test passed' } else { Warn "self-test reported problems - see $Root\logs\selftest.json" }

$mins = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
Write-Host "`nDone in $mins min. Launching Podcast Studio..." -ForegroundColor Green
Write-Host "Next: Voice clone tab > extract a voice sample; Create tab > Index footage, then type a prompt."
Save-Log
Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$gui`""

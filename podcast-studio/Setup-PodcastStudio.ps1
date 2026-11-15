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
           -CheckOnly   (look at this PC and the network, install nothing)
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
    [switch]$CheckOnly
)
# Pinned upstream versions (verified to resolve together for Windows / Python 3.11)
$Pins = @{
    'claude-video' = @{ repo = 'bradautomates/claude-video'; sha = '03ceb42f7fa2c4439aca01752118044baabffb8f' }
    'Qwen3-TTS'    = @{ repo = 'QwenLM/Qwen3-TTS';           sha = '022e286b98fbec7e1e916cb940cdf532cd9f488e' }
}
$PyPins = 'faster-whisper==1.2.1', 'diffusers==0.39.0', 'pillow==13.0.0', 'fal-client==1.0.3',
          'huggingface_hub==0.36.2', 'soundfile==0.14.0', 'numpy==2.2.6', 'opencv-python-headless==4.12.0.88'
$ModelFallbacks = 'gemma3:4b', 'qwen3:4b', 'phi4-mini', 'llama3.2:3b'
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
$t0 = New-Tab 'Create (prompt to video)'
Add-Label $t0 'Project name' 10 12 | Out-Null
$cName = Add-Text $t0 150 12 170 'my-video'
Add-Label $t0 'Length (s)' 335 12 70 | Out-Null
$cSecs = Add-Text $t0 405 12 45 '45'
Add-Label $t0 'Format' 465 12 50 | Out-Null
$cFmt = Add-Combo $t0 515 12 70 @('9:16', '16:9', '1:1')
Add-Label $t0 'Local model' 600 12 80 | Out-Null
$cModel = Add-Combo $t0 685 12 225 @('gemma3:4b', 'qwen3:4b', 'phi4-mini', 'llama3.2:3b') $true
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
        '--soundbites', $(if ($cBites.Checked) { 'on' } else { 'off' }))
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
$cHook.Location = New-Object System.Drawing.Point(150, 218); $cHook.Size = New-Object System.Drawing.Size(520, 24)
$t0.Controls.Add($cHook)
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
              caption_uppercase = $false; font = 'Segoe UI'; logo = ''; logo_position = 'top-right' }
    if (Test-Path $path) {
        try {
            $saved = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
            foreach ($k in @($kit.Keys)) { if ($null -ne $saved.$k -and "$($saved.$k)" -ne '') { $kit[$k] = $saved.$k } }
        } catch { }
    }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Brand kit'; $f.Size = New-Object System.Drawing.Size(520, 400); $f.StartPosition = 'CenterParent'
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
    $ok = Add-Button $f 'Save' 300 310 90; $ok.DialogResult = 'OK'; $f.AcceptButton = $ok
    $cancel = Add-Button $f 'Cancel' 400 310 90; $cancel.DialogResult = 'Cancel'; $f.CancelButton = $cancel
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
    [System.IO.File]::WriteAllText($path, ($out | ConvertTo-Json))
    Log "Brand kit saved: $path (used by the next video you make)"
}

# ================================================================ TAB: Scenes (edit one scene, re-make only what changed)
$tS = New-Tab 'Scenes (edit)'
$script:sceneData = @()
$b = Add-Button $tS 'Load scenes' 10 10 120
$b.Add_Click({ Load-Scenes $false })
$sInfo = Add-Label $tS 'Shows the project named in the Create tab.' 140 10 760
$eList = New-Object System.Windows.Forms.ListBox
$eList.Location = New-Object System.Drawing.Point(10, 45); $eList.Size = New-Object System.Drawing.Size(340, 340)
$eList.HorizontalScrollbar = $true; $eList.Font = New-Object System.Drawing.Font('Consolas', 9)
$tS.Controls.Add($eList)
Add-Label $tS 'Type' 365 45 90 | Out-Null
$eType = Add-Combo $tS 460 45 150 @('card', 'footage', 'soundbite', 'still')
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
    $eNarr.Text = [string]$sc.narration; $eQuery.Text = [string]$sc.query
    $eCard.Text = [string]$sc.card_text; $eImg.Text = [string]$sc.image_prompt
})

$b = Add-Button $tS 'Save scene' 460 295 105
$b.Add_Click({
    $n = Get-SceneNumber; if ($n -eq 0) { return }
    $dir = Get-Project; if (-not $dir) { return }
    $fields = [ordered]@{ narration = $eNarr.Text; visual = [string]$eType.SelectedItem; query = $eQuery.Text
                          card_text = $eCard.Text; image_prompt = $eImg.Text }
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
$nS = Add-Label $tS ('Save scene stores your edit; nothing is rebuilt until you press "Apply changes". Only edited scenes are re-made: changing ' +
    'card text keeps the voice line, changing narration re-records it. "Re-make this scene" gives a new voice take and, for footage or ' +
    'soundbites, the next best matching moment.') 365 378 545
$nS.Size = New-Object System.Drawing.Size(545, 62)

# ================================================================ TAB 1: Analyze
$t1 = New-Tab '1 - Analyze'
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
$b = Add-Button $t1 'Build style bible (local)' 490 140 230
$b.Add_Click({
    if (-not (Test-Path (Join-Path $Work 'library\index.json'))) { Msg 'Index your episodes first (Create tab > Index footage).'; return }
    $script:ctx = @{ out = (Join-Path $Work 'style-bible.md') }
    Run-Py 'Build style bible (local model)' 'stylebible.py' @('--lib', (Join-Path $Work 'library'), '--out', $script:ctx.out, '--model', $cModel.Text) {
        if (Test-Path $script:ctx.out) { Start-Process notepad.exe $script:ctx.out }
    }
})
$note = Add-Label $t1 ("Tips: 'balanced' samples scene changes. For a 45-min episode, analyse 5-10 min windows with Start/End. " +
    "Output lands in workspace\analysis. The style bible is written on this PC from your indexed episodes; the Create tab reads it automatically.") 10 190 900
$note.Size = New-Object System.Drawing.Size(900, 60)

# ================================================================ TAB 2: Voice
$t2 = New-Tab '2 - Voice clone'
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
$t4 = New-Tab '4 - Assemble'
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
$tabs.TabPages.Remove($t3); $t3.Text = '5 - Cloud video (optional, fal.ai)'; $tabs.TabPages.Add($t3)
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
    Expect ($tabs.TabPages.Count -eq 6) "expected 6 tabs, found $($tabs.TabPages.Count)"
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
    foreach ($need in '--project', '--stage', 'outline', '--prompt-file', '--seconds', '--format', '--model', '--stills', '--soundbites') {
        Expect ($argv -contains $need) "missing argument $need"
    }
    Expect (Test-Path (Join-Path $dir 'prompt.txt')) 'prompt.txt was not written'
    $cPrompt.Text = ''
    "$($argv.Count) arguments"
}
Check 'scenes tab loads and selects' {
    $json = '{"title":"Smoke","scenes":[{"narration":"First line.","visual":"card","query":"q1","card_text":"Card one","image_prompt":""},' +
            '{"narration":"","visual":"soundbite","query":"cash flow","card_text":"","image_prompt":""}]}'
    [System.IO.File]::WriteAllText((Join-Path $smokeDir 'script.json'), $json)
    Load-Scenes $true
    Expect ($eList.Items.Count -eq 2) "expected 2 scenes, list shows $($eList.Items.Count)"
    $eList.SelectedIndex = 0
    Expect ($eNarr.Text -eq 'First line.' -and $eCard.Text -eq 'Card one' -and [string]$eType.SelectedItem -eq 'card') 'scene 1 fields not filled in'
    $eList.SelectedIndex = 1
    Expect ([string]$eType.SelectedItem -eq 'soundbite' -and $eQuery.Text -eq 'cash flow') 'scene 2 fields not filled in'
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


def transcribe(path, model_size="small", language=None, device=None):
    """Transcribe with faster-whisper. Tries the GPU first, falls back to CPU int8.

    `device="cpu"` skips the GPU (used while another model is holding the VRAM).
    Returns [(start, end, text)].
    """
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
            segments, info = _whisper[key].transcribe(path, language=language, vad_filter=True)
            return [(s.start, s.end, s.text.strip()) for s in segments]
        except Exception as e:  # missing CUDA DLLs, OOM, etc.
            _whisper.pop(key, None)
            last = e
            log(f"  {dev}/{compute} failed: {e}")
    raise RuntimeError(f"Transcription failed: {last}")


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


def chat(system, user, model=DEFAULT_MODEL, as_json=False, temperature=0.7, num_ctx=8192, schema=None):
    """One chat turn. keep_alive=0 unloads the model afterwards so the GPU is free for the next stage.

    `schema` (a JSON schema dict) makes Ollama constrain the reply to that shape; older Ollama
    versions that reject it fall back to plain JSON mode.
    """
    model = pick_model(model)
    payload = {
        "model": model,
        "stream": False,
        "keep_alive": 0,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "options": {"temperature": temperature, "num_ctx": num_ctx},
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
    """Return a list of embedding vectors (lists of floats)."""
    ensure_server()
    ensure_model(model)
    vectors = []
    for i in range(0, len(texts), batch):
        out = _post("/api/embed", {"model": model, "input": texts[i:i + batch], "keep_alive": 0})
        vectors.extend(out["embeddings"])
    return vectors
'@
$files['library.py'] = @'
"""Footage library: transcribe your episodes once, then find the moment that matches a line of script.

Index:  python library.py index <folder-with-videos> --lib <workspace>/library
Search: python library.py search "topic words" --lib <workspace>/library
"""
import argparse
import math
import os
import re

from common import ensure_dir, fail, log, read_json, transcribe, write_json

VIDEO_EXT = (".mp4", ".mov", ".mkv", ".webm", ".m4v")
WINDOW = 20.0  # seconds of speech per searchable chunk


def _chunks(segs):
    """Group transcript segments into ~20 s chunks: (start, end, text, [segments])."""
    out, cur = [], None
    for start, end, text in segs:
        seg = [round(start, 2), round(end, 2), text]
        if cur is None:
            cur = [start, end, text, [seg]]
        elif end - cur[0] <= WINDOW:
            cur[1], cur[2] = end, cur[2] + " " + text
            cur[3].append(seg)
        else:
            out.append(tuple(cur))
            cur = [start, end, text, [seg]]
    if cur:
        out.append(tuple(cur))
    return out


def pick_soundbite(chunk, query, min_s=4.0, max_s=10.0):
    """Choose a 4-10 s spoken passage inside a chunk. Returns (start, seconds, [(rel_start, rel_end, text)])."""
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
    rel = [(max(0.0, a - start), min(b, end) - start, t) for a, b, t in picked if a < end]
    return start, round(end - start + 0.15, 2), rel


def index(folder, lib, whisper="small", use_embeddings=True):
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
        if data["files"].get(video) == stamp:
            log(f"[{n}/{len(videos)}] already indexed: {os.path.basename(video)}")
            continue
        log(f"[{n}/{len(videos)}] indexing {os.path.basename(video)}")
        data["chunks"] = [c for c in data["chunks"] if c["file"] != video]
        for start, end, text, segs in _chunks(transcribe(video, whisper)):
            data["chunks"].append({"file": video, "start": round(start, 2), "end": round(end, 2),
                                   "text": text, "segs": segs})
        data["files"][video] = stamp
        write_json(path, data)  # save after every file so a long run can resume

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
    s = sub.add_parser("search")
    s.add_argument("query")
    s.add_argument("--lib", required=True)
    a = ap.parse_args()
    if a.cmd == "index":
        index(a.folder, a.lib, a.whisper, not a.no_embeddings)
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

from common import FF, FORMATS, duration, log, run

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


def card_image(text, out_png, fmt="9:16", kicker=None, brand=None):
    """Render a title/quote card as a PNG in the brand colours: gradient, accent bar, centred wrapped text."""
    from PIL import Image, ImageDraw

    import brand as brandkit

    kit = brand or brandkit.load()
    accent, ink, base = brandkit.rgb(kit["accent"]), brandkit.rgb(kit["text"]), brandkit.rgb(kit["background"], (32, 34, 62))
    fonts = brandkit.font_files(kit)
    W, H = FORMATS[fmt]
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

    block_h = line_h * len(lines)
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
    run(FF + ["-i", image, "-vf", vf, "-frames:v", frames, "-c:v", "libx264", "-preset", "veryfast",
              "-crf", "20", "-an", out_mp4])
    return out_mp4


def card_clip(text, out_mp4, seconds, fmt="9:16", kicker=None, brand=None):
    png = os.path.splitext(out_mp4)[0] + ".png"
    card_image(text, png, fmt, kicker, brand)
    return kenburns(png, out_mp4, seconds, fmt, zoom=0.05)


def detect_faces(src, start, seconds, samples=6):
    """Faces in a few sampled frames: [[(centre_x, centre_y, width) as 0-1 fractions, ...] per frame].

    Runs on the CPU with OpenCV's bundled detector. Returns [] if OpenCV is unavailable.
    """
    try:
        import cv2
    except ImportError:
        return []
    cascade = cv2.CascadeClassifier(os.path.join(cv2.data.haarcascades, "haarcascade_frontalface_default.xml"))
    cap = cv2.VideoCapture(src)
    if cascade.empty() or not cap.isOpened():
        return []
    frames = []
    for i in range(samples):
        cap.set(cv2.CAP_PROP_POS_MSEC, (start + seconds * (i + 0.5) / samples) * 1000)
        ok, frame = cap.read()
        if not ok:
            continue
        h, w = frame.shape[:2]
        scale = 640.0 / w if w > 640 else 1.0
        gray = cv2.cvtColor(cv2.resize(frame, (int(w * scale), int(h * scale))), cv2.COLOR_BGR2GRAY)
        found = cascade.detectMultiScale(gray, scaleFactor=1.1, minNeighbors=5,
                                         minSize=(int(gray.shape[0] * 0.08),) * 2)
        gh, gw = gray.shape[:2]
        frames.append([((x + fw / 2) / gw, (y + fh / 2) / gh, fw / gw) for x, y, fw, fh in found])
    cap.release()
    return frames


def _median(values):
    values = sorted(values)
    return values[len(values) // 2]


def plan_layout(frames, vertical=True):
    """Decide how to frame footage from detected faces.

    ("stack", left, right)  two hosts side by side -> one above the other (vertical video only)
    ("single", centre)      one speaker -> crop around them
    ("center",)             no faces found -> plain centre crop
    """
    with_faces = [f for f in frames if f]
    pairs = []
    for f in with_faces:
        if len(f) < 2:
            continue
        a, b = sorted(f, key=lambda face: -face[2])[:2]
        if abs(a[0] - b[0]) >= 0.25 and b[2] >= 0.5 * a[2]:
            pairs.append(sorted((a, b)))
    if vertical and len(pairs) >= 2 and len(pairs) >= 0.6 * len(with_faces):
        left = (_median([p[0][0] for p in pairs]), _median([p[0][1] for p in pairs]))
        right = (_median([p[1][0] for p in pairs]), _median([p[1][1] for p in pairs]))
        return ("stack", left, right)
    if len(with_faces) >= 2:
        biggest = [max(f, key=lambda face: face[2]) for f in with_faces]
        return ("single", (_median([b[0] for b in biggest]), _median([b[1] for b in biggest])))
    return ("center",)


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


def footage_filter(src_w, src_h, W, H, layout):
    """ffmpeg filter graph ([0:v] -> [v]) for a layout from plan_layout."""
    tail = "fps=30,format=yuv420p,setsar=1[v]"
    if layout[0] == "stack":
        half = H // 2
        # zoom so each host's box shows roughly half the width of the original frame
        zoom = max(1.0, (W / (0.55 * src_w)) / max(W / src_w, half / src_h))
        parts = []
        for name, face in (("top", layout[1]), ("bottom", layout[2])):
            sw, sh, x, y = crop_offsets(src_w, src_h, W, half, face, zoom)
            parts.append(f"[{name}0]scale={sw}:{sh},crop={W}:{half}:{x}:{y}[{name}]")
        return "[0:v]split=2[top0][bottom0];" + ";".join(parts) + f";[top][bottom]vstack,{tail}"
    sw, sh, x, y = crop_offsets(src_w, src_h, W, H, layout[1] if layout[0] == "single" else None)
    return f"[0:v]scale={sw}:{sh},crop={W}:{H}:{x}:{y},{tail}"


def footage_clip(src, start, out_mp4, seconds, fmt="9:16", audio=False, layout=None):
    """Cut `seconds` of real footage at `start`, framed around the speaker(s). Muted unless `audio`.

    One face: crop around it. Two hosts in a vertical video: stacked, one above the other.
    """
    from common import video_size

    W, H = FORMATS[fmt]
    total = duration(src)
    start = max(0.0, min(float(start), max(0.0, total - seconds)))
    src_w, src_h = video_size(src)
    if not src_w:
        raise RuntimeError(f"cannot read video size of {src}")
    layout = layout or plan_layout(detect_faces(src, start, seconds), vertical=H > W)
    log(f"  framing: {layout[0]}")
    sound = ["-map", "0:a?", "-c:a", "aac", "-ar", "48000", "-ac", "2"] if audio else ["-an"]
    run(FF + ["-ss", f"{start:.2f}", "-t", f"{seconds:.2f}", "-i", src,
              "-filter_complex", footage_filter(src_w, src_h, W, H, layout), "-map", "[v]", *sound,
              "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", out_mp4])
    if not audio and duration(out_mp4) < seconds - 0.5:  # source too short: freeze the last frame
        padded = out_mp4 + ".pad.mp4"
        run(FF + ["-i", out_mp4, "-vf", f"tpad=stop_mode=clone:stop_duration={seconds}", "-t", f"{seconds:.2f}",
                  "-an", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", padded])
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


def build_ass(words, width, height, path, font="Arial", highlight=HIGHLIGHT, uppercase=False):
    """Write an ASS file where each word changes colour as it is spoken. Returns seconds of caption coverage."""
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
        f"{max(3, size // 11)},0,2,{int(width * 0.06)},{int(width * 0.06)},{margin_v},1\n\n"
        "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n")
    lines, covered = [], 0.0
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
    for p in (os.path.join(project, "style-bible.md"),
              os.path.join(os.path.dirname(os.path.dirname(project)), "style-bible.md")):
        if os.path.exists(p):
            return read_text(p)[:6000]
    return ""


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
                start, secs, segs = pick_soundbite(hit, s["query"])
                s["source"] = {"file": hit["file"], "start": start, "seconds": secs, "segs": segs}
                s["narration"] = ""
            elif hit:
                s["source"] = {"file": hit["file"], "start": hit["start"]}
            elif not s["narration"]:
                continue  # a soundbite with nothing to play and nothing to say
            else:
                s["visual"] = "card"
        out.append(s)
    return out


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
    bible = style_bible(project)
    system = ("You write narration scripts and shot lists for short podcast videos. Reply with JSON only."
              + (f"\n\nSHOW STYLE GUIDE:\n{bible}" if bible else ""))
    base = (f"Turn this outline into a video of about {target:.0f} seconds. Narration is spoken at "
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
    t0, best, feedback = time.time(), None, ""
    for attempt in range(3):
        raw = llm.chat(system, base + feedback, cfg["model"], schema=scene_schema(kinds),
                       temperature=0.6 + 0.1 * attempt)
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

    from tts import Voice
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
        if os.path.exists(out) and not force and abs(duration(out) - secs) < 0.6:
            counts[kind] += 1
            continue
        log(f"[visual {i}/{len(script['scenes'])}] {kind} ({secs:.1f}s)")
        try:
            if kind in ("soundbite", "footage"):
                if not src or not os.path.exists(src["file"]):
                    raise RuntimeError("source footage is missing")
                log(f"  {os.path.basename(src['file'])} @ {src['start']}s")
                s["framing"] = visuals.footage_clip(src["file"], src["start"], out, secs, fmt,
                                                    audio=kind == "soundbite")
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
    enc = ["-r", "30", "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p",
           "-c:a", "aac", "-ar", "48000", "-ac", "2"]
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
            run(FF + ["-i", vis, "-filter_complex", f"[0:v]scale={W}:{H},setsar=1[v];[0:a]{fades}[a]",
                      "-map", "[v]", "-map", "[a]", "-t", f"{secs:.3f}", *enc, out])
        else:
            if not os.path.exists(wav):
                fail(f"Missing {wav} - run the voice stage first.")
            secs = duration(wav)
            fades = f"loudnorm=I=-16:TP=-1.5,afade=t=in:d=0.02,afade=t=out:st={max(0, secs - 0.04):.3f}:d=0.04"
            # hold the last frame if the picture is shorter than the voice line, then cut to the voice
            run(FF + ["-i", vis, "-i", wav, "-filter_complex",
                      f"[0:v]scale={W}:{H},setsar=1,tpad=stop_mode=clone:stop_duration=2[v];[1:a]{fades}[a]",
                      "-map", "[v]", "-map", "[a]", "-t", f"{secs:.3f}", *enc, out])
        real = duration(out)
        if s["visual"] == "soundbite":
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
    if cfg.get("music") and os.path.exists(cfg["music"]):
        cmd += ["--music", cfg["music"]]
    run(cmd)
    got = duration(final)
    ok = abs(got - offset) < 1.5
    record_metric(project, "render", final_seconds=round(got, 2), expected_seconds=round(offset, 2),
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
    ap.add_argument("--stills", choices=["on", "off"])
    ap.add_argument("--captions", choices=["on", "off"])
    ap.add_argument("--soundbites", choices=["on", "off"])
    ap.add_argument("--qa-listen", choices=["on", "off"], dest="qa_listen")
    ap.add_argument("--voice-check", choices=["on", "off"], dest="voice_check")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()

    project = ensure_dir(os.path.abspath(a.project))
    cfg = {"seconds": 45, "format": "9:16", "model": "gemma3:4b", "language": "English",
           "device": "cuda", "stills": False, "captions": True}
    cfg.update(load(project))
    if a.prompt_file:
        cfg["prompt"] = read_text(a.prompt_file).strip()
    for key in ("prompt", "seconds", "format", "model", "voice", "voice_text", "language", "library", "music", "device"):
        if getattr(a, key) is not None:
            cfg[key] = getattr(a, key)
    for key in ("stills", "captions", "soundbites", "qa_listen", "voice_check"):
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

  python scenes.py set    --project P --index 3 --fields-file edit.json
  python scenes.py remake --project P --index 3        (new voice take / next best footage / new still)
  python scenes.py add    --project P --index 3        (insert a card scene after scene 3)
  python scenes.py delete --project P --index 3
Then run pipeline.py --stage all: only the missing pieces are rebuilt.
"""
import argparse
import os

from common import fail, log, read_json, write_json, write_text

KINDS = ("soundbite", "footage", "card", "still")
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
        start, secs, segs = pick_soundbite(hit, s["query"])
        s["source"] = {"file": hit["file"], "start": start, "seconds": secs, "segs": segs}
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
$files['assemble.py'] = @'
"""Stitch clips, lay voiceover + music (ducked under speech), burn captions, normalise loudness, export MP4."""
import argparse
import os
import shutil
import subprocess
import tempfile

from common import FF, FORMATS, duration, fail, log, run, transcribe, write_srt

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
        # 1. normalise every clip (size, fps, audio) so concat is safe
        norm = []
        for i, c in enumerate(a.clips):
            o = os.path.join(tmp, f"n{i:03}.mp4")
            vf = (f"scale={W}:{H}:force_original_aspect_ratio=decrease,"
                  f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:color=black,fps=30,format=yuv420p,setsar=1")
            cmd = FF + ["-i", c]
            if not has_audio(c):
                cmd += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-shortest"]
            cmd += ["-vf", vf, "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
                    "-c:a", "aac", "-ar", "48000", "-ac", "2", o]
            log(f"Normalising {os.path.basename(c)}")
            run(cmd)
            norm.append(o)
        with open(os.path.join(tmp, "list.txt"), "w", encoding="utf-8") as f:
            for n in norm:
                f.write(f"file '{os.path.basename(n)}'\n")
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
            cmd += ["-filter_complex", ";".join(graph), "-map", picture, "-map", "[aout]",
                    "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p"]
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

from common import FF, duration, gpu_used_mb, log, read_text, write_json

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
    for m in ("cv2", "diffusers", "fal_client"):
        check(m, module(m), required=False)
    check("GPU", torch_gpu, required=False)
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
- `brand.json` - colours, font and logo for cards, captions and the corner logo (a project can hold its own copy)

## Tools (Python = `..\venv\Scripts\python.exe`, scripts in `..\app\`)
- Whole pipeline: `python ..\app\pipeline.py --project projects\x --stage outline --prompt "..."`, edit `outline.txt`, then `--stage all`
- One stage: `--stage script|voice|visuals|render|qa` (add `--force` to redo it)
- Style bible: `python ..\app\stylebible.py --lib library --out style-bible.md`
- Quality gate: `python ..\app\qa.py --project projects\x`
- Edit one scene: `python ..\app\scenes.py set|remake|add|delete --project projects\x --index N [--fields-file edit.json]`, then `--stage all`
- Index footage: `python ..\app\library.py index <folder> --lib library`
- Voice sample: `python ..\app\extract_voice.py <url|file> --start MM:SS --duration 12 --outdir voice --name host`
- One visual: `python ..\app\visuals.py card "Text" --out clips\c.mp4 --seconds 4`
- Assemble by hand: `python ..\app\assemble.py --clips a.mp4 b.mp4 --voice v.wav --format 9:16 --captions --out output\final.mp4`
- Self-test: `powershell -File ..\app\Test-PodcastStudio.ps1 [-Full] [-NoGui]` (includes the invisible app smoke test: `PodcastStudio.ps1 -SmokeTest`)
- Optional cloud clip (off by default): `python ..\app\fal_generate.py --endpoint <fal id> ...`

## Rules
- Only clone voices of people who have consented.
- `script.json` scenes: `narration`, `visual` (soundbite | footage | card | still), `query`, `card_text`, `image_prompt`, `source`.
- A soundbite plays a real episode clip with its own sound (max 2 per video); other scenes use the cloned voice.
- Captions are built from the script and measured timings, not from speech recognition.
- The outline step writes `hooks.json` (three opening lines); the `HOOK:` line in `outline.txt` is the one used.
- New voice lines are listened back to on the CPU and re-made up to twice if garbled (`--voice-check off` to skip).
- Footage with two faces side by side is stacked (one host above the other) in vertical videos.
- Models run one at a time (each stage is its own process) so 4 GB of VRAM is enough.
'@
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

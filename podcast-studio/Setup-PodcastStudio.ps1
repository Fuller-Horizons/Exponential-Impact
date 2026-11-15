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
$files['PodcastStudio.ps1'] = @'
# Podcast Studio - local GUI: prompt -> outline -> script -> voice -> visuals -> video (all on this PC)
# Windows PowerShell 5.1+.  Launch:  powershell -ExecutionPolicy Bypass -File PodcastStudio.ps1
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
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
function Msg([string]$t) { [void][System.Windows.Forms.MessageBox]::Show($t, 'Podcast Studio') }
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
    Remove-Item $script:outFile, $script:errFile -ErrorAction SilentlyContinue
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
        '--stills', $(if ($cStills.Checked) { 'on' } else { 'off' }))
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
Add-Label $t0 'Outline (editable)' 10 220 | Out-Null
$cOutline = Add-Text $t0 150 220 760 '' 185
$n0 = Add-Label $t0 'Runs fully on this PC: Ollama writes the outline and script, Qwen3-TTS speaks it, visuals come from your indexed episodes, text cards and optional AI stills. A failed run resumes: press step 2 again.' 150 408 760
$n0.Size = New-Object System.Drawing.Size(760, 34)

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
$b = Add-Button $t1 'Ask Claude: build style bible' 490 140 230
$b.Add_Click({
    $prompt = 'Read everything in analysis/ (frames, transcripts) and CLAUDE.md. Write style-bible.md describing this podcast: hosts, voice and tone, recurring topics, hook patterns, pacing and cut rhythm, caption style, typical short-form length, and 10 example hooks. Then list 5 new short-video ideas in that style.'
    Start-Process powershell.exe -WorkingDirectory $Work -ArgumentList '-NoExit', '-Command', ("claude " + (Q $prompt))
})
$note = Add-Label $t1 ("Tips: 'balanced' samples scene changes. For a 45-min episode, analyse 5-10 min windows with Start/End. " +
    "Output lands in workspace\analysis. The style bible step opens Claude Code in the workspace.") 10 190 900
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
[void]$form.ShowDialog()
'@
$files['Test-PodcastStudio.ps1'] = @'
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


def transcribe(path, model_size="small", language=None, words=False):
    """Transcribe with faster-whisper. Tries the GPU first, falls back to CPU int8.

    Returns [(start, end, text)].
    """
    _expose_torch_cuda_dlls()
    from faster_whisper import WhisperModel

    last = None
    for device, compute in (("cuda", "int8_float16"), ("cuda", "int8"), ("cpu", "int8")):
        try:
            log(f"Transcribing on {device} ({compute}) with whisper-{model_size}...")
            model = WhisperModel(model_size, device=device, compute_type=compute)
            segments, info = model.transcribe(path, language=language, vad_filter=True)
            segs = [(s.start, s.end, s.text.strip()) for s in segments]
            log(f"  language: {info.language}, segments: {len(segs)}, device: {device}")
            return segs
        except Exception as e:  # missing CUDA DLLs, OOM, etc.
            last = e
            log(f"  {device}/{compute} failed: {e}")
    raise RuntimeError(f"Transcription failed: {last}")


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


def chat(system, user, model=DEFAULT_MODEL, as_json=False, temperature=0.7, num_ctx=8192):
    """One chat turn. keep_alive=0 unloads the model afterwards so the GPU is free for the next stage."""
    ensure_server()
    ensure_model(model)
    payload = {
        "model": model,
        "stream": False,
        "keep_alive": 0,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "options": {"temperature": temperature, "num_ctx": num_ctx},
    }
    if as_json:
        payload["format"] = "json"
    try:
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
    out, cur = [], None
    for start, end, text in segs:
        if cur is None:
            cur = [start, end, text]
        elif end - cur[0] <= WINDOW:
            cur[1], cur[2] = end, cur[2] + " " + text
        else:
            out.append(tuple(cur))
            cur = [start, end, text]
    if cur:
        out.append(tuple(cur))
    return out


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
        for start, end, text in _chunks(transcribe(video, whisper)):
            data["chunks"].append({"file": video, "start": round(start, 2), "end": round(end, 2), "text": text})
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


def _font(size):
    from PIL import ImageFont
    for path in FONTS:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def card_image(text, out_png, fmt="9:16", kicker=None, accent=(255, 196, 0)):
    """Render a title/quote card as a PNG: dark gradient, accent bar, centred wrapped text."""
    from PIL import Image, ImageDraw

    W, H = FORMATS[fmt]
    img = Image.new("RGB", (W, H))
    px = img.load()
    for y in range(H):  # vertical gradient
        t = y / H
        row = (int(14 + 18 * t), int(16 + 14 * t), int(28 + 30 * t))
        for x in range(W):
            px[x, y] = row
    draw = ImageDraw.Draw(img)

    text = " ".join(text.split())
    size = int(min(W, H) * (0.10 if len(text) < 40 else 0.075 if len(text) < 90 else 0.058))
    while True:
        font = _font(size)
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
        kf = _font(int(size * 0.45))
        kw = draw.textlength(kicker.upper(), font=kf)
        draw.text(((W - kw) // 2, y - bar_h * 4 - int(size * 0.8)), kicker.upper(), font=kf, fill=accent)
    for line in lines:
        w = draw.textlength(line, font=font)
        draw.text(((W - w) // 2 + 3, y + 3), line, font=font, fill=(0, 0, 0))
        draw.text(((W - w) // 2, y), line, font=font, fill=(255, 255, 255))
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


def card_clip(text, out_mp4, seconds, fmt="9:16", kicker=None):
    png = os.path.splitext(out_mp4)[0] + ".png"
    card_image(text, png, fmt, kicker)
    return kenburns(png, out_mp4, seconds, fmt, zoom=0.05)


def footage_clip(src, start, out_mp4, seconds, fmt="9:16"):
    """Cut `seconds` of real footage from `src` at `start`, cropped to fill the frame, muted."""
    W, H = FORMATS[fmt]
    total = duration(src)
    start = max(0.0, min(float(start), max(0.0, total - seconds)))
    vf = f"scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H},fps=30,format=yuv420p,setsar=1"
    run(FF + ["-ss", f"{start:.2f}", "-t", f"{seconds:.2f}", "-i", src, "-vf", vf, "-an",
              "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", out_mp4])
    if duration(out_mp4) < seconds - 0.5:  # source too short: freeze the last frame
        padded = out_mp4 + ".pad.mp4"
        run(FF + ["-i", out_mp4, "-vf", f"tpad=stop_mode=clone:stop_duration={seconds}", "-t", f"{seconds:.2f}",
                  "-an", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", padded])
        os.replace(padded, out_mp4)
    return out_mp4


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
"""Prompt -> outline -> script + shot list -> voice -> visuals -> finished video. All local.

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

STAGES = ["outline", "script", "voice", "visuals", "render"]
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
def stage_outline(project, cfg, force):
    import llm

    out = os.path.join(project, "outline.txt")
    if os.path.exists(out) and not force:
        log("outline.txt exists - keeping it (use --force to redraft)")
        return
    bible = style_bible(project)
    system = ("You plan short videos for a podcast. Be concrete and punchy. Plain text only, no markdown."
              + (f"\n\nSHOW STYLE GUIDE:\n{bible}" if bible else ""))
    user = (f"Write an outline for a {cfg['seconds']}-second video about:\n{cfg['prompt']}\n\n"
            "Use exactly this layout:\n"
            "TITLE: <max 8 words>\n"
            "HOOK: <the opening line, said in the first 3 seconds>\n"
            "BEATS:\n1. <one line>\n2. <one line>\n(4 to 7 beats)\n"
            "CTA: <closing line>")
    t0 = time.time()
    text = llm.chat(system, user, cfg["model"])
    write_text(out, text.strip() + "\n")
    record_metric(project, "outline", seconds=round(time.time() - t0, 1), model=cfg["model"])
    log(f"Outline saved: {out}\n\n{text}\n")


# ------------------------------------------------------------------ stage: script
def clean_scenes(raw, kinds):
    """Coerce whatever the model returned into a valid scene list."""
    scenes = []
    for s in (raw.get("scenes") or []) if isinstance(raw, dict) else []:
        if not isinstance(s, dict):
            continue
        narration = " ".join(str(s.get("narration", "")).split())
        if not narration:
            continue
        visual = str(s.get("visual", "")).lower().strip()
        if visual not in kinds:
            visual = kinds[0]
        scenes.append({
            "narration": narration,
            "visual": visual,
            "query": str(s.get("query") or narration)[:200],
            "card_text": " ".join(str(s.get("card_text") or "").split())[:120],
            "image_prompt": str(s.get("image_prompt") or s.get("query") or narration)[:300],
        })
    return scenes


def stage_script(project, cfg, force):
    import llm

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

    from library import Library
    kinds = []
    if len(Library(library_dir(cfg, project))):
        kinds.append("footage")
    kinds.append("card")
    if cfg.get("stills"):
        kinds.append("still")
    words = int(cfg["seconds"] * WORDS_PER_SECOND)
    explain = {"footage": '"footage" = a real clip from the podcast; give "query": words to search the episode transcripts',
               "card": '"card" = bold text on screen; give "card_text": max 10 words',
               "still": '"still" = a generated photo; give "image_prompt": a visual description, no text in image'}
    bible = style_bible(project)
    system = ("You write narration scripts and shot lists for short podcast videos. Reply with JSON only."
              + (f"\n\nSHOW STYLE GUIDE:\n{bible}" if bible else ""))
    user = (f"Turn this outline into a narrated video of about {cfg['seconds']} seconds "
            f"(about {words} spoken words in total).\n\nOUTLINE:\n{outline}\n\n"
            "Return JSON: {\"title\": str, \"scenes\": [{\"narration\": str, \"visual\": str, "
            "\"query\": str, \"card_text\": str, \"image_prompt\": str}]}\n"
            "Rules:\n- One scene per sentence or two of narration (6 to 12 scenes).\n"
            "- The first scene is the hook. The last scene is the call to action.\n"
            "- Narration is spoken aloud: no emojis, no stage directions, no hashtags.\n"
            "- \"visual\" must be one of: " + ", ".join(kinds) + ".\n"
            + "\n".join("- " + explain[k] for k in kinds) + "\n- Vary the visuals.")
    t0 = time.time()
    scenes, raw = [], {}
    for attempt in range(3):
        raw = llm.chat(system, user, cfg["model"], as_json=True, temperature=0.6 + 0.1 * attempt)
        scenes = clean_scenes(raw, kinds)
        if len(scenes) >= 3:
            break
        log(f"  attempt {attempt + 1}: unusable script, retrying")
    if len(scenes) < 3:
        fail("The local model did not produce a usable script. Try another model in the Create tab.")
    title = str(raw.get("title") or outline.splitlines()[0].replace("TITLE:", "").strip())[:80]
    write_json(out, {"title": title, "outline_sha1": digest, "scenes": scenes})
    write_text(os.path.join(project, "script.txt"), "\n\n".join(s["narration"] for s in scenes) + "\n")
    total = sum(len(s["narration"].split()) for s in scenes)
    record_metric(project, "script", seconds=round(time.time() - t0, 1), scenes=len(scenes), words=total)
    log(f"Script saved: {len(scenes)} scenes, {total} words (~{total / WORDS_PER_SECOND:.0f}s)")


# ------------------------------------------------------------------ stage: voice
def stage_voice(project, cfg, force):
    script = read_json(os.path.join(project, "script.json"))
    if not script:
        fail("No script.json - run the script stage first.")
    vdir = ensure_dir(os.path.join(project, "voice"))
    todo = []
    for i, s in enumerate(script["scenes"], 1):
        wav = os.path.join(vdir, f"scene_{i:02}.wav")
        if force or not os.path.exists(wav) or duration(wav) < 0.2:
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
    record_metric(project, "voice", seconds=round(time.time() - t0, 1), torch_peak_mb=voice.peak_mb(),
                  gpu_used_before_mb=before, gpu_used_after_mb=gpu_used_mb(), dtype=str(voice.dtype))
    log(f"Voice done. Peak VRAM (torch): {voice.peak_mb()} MiB")


# ------------------------------------------------------------------ stage: visuals
def stage_visuals(project, cfg, force):
    import visuals
    from library import Library

    script = read_json(os.path.join(project, "script.json"))
    if not script:
        fail("No script.json - run the script stage first.")
    fmt = cfg["format"]
    vdir = ensure_dir(os.path.join(project, "visuals"))
    lib = Library(library_dir(cfg, project))
    stills, t0 = None, time.time()
    counts = {"footage": 0, "card": 0, "still": 0}
    for i, s in enumerate(script["scenes"], 1):
        out = os.path.join(vdir, f"scene_{i:02}.mp4")
        wav = os.path.join(project, "voice", f"scene_{i:02}.wav")
        if not os.path.exists(wav):
            fail(f"Missing voice line {wav} - run the voice stage first.")
        secs = duration(wav) + 0.05
        if os.path.exists(out) and not force and abs(duration(out) - secs) < 0.6:
            continue
        kind = s["visual"]
        log(f"[visual {i}/{len(script['scenes'])}] {kind} ({secs:.1f}s)")
        try:
            if kind == "footage":
                hit = lib.search(s["query"])
                if not hit:
                    raise RuntimeError("no matching footage")
                log(f"  {os.path.basename(hit['file'])} @ {hit['start']}s (score {hit['score']})")
                visuals.footage_clip(hit["file"], hit["start"], out, secs, fmt)
                s["source"] = {"file": hit["file"], "start": hit["start"]}
            elif kind == "still":
                stills = stills or visuals.StillMaker()
                png = os.path.splitext(out)[0] + ".png"
                stills.make(s["image_prompt"], png, fmt)
                visuals.kenburns(png, out, secs, fmt)
            else:
                raise LookupError
        except Exception as e:
            if not isinstance(e, LookupError):
                log(f"  {kind} failed ({e}) - using a text card instead")
            kind = "card"
            text = s["card_text"] or " ".join(s["narration"].split()[:10])
            visuals.card_clip(text, out, secs, fmt, kicker=script.get("title") if i == 1 else None)
        counts[kind] += 1
    write_json(os.path.join(project, "script.json"), script)
    record_metric(project, "visuals", seconds=round(time.time() - t0, 1), gpu_used_after_mb=gpu_used_mb(),
                  torch_peak_mb=stills.peak_mb() if stills else 0, **counts)
    log(f"Visuals done: {counts}")


# ------------------------------------------------------------------ stage: render
def stage_render(project, cfg, force):
    script = read_json(os.path.join(project, "script.json"))
    if not script:
        fail("No script.json.")
    sdir = ensure_dir(os.path.join(project, "scenes"))
    W, H = FORMATS[cfg["format"]]
    clips, expected = [], 0.0
    for i in range(1, len(script["scenes"]) + 1):
        vis = os.path.join(project, "visuals", f"scene_{i:02}.mp4")
        wav = os.path.join(project, "voice", f"scene_{i:02}.wav")
        for p in (vis, wav):
            if not os.path.exists(p):
                fail(f"Missing {p} - run earlier stages first.")
        out = os.path.join(sdir, f"scene_{i:02}.mp4")
        secs = duration(wav)
        expected += secs
        # hold the last frame if the picture is shorter than the voice line, then cut to the voice
        run(FF + ["-i", vis, "-i", wav, "-filter_complex",
                  f"[0:v]scale={W}:{H},setsar=1,tpad=stop_mode=clone:stop_duration=2[v]",
                  "-map", "[v]", "-map", "1:a", "-t", f"{secs:.3f}", "-r", "30",
                  "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p",
                  "-c:a", "aac", "-ar", "48000", "-ac", "2", out])
        clips.append(out)

    final = os.path.join(project, "final.mp4")
    cmd = [sys.executable, "-u", os.path.join(os.path.dirname(os.path.abspath(__file__)), "assemble.py"),
           "--clips", *clips, "--format", cfg["format"], "--out", final]
    if cfg.get("captions", True):
        cmd.append("--captions")
    if cfg.get("music") and os.path.exists(cfg["music"]):
        cmd += ["--music", cfg["music"]]
    run(cmd)
    got = duration(final)
    ok = abs(got - expected) < 1.5
    record_metric(project, "render", final_seconds=round(got, 2), expected_seconds=round(expected, 2), duration_ok=ok)
    log(f"{'OK' if ok else 'WARNING: length mismatch'} - final video {got:.1f}s (voice total {expected:.1f}s)")
    log(f"FINAL: {final}")


RUN = {"outline": stage_outline, "script": stage_script, "voice": stage_voice,
       "visuals": stage_visuals, "render": stage_render}


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
    for key in ("stills", "captions"):
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
$files['assemble.py'] = @'
"""Stitch clips, lay voiceover + music, burn captions, export MP4 (CPU / ffmpeg only)."""
import argparse
import os
import shutil
import subprocess
import tempfile

from common import FORMATS, duration, fail, log, run, transcribe, write_srt


def has_audio(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries",
                          "stream=index", "-of", "csv=p=0", path], capture_output=True, text=True)
    return bool(out.stdout.strip())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clips", nargs="+", required=True)
    ap.add_argument("--voice", help="Voiceover WAV; replaces clip audio")
    ap.add_argument("--music", help="Background music")
    ap.add_argument("--music-volume", type=float, default=0.12)
    ap.add_argument("--format", default="9:16", choices=list(FORMATS))
    ap.add_argument("--captions", action="store_true")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    for c in a.clips:
        if not os.path.exists(c):
            fail(f"Missing clip: {c}")
    W, H = FORMATS[a.format]
    tmp = tempfile.mkdtemp(prefix="pstudio_")
    try:
        # 1. normalise every clip (size, fps, audio) so concat is safe
        norm = []
        for i, c in enumerate(a.clips):
            o = os.path.join(tmp, f"n{i:03}.mp4")
            vf = (f"scale={W}:{H}:force_original_aspect_ratio=decrease,"
                  f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:color=black,fps=30,format=yuv420p,setsar=1")
            cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", c]
            if not has_audio(c):
                cmd += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-shortest"]
            cmd += ["-vf", vf, "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                    "-c:a", "aac", "-ar", "48000", "-ac", "2", o]
            log(f"Normalising {os.path.basename(c)}")
            run(cmd)
            norm.append(o)

        lst = os.path.join(tmp, "list.txt")
        with open(lst, "w", encoding="utf-8") as f:
            for n in norm:
                f.write(f"file '{n.replace(os.sep, '/')}'\n")
        joined = os.path.join(tmp, "joined.mp4")
        run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "concat", "-safe", "0",
             "-i", lst, "-c", "copy", joined])

        # 2. audio: voiceover (looping video if voice is longer) + optional music bed
        stage = joined
        if a.voice or a.music:
            mixed = os.path.join(tmp, "mixed.mp4")
            cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error"]
            if a.voice and duration(a.voice) > duration(joined):
                cmd += ["-stream_loop", "-1"]
            cmd += ["-i", joined]
            filt, maps, n = [], [], 1
            base = "[0:a]"
            if a.voice:
                cmd += ["-i", a.voice]
                base = f"[{n}:a]"
                n += 1
            if a.music:
                cmd += ["-stream_loop", "-1", "-i", a.music]
                filt.append(f"[{n}:a]volume={a.music_volume}[m]")
                filt.append(f"{base}[m]amix=inputs=2:duration=first:dropout_transition=0[aout]")
                maps = ["-map", "0:v", "-map", "[aout]"]
            else:
                maps = ["-map", "0:v", "-map", base.strip("[]")]
            if filt:
                cmd += ["-filter_complex", ";".join(filt)]
            cmd += maps + ["-c:v", "copy", "-c:a", "aac"]
            if a.voice:
                cmd += ["-shortest"]
            run(cmd + [mixed])
            stage = mixed

        # 3. captions burned in (run ffmpeg from tmp so the subtitles path needs no escaping)
        if a.captions:
            segs = transcribe(a.voice or stage)
            write_srt(segs, os.path.join(tmp, "subs.srt"))
            shutil.copy(os.path.join(tmp, "subs.srt"), os.path.splitext(a.out)[0] + ".srt")
            # libass lays SRT out on a 288-line canvas, so size and margin are in those units
            size = 16 if H > W else 12
            style = (f"FontName=Arial,FontSize={size},Bold=1,PrimaryColour=&H00FFFFFF,"
                     f"OutlineColour=&H00000000,Outline=3,Shadow=0,Alignment=2,MarginV={28 if H > W else 20}")
            capt = os.path.join(tmp, "capt.mp4")
            run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", os.path.basename(stage),
                 "-vf", f"subtitles=subs.srt:force_style='{style}'", "-c:v", "libx264",
                 "-preset", "veryfast", "-crf", "20", "-c:a", "copy", "capt.mp4"], cwd=tmp)
            stage = capt

        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        shutil.copy(stage, a.out)
        log(f"Rendered: {a.out}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


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
    for m in ("diffusers", "fal_client"):
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
- `projects/<name>/` - one folder per video: `project.json`, `outline.txt`, `script.json`, `voice/`, `visuals/`, `scenes/`, `final.mp4`, `metrics.json`
- `library/index.json` - searchable transcript index of the episode footage
- `voice/` - reference voice samples (`*.wav` + matching `*.txt` transcript)
- `analysis/` - frames + transcripts from the watch skill and faster-whisper
- `style-bible.md` - the show's distilled style; the outline and script stages read it when present

## Tools (Python = `..\venv\Scripts\python.exe`, scripts in `..\app\`)
- Whole pipeline: `python ..\app\pipeline.py --project projects\x --stage outline --prompt "..."`, edit `outline.txt`, then `--stage all`
- One stage: `--stage script|voice|visuals|render` (add `--force` to redo it)
- Index footage: `python ..\app\library.py index <folder> --lib library`
- Voice sample: `python ..\app\extract_voice.py <url|file> --start MM:SS --duration 12 --outdir voice --name host`
- One visual: `python ..\app\visuals.py card "Text" --out clips\c.mp4 --seconds 4`
- Assemble by hand: `python ..\app\assemble.py --clips a.mp4 b.mp4 --voice v.wav --format 9:16 --captions --out output\final.mp4`
- Self-test: `powershell -File ..\app\Test-PodcastStudio.ps1 [-Full]`
- Optional cloud clip (off by default): `python ..\app\fal_generate.py --endpoint <fal id> ...`

## Rules
- Only clone voices of people who have consented.
- `script.json` scenes: `narration`, `visual` (footage | card | still), `query`, `card_text`, `image_prompt`.
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
Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$gui`""

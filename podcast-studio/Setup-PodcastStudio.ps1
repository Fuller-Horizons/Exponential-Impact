<#
  Podcast Studio - one-shot installer for Windows 10/11 (4 GB NVIDIA GPU, 16 GB RAM)

  Installs:  Git, Python 3.11, Node.js LTS, FFmpeg, yt-dlp, Deno (winget), Claude Code,
             PyTorch (CUDA 12.4), Qwen3-TTS 0.6B voice cloning, faster-whisper, fal.ai client,
             claude-video "watch" skill, HyperFrames CLI + Claude Code plugins.
  Creates :  <Root>\app\PodcastStudio.ps1 (GUI), <Root>\workspace, desktop shortcut.

  Run (normal PowerShell window, not admin):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-PodcastStudio.ps1
  Options: -Root D:\PodcastStudio   -SkipModels   -SkipClaude   -CpuOnly
  Safe to re-run: it updates what is already installed.
#>
param(
    [string]$Root = (Join-Path $env:USERPROFILE 'PodcastStudio'),
    [switch]$SkipModels,
    [switch]$SkipClaude,
    [switch]$CpuOnly
)
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
                (Join-Path $env:USERPROFILE '.local\bin')
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
$pkgs = 'Git.Git', 'Python.Python.3.11', 'OpenJS.NodeJS.LTS', 'Gyan.FFmpeg', 'yt-dlp.yt-dlp', 'DenoLand.Deno'
foreach ($id in $pkgs) {
    Write-Host "    $id ..."
    & winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
    # already-installed returns non-zero: try an upgrade, ignore "no update"
    if ($LASTEXITCODE -ne 0) { & winget upgrade --id $id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null }
}
Refresh-Path
foreach ($c in 'git', 'node', 'ffmpeg', 'yt-dlp', 'deno') {
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
foreach ($d in 'repos', 'app', 'logs', 'workspace\analysis', 'workspace\voice', 'workspace\scripts', 'workspace\clips', 'workspace\output', 'workspace\frames') {
    New-Item -ItemType Directory -Force -Path (Join-Path $Root $d) | Out-Null
}
$repos = @{ 'claude-video' = 'bradautomates/claude-video'; 'Qwen3-TTS' = 'QwenLM/Qwen3-TTS' }
foreach ($name in $repos.Keys) {
    $dir = Join-Path $Root "repos\$name"
    if (Test-Path (Join-Path $dir '.git')) {
        Native "git pull $name" { & git -C $dir pull --ff-only --quiet } -Soft | Out-Null
    } else {
        Native "git clone $name" { & git clone --depth 1 --quiet "https://github.com/$($repos[$name])" $dir } | Out-Null
    }
    Ok $name
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
Native 'qwen-tts' { & $py -m pip install --quiet -e (Join-Path $Root 'repos\Qwen3-TTS') } | Out-Null
Native 'tools' { & $py -m pip install --quiet faster-whisper fal-client 'huggingface_hub[cli]' soundfile numpy } | Out-Null
& $py -c "import torch; ok=torch.cuda.is_available(); print('    torch', torch.__version__, '| CUDA:', ok, '|', torch.cuda.get_device_name(0) if ok else 'cpu only')"

# ------------------------------------------------------------------ 6. model weights
if (-not $SkipModels) {
    Step 'Downloading models (Qwen3-TTS 0.6B Base + tokenizer, whisper-small)'
    Native 'model download' {
        & $py -c "from huggingface_hub import snapshot_download as d; [print('    ', d(r)) for r in ('Qwen/Qwen3-TTS-12Hz-0.6B-Base', 'Qwen/Qwen3-TTS-Tokenizer-12Hz')]; from faster_whisper import WhisperModel; WhisperModel('small', device='cpu', compute_type='int8'); print('     whisper-small ready')"
    } -Soft | Out-Null
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
# Podcast Studio - local GUI for: analyze -> clone voice -> cloud clips (fal.ai) -> assemble
# Windows PowerShell 5.1+.  Launch:  powershell -ExecutionPolicy Bypass -File PodcastStudio.ps1
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Root   = Split-Path $PSScriptRoot -Parent
$App    = $PSScriptRoot
$Py     = Join-Path $Root 'venv\Scripts\python.exe'
$Work   = Join-Path $Root 'workspace'
$Watch  = Join-Path $Root 'repos\claude-video\skills\watch\scripts\watch.py'
$LogDir = Join-Path $Root 'logs'
foreach ($d in 'analysis','voice','scripts','clips','output','frames') { New-Item -ItemType Directory -Force -Path (Join-Path $Work $d) | Out-Null }
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

# ---------------------------------------------------------------- startup checks
$form.Add_Shown({
    Log "Podcast Studio  |  root: $Root"
    foreach ($tool in 'ffmpeg', 'yt-dlp', 'node', 'claude') {
        if (Get-Command $tool -ErrorAction SilentlyContinue) { Log "  [ok] $tool" } else { Log "  [missing] $tool - re-run setup" }
    }
    if (Test-Path $Py) { Log '  [ok] python venv' } else { Log '  [missing] python venv - re-run setup' }
    if ($env:FAL_KEY) { Log '  [ok] fal.ai key' } else { Log '  [info] no fal.ai key yet (tab 3 > Set fal.ai key)' }
})
$form.Add_FormClosing({ if ($script:proc -and -not $script:proc.HasExited) { & taskkill.exe /PID $script:proc.Id /T /F | Out-Null } })
[void]$form.ShowDialog()
'@
$files['common.py'] = @'
"""Shared helpers for Podcast Studio scripts."""
import os
import subprocess
import sys


def log(msg):
    print(msg, flush=True)


def run(cmd, **kw):
    log("> " + " ".join(str(c) for c in cmd))
    subprocess.run([str(c) for c in cmd], check=True, **kw)


def transcribe(path, model_size="small", language=None):
    """Transcribe with faster-whisper. Tries the GPU first, falls back to CPU int8."""
    from faster_whisper import WhisperModel

    attempts = [("cuda", "int8_float16"), ("cpu", "int8")]
    last = None
    for device, compute in attempts:
        try:
            log(f"Transcribing on {device} ({compute}) with whisper-{model_size}...")
            model = WhisperModel(model_size, device=device, compute_type=compute)
            segments, info = model.transcribe(path, language=language, vad_filter=True)
            segs = [(s.start, s.end, s.text.strip()) for s in segments]
            log(f"Detected language: {info.language}")
            return segs
        except Exception as e:  # missing CUDA DLLs, OOM, etc.
            last = e
            log(f"  {device} failed: {e}")
    raise RuntimeError(f"Transcription failed: {last}")


def srt_time(t):
    h, rem = divmod(t, 3600)
    m, s = divmod(rem, 60)
    ms = int(round((s - int(s)) * 1000))
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


def ensure_dir(p):
    os.makedirs(p, exist_ok=True)
    return p


def fail(msg):
    log("ERROR: " + msg)
    sys.exit(1)
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
$files['tts.py'] = @'
"""Voice-cloned narration with Qwen3-TTS 0.6B (fits a 4 GB GPU in fp16)."""
import argparse
import os
import re

import numpy as np

from common import fail, log


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", required=True, help="Text file with the narration")
    ap.add_argument("--ref-audio", required=True)
    ap.add_argument("--ref-text", help="Text file with the reference transcript (better quality)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--language", default="English")
    ap.add_argument("--model", default="Qwen/Qwen3-TTS-12Hz-0.6B-Base")
    ap.add_argument("--device", default="cuda", choices=["cuda", "cpu"])
    ap.add_argument("--pause", type=float, default=0.25, help="Seconds of silence between chunks")
    a = ap.parse_args()

    import soundfile as sf
    import torch
    from qwen_tts import Qwen3TTSModel

    with open(a.script, encoding="utf-8") as f:
        text = f.read().strip()
    if not text:
        fail("Script is empty")
    ref_text = None
    if a.ref_text and os.path.exists(a.ref_text):
        with open(a.ref_text, encoding="utf-8") as f:
            ref_text = f.read().strip() or None

    device = a.device
    if device == "cuda" and not torch.cuda.is_available():
        log("CUDA not available - falling back to CPU (slow).")
        device = "cpu"
    dtype = torch.float16 if device == "cuda" else torch.float32
    log(f"Loading {a.model} on {device} ({dtype})...")
    model = Qwen3TTSModel.from_pretrained(
        a.model, device_map="cuda:0" if device == "cuda" else "cpu", dtype=dtype)

    prompt = model.create_voice_clone_prompt(
        ref_audio=a.ref_audio, ref_text=ref_text, x_vector_only_mode=ref_text is None)

    chunks = chunk_text(text)
    pieces, sr = [], None
    for i, chunk in enumerate(chunks, 1):
        log(f"[{i}/{len(chunks)}] {chunk[:70]}...")
        wavs, sr = model.generate_voice_clone(text=chunk, language=a.language,
                                              voice_clone_prompt=prompt)
        pieces.append(np.asarray(wavs[0], dtype=np.float32))
        pieces.append(np.zeros(int(sr * a.pause), dtype=np.float32))
        if device == "cuda":
            torch.cuda.empty_cache()

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    sf.write(a.out, np.concatenate(pieces), sr)
    log(f"Saved voiceover: {a.out}")


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
$files['assemble.py'] = @'
"""Stitch clips, lay voiceover + music, burn captions, export MP4 (CPU / ffmpeg only)."""
import argparse
import os
import shutil
import subprocess
import tempfile

from common import fail, log, run, transcribe, write_srt

FORMATS = {"16:9": (1920, 1080), "9:16": (1080, 1920), "1:1": (1080, 1080)}


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "default=nw=1:nk=1", path], capture_output=True, text=True)
    try:
        return float(out.stdout.strip())
    except ValueError:
        return 0.0


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
            size = 16 if H > W else 12
            style = (f"FontName=Arial,FontSize={size},Bold=1,PrimaryColour=&H00FFFFFF,"
                     f"OutlineColour=&H00000000,Outline=3,Shadow=0,Alignment=2,MarginV={int(H * 0.08)}")
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
$files['CLAUDE.md'] = @'
# Podcast Studio workspace

Local pipeline for turning podcast episodes into new short videos. Hardware: 4 GB GeForce GPU, 16 GB RAM.
Heavy video generation is offloaded to fal.ai (pay per second); everything else runs locally.

## Layout
- `analysis/` - frames + transcripts from the watch skill and faster-whisper
- `voice/` - reference voice samples (`*.wav` + matching `*.txt` transcript)
- `scripts/` - narration scripts
- `clips/` - generated or source clips
- `output/` - finished videos
- `style-bible.md` - the show's distilled style (create it from `analysis/`)

## Tools (Python = `..\venv\Scripts\python.exe`, scripts in `..\app\`)
- Analyze: `python ..\repos\claude-video\skills\watch\scripts\watch.py <url|file> --engine local --detail balanced --out-dir analysis`
- Transcribe: `python ..\app\captions.py <file> --out analysis\<name>`
- Voice sample: `python ..\app\extract_voice.py <url|file> --start MM:SS --duration 12 --outdir voice --name host`
- Voiceover: `python ..\app\tts.py --script scripts\x.txt --ref-audio voice\host.wav --ref-text voice\host.txt --out output\x.wav`
- Cloud clip: `python ..\app\fal_generate.py --endpoint <fal id> --prompt "..." --image frame.png [--video v.mp4 --audio a.wav] --out clips\x.mp4`
- Assemble: `python ..\app\assemble.py --clips a.mp4 b.mp4 --voice output\x.wav --format 9:16 --captions --out output\final.mp4`
- Motion graphics / kinetic captions: use the `/hyperframes` skill (`hyperframes` CLI, Node 22+).

## Rules
- Only clone voices of people who have consented.
- Keep `FAL_KEY` in the user environment, never in files.
- Before generating, read `style-bible.md` and match hooks, pacing, length and caption style.
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

$mins = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
Write-Host "`nDone in $mins min. Launching Podcast Studio..." -ForegroundColor Green
Write-Host "Next: tab 3 > 'Set fal.ai key' (get one at https://fal.ai/dashboard/keys), and run 'claude' once to sign in."
Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$gui`""

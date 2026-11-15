# Podcast Studio - local GUI: prompt -> outline -> script -> voice -> visuals -> video (all on this PC)
# Windows PowerShell 5.1+.  Launch:  powershell -ExecutionPolicy Bypass -File PodcastStudio.ps1
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
function Show-BrandKit {
    $path = Join-Path $Work 'brand.json'
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
[void]$form.ShowDialog()

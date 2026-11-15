# Podcast Studio - local GUI: prompt -> outline -> script -> voice -> visuals -> video (all on this PC)
# Windows PowerShell 5.1+.  Launch:  powershell -ExecutionPolicy Bypass -File PodcastStudio.ps1
#   -SmokeTest  builds every screen invisibly, exercises the main handlers, writes logs\gui-smoke.json and exits
#               (exit code = number of failed checks). Run by Test-PodcastStudio.ps1.
param([switch]$SmokeTest)
$script:Smoke = [bool]$SmokeTest
$Error.Clear()
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security
[System.Windows.Forms.Application]::EnableVisualStyles()

$Root   = Split-Path $PSScriptRoot -Parent
$App    = $PSScriptRoot
$Py     = Join-Path $Root 'venv\Scripts\python.exe'
$Shared = Join-Path $Root 'shared'
$ProfilesFile = Join-Path $Root 'profiles\profiles.json'
function Get-ProfileRegistry {
    # profiles\profiles.json: {"current": name, "profiles": {name: folder}}. Before any profile exists, the
    # original workspace folder is the profile "Main".
    if (Test-Path $ProfilesFile) {
        try {
            $r = [System.IO.File]::ReadAllText($ProfilesFile) | ConvertFrom-Json
            if ($r.profiles) { return $r }
        } catch { }
    }
    return [pscustomobject]@{ current = 'Main'; profiles = [pscustomobject]@{ Main = (Join-Path $Root 'workspace') } }
}
$script:reg0 = Get-ProfileRegistry
$Work = [string]$script:reg0.profiles.($script:reg0.current)
if (-not $Work) { $Work = Join-Path $Root 'workspace' }
$env:PSTUDIO_WORKSPACE = $Work
$Watch  = Join-Path $Root 'repos\claude-video\skills\watch\scripts\watch.py'
$LogDir = Join-Path $Root 'logs'
foreach ($d in 'analysis','voice','scripts','clips','output','frames','projects','library','episodes','highlights','music','assets') { New-Item -ItemType Directory -Force -Path (Join-Path $Work $d) | Out-Null }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$env:PYTHONUNBUFFERED = '1'
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONPATH = $App
$env:PSTUDIO_ROOT = $Root

# ---------------------------------------------------------------- secrets (Windows DPAPI, this Windows user only)
# Same format as secretstore.py: "dpapi1:<base64>". Keys are loaded into this app's own process, never into
# the user's environment variables.
$script:SecretEntropy = [System.Text.Encoding]::UTF8.GetBytes('PodcastStudio.v1')
function Secret-Path([string]$name) {
    if ($name -in 'fal', 'hf') { return (Join-Path $Shared "secrets\$name.dat") }
    return (Join-Path $Work "secrets\$name.dat")
}
function Protect-Secret([string]$name, [string]$text) {
    $p = Secret-Path $name
    New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
    $bytes = [System.Security.Cryptography.ProtectedData]::Protect([System.Text.Encoding]::UTF8.GetBytes($text),
        $script:SecretEntropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [System.IO.File]::WriteAllText($p, 'dpapi1:' + [Convert]::ToBase64String($bytes), [System.Text.Encoding]::ASCII)
}
function Unprotect-Secret([string]$name) {
    $p = Secret-Path $name
    if (-not (Test-Path $p)) { return $null }
    try {
        $kind, $body = ([System.IO.File]::ReadAllText($p).Trim() -split ':', 2)
        $raw = [Convert]::FromBase64String($body)
        if ($kind -eq 'plain1') { $text = [System.Text.Encoding]::UTF8.GetString($raw); Protect-Secret $name $text; return $text }
        if ($kind -ne 'dpapi1') { return $null }
        return [System.Text.Encoding]::UTF8.GetString([System.Security.Cryptography.ProtectedData]::Unprotect($raw,
            $script:SecretEntropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser))
    } catch { return $null }
}
function Remove-Secret([string]$name) { Remove-Item (Secret-Path $name) -Force -ErrorAction Ignore }
function Test-Secret([string]$name) { return [bool](Unprotect-Secret $name) }
function Migrate-Secrets {
    # older versions kept the fal.ai key in a user environment variable and YouTube sign-ins as plain JSON
    $userFal = [Environment]::GetEnvironmentVariable('FAL_KEY', 'User')
    if ($userFal) {
        if (-not (Test-Secret 'fal')) { Protect-Secret 'fal' $userFal }
        if (Test-Secret 'fal') { [Environment]::SetEnvironmentVariable('FAL_KEY', $null, 'User') }
    }
    foreach ($pair in @(@('youtube_client', 'youtube_client_secret.json'), @('youtube_token', 'youtube_token.json'))) {
        $old = Join-Path $Work $pair[1]
        if (Test-Path $old) {
            if (-not (Test-Secret $pair[0])) { Protect-Secret $pair[0] ([System.IO.File]::ReadAllText($old)) }
            if (Test-Secret $pair[0]) { Remove-Item $old -Force }
        }
    }
}
function Load-SecretsIntoProcess {
    $k = Unprotect-Secret 'fal'; if ($k) { $env:FAL_KEY = $k } else { Remove-Item Env:FAL_KEY -ErrorAction Ignore }
    $h = Unprotect-Secret 'hf'; if ($h) { $env:HF_TOKEN = $h } else { Remove-Item Env:HF_TOKEN -ErrorAction Ignore }
}
function Ask-Secret([string]$title, [string]$hint) {
    # masked input box; returns the text or $null
    $kf = New-Object System.Windows.Forms.Form
    $kf.Text = $title; $kf.Size = New-Object System.Drawing.Size(480, 180); $kf.StartPosition = 'CenterParent'
    $kf.FormBorderStyle = 'FixedDialog'; $kf.MaximizeBox = $false; $kf.MinimizeBox = $false
    $kl = New-Object System.Windows.Forms.Label; $kl.Text = $hint
    $kl.Location = New-Object System.Drawing.Point(15, 12); $kl.Size = New-Object System.Drawing.Size(440, 36)
    $kt = New-Object System.Windows.Forms.TextBox; $kt.UseSystemPasswordChar = $true
    $kt.Location = New-Object System.Drawing.Point(15, 55); $kt.Size = New-Object System.Drawing.Size(430, 24)
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Save'; $ok.Location = New-Object System.Drawing.Point(290, 95)
    $ok.DialogResult = 'OK'; $kf.AcceptButton = $ok
    $no = New-Object System.Windows.Forms.Button; $no.Text = 'Cancel'; $no.Location = New-Object System.Drawing.Point(370, 95)
    $no.DialogResult = 'Cancel'; $kf.CancelButton = $no
    $kf.Controls.AddRange(@($kl, $kt, $ok, $no))
    $r = $kf.ShowDialog(); $v = $kt.Text.Trim(); $kf.Dispose()
    if ($r -eq 'OK' -and $v) { return $v }
    return $null
}
Migrate-Secrets
Load-SecretsIntoProcess
function Save-YouTubeFile {
    $f = Pick-File 'Google sign-in file|*.json|All files|*.*' ([Environment]::GetFolderPath('UserProfile'))
    if (-not $f) { return $false }
    $text = [System.IO.File]::ReadAllText($f)
    if ($text -notmatch '"(installed|web)"') { Msg 'That is not a Google OAuth client file. Download the "Desktop app" JSON from Google Cloud Console.'; return $false }
    Protect-Secret 'youtube_client' $text
    Log 'YouTube sign-in file saved (encrypted for this Windows user). You can delete the downloaded copy.'
    return $true
}

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
function Get-Connections {
    # Last saved result of the Settings tab's checks (workspace\connections.json); nothing is connected until checked
    $f = Join-Path $Shared 'connections.json'
    if (Test-Path $f) { try { return ([System.IO.File]::ReadAllText($f) | ConvertFrom-Json) } catch { } }
    return [pscustomobject]@{ services = [pscustomobject]@{}; folders = [pscustomobject]@{} }
}
function Test-Connected([string]$service) {
    $c = Get-Connections
    $entry = $c.services.$service
    return [bool]($entry -and $entry.connected)
}
function Get-ServicesBlock([string]$project, [string]$editor) {
    # The project's service rules (which outside services are allowed, caps, spend so far), added to every agent prompt
    if (-not $project -or -not (Test-Path $Py)) { return '' }
    $text = & $Py -u (Join-Path $App 'services.py') block --project $project --editor $editor 2>$null | Out-String
    if ($LASTEXITCODE -ne 0) { return '' }
    return $text
}
function Start-Agent([string]$dir, [string]$promptFile, [string]$editor = 'claude', [string]$project = '') {
    # Opens Claude Code or Codex in its own window with the prompt read from a file (no quoting problems)
    $exe = if ($editor -eq 'codex') { 'codex' } else { 'claude' }
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        if ($editor -eq 'codex') { Msg 'Codex is not installed. Re-run the installer with -WithCodex, then run "codex" once and choose "Sign in with ChatGPT".' }
        else { Msg 'Claude Code is not installed or not on PATH. Re-run the installer, then run "claude" once to sign in.' }
        return $false
    }
    $run = $promptFile
    $lighter = ''
    if ($project) {
        $rules = Get-ServicesBlock $project $editor
        $run = [System.IO.Path]::ChangeExtension($promptFile, '.run.txt')
        [System.IO.File]::WriteAllText($run, [System.IO.File]::ReadAllText($promptFile) + "`n" + $rules)
        # No paid service allowed: ask Claude Code not to load the account's connectors (less memory). This setting
        # is reported by third parties, not confirmed by Anthropic; if it is ignored the prompt still forbids them.
        if ($editor -eq 'claude' -and $rules -notmatch 'allowed, up to') { $lighter = "`$env:ENABLE_CLAUDEAI_MCP_SERVERS='false'; " }
    }
    $safe = $run -replace "'", "''"
    Start-Process powershell.exe -WorkingDirectory $dir -ArgumentList '-NoExit', '-Command', "$lighter$exe (Get-Content -Raw -LiteralPath '$safe')"
    return $true
}
function Start-Claude([string]$dir, [string]$promptFile, [string]$project = '') { return (Start-Agent $dir $promptFile 'claude' $project) }
$VideoFilter = 'Video|*.mp4;*.mov;*.mkv;*.webm|All files|*.*'
$AudioFilter = 'Audio|*.wav;*.mp3;*.m4a;*.flac|All files|*.*'
$ImageFilter = 'Image|*.png;*.jpg;*.jpeg;*.webp|All files|*.*'

# ---------------------------------------------------------------- form
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Podcast Studio'
$form.Size = New-Object System.Drawing.Size(980, 856)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(8, 42)
$tabs.Size = New-Object System.Drawing.Size(950, 470)
$tabs.Anchor = 'Top,Left,Right'
$form.Controls.Add($tabs)

$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true; $log.ScrollBars = 'Vertical'; $log.ReadOnly = $true
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$log.Location = New-Object System.Drawing.Point(8, 554)
$log.Size = New-Object System.Drawing.Size(950, 250)
$log.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($log)

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(8, 522); $status.Size = New-Object System.Drawing.Size(450, 24)
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

# ---------------------------------------------------------------- profile bar (one profile per show or persona)
Add-Label $form 'Profile' 8 8 50 | Out-Null
$pCombo = New-Object System.Windows.Forms.ComboBox
$pCombo.DropDownStyle = 'DropDownList'
$pCombo.Location = New-Object System.Drawing.Point(60, 8); $pCombo.Size = New-Object System.Drawing.Size(200, 24)
$form.Controls.Add($pCombo)
$script:pSwitching = $false
function Fill-ProfileList {
    $script:pSwitching = $true
    $reg = Get-ProfileRegistry
    $pCombo.Items.Clear()
    foreach ($pp in $reg.profiles.PSObject.Properties) { [void]$pCombo.Items.Add($pp.Name) }
    if ($pCombo.Items.Contains([string]$reg.current)) { $pCombo.SelectedItem = [string]$reg.current }
    $script:pSwitching = $false
}
function Set-Workspace([string]$dir) {
    $script:Work = $dir
    $script:RulesFile = Join-Path $dir 'house-rules.md'
    $env:PSTUDIO_WORKSPACE = $dir
    Migrate-Secrets
    foreach ($d in 'analysis','voice','scripts','clips','output','frames','projects','library','episodes','highlights','music','assets') {
        New-Item -ItemType Directory -Force -Path (Join-Path $dir $d) | Out-Null
    }
}
function Get-ProfileDefaults {
    $f = Join-Path $Work 'profile.json'
    if (Test-Path $f) { try { $m = [System.IO.File]::ReadAllText($f) | ConvertFrom-Json; if ($m.defaults) { return $m.defaults } } catch { } }
    return $null
}
function Apply-ProfileDefaults {
    # New videos start from the profile's saved choices
    $d = Get-ProfileDefaults
    if (-not $d) { return }
    if ($d.seconds) { $cSecs.Text = [string]$d.seconds }
    if ($d.format -and $cFmt.Items.Contains([string]$d.format)) { $cFmt.SelectedItem = [string]$d.format }
    $fl = Get-FramingLabel ([string]$d.framing); if ($fl) { $cFrame.SelectedItem = $fl }
    if ($d.model) { $cModel.Text = [string]$d.model }
    if ($null -ne $d.soundbites) { $cBites.Checked = [bool]$d.soundbites }
    if ($null -ne $d.stills) { $cStills.Checked = [bool]$d.stills }
    if ($null -ne $d.lipsync) { $cLip.Checked = [bool]$d.lipsync }
    if ($d.voice) { $cVoice.Text = [string]$d.voice }
    if ($d.episodes) { $cLib.Text = [string]$d.episodes }
}
function Save-ProfileDefaults {
    $f = Join-Path $Work 'profile.json'
    $meta = [ordered]@{}
    if (Test-Path $f) { try { foreach ($pp in ([System.IO.File]::ReadAllText($f) | ConvertFrom-Json).PSObject.Properties) { $meta[$pp.Name] = $pp.Value } } catch { } }
    $meta['defaults'] = [ordered]@{
        seconds = $cSecs.Text; format = [string]$cFmt.SelectedItem; framing = $Framings[[string]$cFrame.SelectedItem]
        model = $cModel.Text; soundbites = [bool]$cBites.Checked; stills = [bool]$cStills.Checked; lipsync = [bool]$cLip.Checked
        voice = $cVoice.Text; episodes = $cLib.Text }
    [System.IO.File]::WriteAllText($f, ($meta | ConvertTo-Json -Depth 4))
}
function Switch-Profile([string]$name) {
    $out = & $Py -u (Join-Path $App 'profiles.py') switch --name $name 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Msg ("Could not switch profile: " + $out.Trim()); Fill-ProfileList; return }
    $path = ($out -split "`n" | Where-Object { $_ -match '^PROFILE: ' } | Select-Object -First 1) -replace '^PROFILE:\s*', ''
    Set-Workspace $path.Trim()
    $cName.Text = 'my-video'; $cPrompt.Text = ''; $cOutline.Text = ''; $cHook.Items.Clear(); $cVoice.Text = ''; $cLib.Text = ''
    $eList.Items.Clear(); $hList.Items.Clear(); $pTitle.Text = ''; $pDesc.Text = ''; $pTags.Text = ''
    Load-DefaultModel
    Apply-ProfileDefaults
    Load-Services $true
    Log "Profile: $name ($Work)"
    if (-not $script:proc) { Run-Py 'Check this profile''s YouTube sign-in' 'connections.py' @('check', '--service', 'youtube') { Update-Connections } }
}
$pCombo.Add_SelectedIndexChanged({
    if ($script:pSwitching -or $pCombo.SelectedIndex -lt 0) { return }
    if ($script:proc -and -not $script:proc.HasExited) { Msg 'Wait for the running job to finish before switching profile.'; Fill-ProfileList; return }
    Switch-Profile ([string]$pCombo.SelectedItem)
})
function Show-NewProfileDialog {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'New profile'; $f.Size = New-Object System.Drawing.Size(460, 200); $f.StartPosition = 'CenterParent'
    $f.Font = $form.Font; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    Add-Label $f 'Name (a show or persona)' 15 15 200 | Out-Null
    $nm = Add-Text $f 220 15 210
    $copy = New-Object System.Windows.Forms.CheckBox
    $copy.Text = "Copy the setup of '$([string]$pCombo.SelectedItem)' (brand kit, style, rules, voice, defaults)"
    $copy.Location = New-Object System.Drawing.Point(15, 55); $copy.Size = New-Object System.Drawing.Size(420, 40)
    $f.Controls.Add($copy)
    $ok = Add-Button $f 'Create' 240 110 90; $ok.DialogResult = 'OK'; $f.AcceptButton = $ok
    $cancel = Add-Button $f 'Cancel' 340 110 90; $cancel.DialogResult = 'Cancel'; $f.CancelButton = $cancel
    if ($script:Smoke) { $f.Opacity = 0; $f.ShowInTaskbar = $false; $f.Add_Shown({ $this.DialogResult = [System.Windows.Forms.DialogResult]::Cancel }) }
    if ($f.ShowDialog($form) -ne 'OK' -or -not $nm.Text.Trim()) { return }
    $argv = @('-u', (Join-Path $App 'profiles.py'), 'create', '--name', $nm.Text.Trim())
    if ($copy.Checked) { $argv += @('--copy-from', [string]$pCombo.SelectedItem) }
    $out = & $Py @argv 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Msg ("Could not create the profile: " + (($out -split "`n" | Where-Object { $_ -match 'ERROR' } | Select-Object -First 1) -replace '^ERROR:\s*', '')); return }
    Fill-ProfileList
    Switch-Profile $nm.Text.Trim()
    Fill-ProfileList
}
$b = Add-Button $form 'New...' 268 6 70
$b.Add_Click({ Show-NewProfileDialog })
$b = Add-Button $form 'Save as profile defaults' 344 6 175
$b.Add_Click({ Save-ProfileDefaults; Log "New videos in '$([string]$pCombo.SelectedItem)' will start with these settings." })
$b = Add-Button $form 'Export...' 525 6 80
$b.Add_Click({
    $d = New-Object System.Windows.Forms.SaveFileDialog
    $d.Filter = 'Profile export|*.zip'; $d.FileName = ([string]$pCombo.SelectedItem) + '-profile.zip'
    if ($d.ShowDialog() -eq 'OK') { Run-Py 'Export the profile (setup only, no footage or sign-ins)' 'profiles.py' @('export', '--name', [string]$pCombo.SelectedItem, '--out', $d.FileName) }
})
$b = Add-Button $form 'Import...' 611 6 80
$b.Add_Click({
    $f = Pick-File 'Profile export|*.zip|All files|*.*' ([Environment]::GetFolderPath('UserProfile'))
    if ($f) { Run-Py 'Import a profile' 'profiles.py' @('import', '--file', $f) { Fill-ProfileList; Log 'Imported. Choose it in the Profile list to use it.' } }
})
$b = Add-Button $form 'Archive...' 697 6 85
$b.Add_Click({
    $others = @($pCombo.Items | Where-Object { [string]$_ -ne [string]$pCombo.SelectedItem })
    if (-not $others) { Msg 'There is only one profile. Create another before archiving one.'; return }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Archive a profile'; $f.Size = New-Object System.Drawing.Size(460, 210); $f.StartPosition = 'CenterParent'
    $f.Font = $form.Font; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $l = Add-Label $f 'Archived profiles leave the list and their folder moves to profiles\_archived. Nothing is deleted.' 15 12 420
    $l.Size = New-Object System.Drawing.Size(420, 40)
    $which = Add-Combo $f 15 60 250 ([string[]]$others)
    $ok = Add-Button $f 'Archive' 240 115 90; $ok.DialogResult = 'OK'
    $cancel = Add-Button $f 'Cancel' 340 115 90; $cancel.DialogResult = 'Cancel'; $f.CancelButton = $cancel
    if ($f.ShowDialog($form) -ne 'OK') { return }
    Run-Py "Archive profile '$([string]$which.SelectedItem)'" 'profiles.py' @('archive', '--name', [string]$which.SelectedItem) { Fill-ProfileList }
})
$cSimple = New-Object System.Windows.Forms.CheckBox
$cSimple.Text = 'Simple mode'; $cSimple.Location = New-Object System.Drawing.Point(800, 8); $cSimple.Size = New-Object System.Drawing.Size(150, 24)
$form.Controls.Add($cSimple)
$SimpleTabs = @('Create', 'Edit recording', 'Highlights', 'Publish')
function Apply-Mode([bool]$simple) {
    $tabs.SuspendLayout()
    $tabs.TabPages.Clear()
    foreach ($page in $script:allPages) { if (-not $simple -or $SimpleTabs -contains $page.Text) { $tabs.TabPages.Add($page) } }
    $tabs.ResumeLayout()
    $tabs.SelectedIndex = 0
}
$cSimple.Add_CheckedChanged({
    Apply-Mode $cSimple.Checked
    if ($script:Smoke) { return }
    try {
        New-Item -ItemType Directory -Force -Path $Shared | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $Shared 'ui.json'), (@{ simple = [bool]$cSimple.Checked } | ConvertTo-Json))
    } catch { }
})

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

$Guide = Join-Path $App 'guide.html'
$btnGuide = Add-Button $form 'Guide' 465 518 105
$btnGuide.Add_Click({
    if (Test-Path $Guide) { Start-Process $Guide } else { Msg "The guide is missing ($Guide). Re-run Setup-PodcastStudio.ps1." }
})
$btnStop = Add-Button $form 'Stop job' 580 518 110
$btnStop.Add_Click({
    if ($script:proc -and -not $script:proc.HasExited) {
        & taskkill.exe /PID $script:proc.Id /T /F | Out-Null
        Log '--- stopped by user ---'
    }
})
$btnWs = Add-Button $form 'Open workspace' 700 518 125
$btnWs.Add_Click({ Start-Process explorer.exe $Work })
$btnClaude = Add-Button $form 'Open Claude Code' 833 518 125
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
$lr = Add-Label $tR 'What the editor will be asked (you can edit it)' 10 165 135
$lr.Size = New-Object System.Drawing.Size(135, 80)
Add-Label $tR 'Editor' 10 255 135 | Out-Null
$rEditor = Add-Combo $tR 10 280 135 @('Claude Code', 'Codex (ChatGPT)')
function Get-Editor { if ($rEditor.SelectedIndex -eq 1) { return 'codex' } else { return 'claude' } }
$rEditor.Add_SelectedIndexChanged({
    if ($rEditor.SelectedIndex -eq 1 -and -not (Test-Connected 'codex')) {
        $rEditor.SelectedIndex = 0
        Msg 'Codex is not connected. Connect it in the Settings tab first.'
    }
})

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
$b = Add-Button $tR '2. Edit with the editor' 380 85 200
$b.Add_Click({
    $proj = Get-RecordingProject
    if (-not $proj -or -not (Test-Path (Join-Path $proj 'assets\raw.json'))) { Msg 'Press "1. Prepare" first.'; return }
    if (-not $rPrompt.Text.Trim()) { Load-RecordingPrompt }
    $pf = Join-Path $proj ("prompt-" + (Get-RecordingKind) + ".txt")
    [System.IO.File]::WriteAllText($pf, ($rPrompt.Text -replace "`r`n", "`n"))
    $ed = Get-Editor
    if (Start-Agent $Kit $pf $ed $proj) { Log "$([string]$rEditor.SelectedItem) opened in $Kit. Its window shows the edit; answer its questions there." }
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
    [void](Save-YouTubeFile)
})
$b = Add-Button $tP 'Upload to YouTube' 670 285 150
$b.Add_Click({
    $dir = Get-Project; if (-not $dir) { return }
    if (-not (Test-Path (Join-Path $dir 'final.mp4'))) { Msg 'This project has no finished video yet.'; return }
    if (-not $pTitle.Text.Trim()) { Msg 'Add a title first.'; return }
    if (-not (Test-Secret 'youtube_client')) { Msg 'Choose your YouTube sign-in file first (see the steps below).'; return }
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
    [void](Start-Claude $dir $pf $dir)
})
$nP = Add-Label $tP ('Nothing leaves this PC until you press Upload and confirm. Videos upload as private unless you change Privacy. ' +
    'One-time setup: in Google Cloud Console create a project, enable "YouTube Data API v3", create an OAuth client of type "Desktop app", ' +
    'download its JSON file and choose it with "YouTube sign-in file...". Social posts are drafts in the project''s social folder; nothing is posted.') 150 360 760
$nP.Size = New-Object System.Drawing.Size(760, 80)

# ================================================================ TAB: Services (optional, per project; everything works with all off)
$tV = New-Tab 'Services'
Add-Label $tV 'Settings for' 10 12 | Out-Null
$vScope = Add-Combo $tV 150 12 250 @('the Create tab project', 'the Edit recording project')
$vWhich = Add-Label $tV '' 410 12 380
$b = Add-Button $tV 'Load' 800 10 110
$b.Add_Click({ Load-Services $false })
$vHigg = New-Object System.Windows.Forms.CheckBox
$vHigg.Text = 'Higgsfield'; $vHigg.Location = New-Object System.Drawing.Point(150, 50); $vHigg.Size = New-Object System.Drawing.Size(125, 24); $vHigg.Enabled = $false
$tV.Controls.Add($vHigg)
Add-Label $tV 'cap' 275 50 30 | Out-Null
$vHiggCap = Add-Text $tV 305 50 55 '200'
Add-Label $tV 'credits. Generated B-roll, dubbing, upscaling, reframing.' 365 50 545 | Out-Null
$vVid = New-Object System.Windows.Forms.CheckBox
$vVid.Text = 'vidIQ'; $vVid.Location = New-Object System.Drawing.Point(150, 85); $vVid.Size = New-Object System.Drawing.Size(125, 24); $vVid.Enabled = $false
$tV.Controls.Add($vVid)
Add-Label $tV 'cap' 275 85 30 | Out-Null
$vVidCap = Add-Text $tV 305 85 55 '100'
Add-Label $tV 'credits. Topic ideas, title scores, thumbnails, music beds.' 365 85 545 | Out-Null
$vDrive = New-Object System.Windows.Forms.CheckBox
$vDrive.Text = 'Google Drive'; $vDrive.Location = New-Object System.Drawing.Point(150, 120); $vDrive.Size = New-Object System.Drawing.Size(125, 24); $vDrive.Enabled = $false
$tV.Controls.Add($vDrive)
$vFolder = Add-Text $tV 275 120 515
$b = Add-Button $tV 'Drive folder...' 800 118 110
$b.Add_Click({ $d = New-Object System.Windows.Forms.FolderBrowserDialog; if ($d.ShowDialog() -eq 'OK') { $vFolder.Text = $d.SelectedPath } })
$b = Add-Button $tV 'Save for this project' 150 158 180
$b.Add_Click({ [void](Save-Services $false) })
$b = Add-Button $tV 'Save as my default' 340 158 160
$b.Add_Click({ [void](Save-Services $true) })
$vSpent = Add-Label $tV '' 510 162 400

function Get-ServicesProject([bool]$quiet) {
    if ($vScope.SelectedIndex -eq 1) {
        $p = Get-RecordingProject
        if (-not $p -or -not (Test-Path (Join-Path $p 'assets'))) { if (-not $quiet) { Msg 'Prepare the recording in the Edit recording tab first.' }; return $null }
        return $p
    }
    return (Get-Project)
}
function Load-Services([bool]$quiet) {
    $p = Get-ServicesProject $quiet; if (-not $p) { return }
    $vWhich.Text = Split-Path $p -Leaf
    $raw = & $Py -u (Join-Path $App 'services.py') json --project $p 2>$null | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $raw.Trim()) { if (-not $quiet) { Msg 'Could not read the service settings.' }; return }
    $c = $raw | ConvertFrom-Json
    foreach ($pair in @(@($vHigg, 'higgsfield', 'Higgsfield'), @($vVid, 'vidiq', 'vidIQ'), @($vDrive, 'drive', 'Google Drive'))) {
        $box, $key, $label = $pair
        $box.Enabled = [bool]$c.available.$key
        $box.Text = if ($box.Enabled) { $label } else { "$label (not connected)" }
    }
    $vHigg.Checked = [bool]$c.services.higgsfield; $vVid.Checked = [bool]$c.services.vidiq; $vDrive.Checked = [bool]$c.services.drive
    $vHiggCap.Text = [string]$c.caps.higgsfield; $vVidCap.Text = [string]$c.caps.vidiq; $vFolder.Text = [string]$c.drive_folder
    $vSpent.Text = "Used so far: Higgsfield $($c.spent.higgsfield), vidIQ $($c.spent.vidiq) credits"
}
function Save-Services([bool]$asDefault) {
    $p = Get-ServicesProject $false; if (-not $p) { return $false }
    foreach ($cap in $vHiggCap.Text, $vVidCap.Text) { if ($cap -notmatch '^\d+$') { Msg 'Credit caps must be whole numbers.'; return $false } }
    $on = @(); $off = @()
    if ($vHigg.Checked) { $on += 'higgsfield' } else { $off += 'higgsfield' }
    if ($vVid.Checked) { $on += 'vidiq' } else { $off += 'vidiq' }
    if ($vDrive.Checked) { $on += 'drive' } else { $off += 'drive' }
    $argv = @('-u', (Join-Path $App 'services.py'), 'set', '--project', $p, '--cap-higgsfield', $vHiggCap.Text,
        '--cap-vidiq', $vVidCap.Text, '--drive-folder', $vFolder.Text)
    if ($on) { $argv += @('--on') + $on }
    if ($off) { $argv += @('--off') + $off }
    if ($asDefault) { $argv += '--default' }
    $out = & $Py @argv 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Msg ("Could not save: " + $out.Trim()); return $false }
    Log ("Services saved for $(Split-Path $p -Leaf)" + $(if ($asDefault) { ' and as your default for new projects.' } else { '.' }))
    Load-Services $true
    return $true
}
$vScope.Add_SelectedIndexChanged({ Load-Services $true })

$hdr = Add-Label $tV 'Optional tasks for the Create tab project. Each opens Claude Code; it tells you the cost and waits for your yes before any paid step.' 10 205 900
$hdr.Size = New-Object System.Drawing.Size(900, 24)
function Start-ServiceTask([string]$kind, [string[]]$extra = @()) {
    $dir = Get-Project; if (-not $dir) { return }
    $out = & $Py -u (Join-Path $App 'services.py') task --project $dir --kind $kind @extra 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Msg (($out -split "`n" | Where-Object { $_ -match 'ERROR' } | Select-Object -First 1) -replace '^ERROR:\s*', ''); return }
    $taskFile = ($out -split "`n" | Where-Object { $_ -match '^TASK: ' } | Select-Object -First 1) -replace '^TASK:\s*', ''
    if (Start-Claude $dir $taskFile.Trim()) { Log "Claude Code opened for the $kind task. Answer its questions in its window." }
}
$b = Add-Button $tV 'Ideas (vidIQ)' 150 235 160
$b.Add_Click({ Start-ServiceTask 'ideas' })
$b = Add-Button $tV 'Title + thumbnail (vidIQ)' 320 235 200
$b.Add_Click({ Start-ServiceTask 'package' })
$b = Add-Button $tV 'Music bed (vidIQ)' 530 235 160
$b.Add_Click({ Start-ServiceTask 'music' })
Add-Label $tV 'Scene' 150 275 45 | Out-Null
$vScene = Add-Text $tV 198 275 40 '1'
$b = Add-Button $tV 'Generated B-roll (Higgsfield)' 245 273 220
$b.Add_Click({ Start-ServiceTask 'broll' @('--scene', $vScene.Text) })
$vLang = Add-Combo $tV 480 275 130 @('spa Spanish', 'por Portuguese', 'fra French', 'deu German', 'ita Italian', 'hin Hindi', 'jpn Japanese', 'kor Korean', 'cmn Chinese', 'ara Arabic', 'rus Russian', 'tur Turkish', 'pol Polish', 'ind Indonesian', 'fil Filipino', 'swe Swedish', 'fin Finnish', 'eng English')
$b = Add-Button $tV 'Dub (Higgsfield)' 620 273 150
$b.Add_Click({ Start-ServiceTask 'dub' @('--language', ([string]$vLang.SelectedItem).Substring(0, 3)) })
$b = Add-Button $tV 'Copy to Drive folder' 150 313 180
$b.Add_Click({
    $dir = Get-Project; if (-not $dir) { return }
    Run-Py 'Copy finished files to the Drive folder' 'services.py' @('drive', '--project', $dir)
})
$b = Add-Button $tV 'Open spending log' 340 313 160
$b.Add_Click({
    $p = Get-ServicesProject $false; if (-not $p) { return }
    $f = Join-Path $p 'services-log.md'
    if (Test-Path $f) { Start-Process notepad.exe $f } else { Msg 'No paid service has been used for this project yet.' }
})
$nV = Add-Label $tV ('Everything works with all of these off, the default. A service can only be ticked once it is connected in the Settings tab. Higgsfield and vidIQ are connected to your Claude account, so ' +
    'only Claude Code can use them; Codex cannot. Caps are instructions Claude follows and logs against, not limits the services enforce. ' +
    'Uploading to a service sends your footage to that company.') 10 355 900
$nV.Size = New-Object System.Drawing.Size(900, 60)

# ================================================================ TAB: Settings (connect outside services once, for the whole app)
$tG = New-Tab 'Settings'
$b = Add-Button $tG 'Check all' 10 10 120
$b.Add_Click({ Run-Py 'Check every connection' 'connections.py' @('check') { Update-Connections } })
$gWhen = Add-Label $tG '' 140 14 530
$script:connRows = @{}
$connList = @(
    @('claude', 'Claude Code'), @('higgsfield', 'Higgsfield (via Claude)'), @('vidiq', 'vidIQ (via Claude)'),
    @('codex', 'Codex (ChatGPT plan)'), @('youtube', 'YouTube upload'), @('drive', 'Google Drive folder'),
    @('riverside', 'Riverside exports folder'), @('fal', 'fal.ai (cloud video)'), @('ollama', 'Ollama (local model)'))
$y = 48
foreach ($item in $connList) {
    $key, $label = $item
    Add-Label $tG $label 10 $y 200 | Out-Null
    $st = Add-Label $tG 'not checked' 215 $y 115
    $dt = Add-Label $tG '' 335 $y 345
    $cb = Add-Button $tG 'Connect' 690 ($y - 3) 105; $cb.Tag = $key
    $cb.Add_Click({ Connect-Service ([string]$this.Tag) })
    $db = Add-Button $tG 'Disconnect' 800 ($y - 3) 110; $db.Tag = $key
    $db.Add_Click({ Disconnect-Service ([string]$this.Tag) })
    if ($key -eq 'ollama') { $cb.Text = 'Check'; $db.Enabled = $false }
    $script:connRows[$key] = @{ status = $st; detail = $dt }
    $y += 33
}
$b = Add-Button $tG 'Import Riverside session...' 10 352 220
$b.Add_Click({
    if (-not (Test-Connected 'riverside')) { Msg 'Connect the Riverside exports folder first (the folder you download separate tracks into).'; return }
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Choose the folder holding ONE session''s separate tracks (one video per person).'
    $d.SelectedPath = [string](Get-Connections).folders.riverside
    if ($d.ShowDialog() -ne 'OK') { return }
    $name = (Split-Path $d.SelectedPath -Leaf) -replace '[^\w\- ]', '-'
    Run-Py "Import Riverside session '$name'" 'multitrack.py' @('import', '--folder', $d.SelectedPath, '--name', $name,
        '--episodes', (Join-Path $Work 'episodes'), '--lib', (Join-Path $Work 'library'))
})
$gNote = Add-Label $tG ('Connect each service once here. A service that is not connected cannot be ticked in the Services tab or chosen as the editor. ' +
    'Higgsfield and vidIQ are connected on claude.ai, then checked here through Claude Code; its list can occasionally misreport a connector, so a service can still fail when used.') 240 350 670
$gNote.Size = New-Object System.Drawing.Size(670, 70)

function Set-FalKey {
    $v = Ask-Secret 'fal.ai API key' 'Paste your fal.ai key. It is encrypted for this Windows user and only given to this app while it runs.'
    if (-not $v) { return $false }
    Protect-Secret 'fal' $v; $env:FAL_KEY = $v
    Log 'fal.ai key saved (encrypted).'
    return $true
}
function Set-HfToken {
    $v = Ask-Secret 'Hugging Face token' 'Optional: a read token from huggingface.co/settings/tokens, used only for who-said-what labels (WhisperX).'
    if (-not $v) { return $false }
    Protect-Secret 'hf' $v; $env:HF_TOKEN = $v
    Log 'Hugging Face token saved (encrypted).'
    return $true
}
function Update-Connections {
    $c = Get-Connections
    $last = ''
    foreach ($key in $script:connRows.Keys) {
        $row = $script:connRows[$key]
        $e = $c.services.$key
        if ($e) {
            $row.status.Text = if ($e.connected) { 'connected' } else { 'not connected' }
            $row.status.ForeColor = if ($e.connected) { [System.Drawing.Color]::ForestGreen } else { [System.Drawing.Color]::Firebrick }
            $row.detail.Text = [string]$e.detail
            if ([string]$e.checked -gt $last) { $last = [string]$e.checked }
        } else {
            $row.status.Text = 'not checked'; $row.status.ForeColor = [System.Drawing.SystemColors]::ControlText; $row.detail.Text = ''
        }
    }
    $gWhen.Text = if ($last) { "Last checked $last" } else { 'Not checked yet - press Check all.' }
    if ($script:wiz) { Wiz-Refresh }
}
function Connect-Service([string]$key) {
    switch ($key) {
        'claude' { Start-Process powershell.exe -ArgumentList '-NoExit', '-Command', 'Write-Host "Type /login if Claude Code asks you to sign in, then close this window and press Check all."; claude' }
        { $_ -in 'higgsfield', 'vidiq' } {
            Start-Process 'https://claude.ai/settings/connectors'
            Msg 'Connect it on the claude.ai page that just opened (Settings > Connectors), then press Check all here.'
        }
        'codex' {
            if (-not (Get-Command codex -ErrorAction SilentlyContinue)) { Msg 'Codex is not installed. Re-run the installer with -WithCodex.'; return }
            Start-Process powershell.exe -ArgumentList '-NoExit', '-Command', 'codex login; Write-Host "Close this window and press Check all."'
        }
        'youtube' {
            if (-not (Test-Secret 'youtube_client')) {
                if (-not (Save-YouTubeFile)) { Msg 'Choose the OAuth "Desktop app" JSON file from Google Cloud Console (see the Publish tab for the steps).'; return }
            }
            Run-Py 'Sign in to YouTube (your browser opens)' 'publish.py' @('login', '--project', $Work) { Run-Py 'Check YouTube' 'connections.py' @('check', '--service', 'youtube') { Update-Connections } }
        }
        { $_ -in 'drive', 'riverside' } {
            $d = New-Object System.Windows.Forms.FolderBrowserDialog
            $d.Description = if ($key -eq 'drive') { 'Choose a folder that Google Drive for desktop syncs (for example G:\Shared drives\...)' } else { 'Choose the folder you download Riverside separate tracks into' }
            if ($d.ShowDialog() -ne 'OK') { return }
            Run-Py "Connect $key folder" 'connections.py' @('folder', '--service', $key, '--path', $d.SelectedPath) { Update-Connections }
        }
        'fal' { if (Set-FalKey) { Run-Py 'Check fal.ai' 'connections.py' @('check', '--service', 'fal') { Update-Connections } } }
        'ollama' { Run-Py 'Check Ollama' 'connections.py' @('check', '--service', 'ollama') { Update-Connections } }
    }
}
function Disconnect-Service([string]$key) {
    switch ($key) {
        'claude' { Msg 'To sign out, type /logout inside Claude Code.' }
        { $_ -in 'higgsfield', 'vidiq' } { Start-Process 'https://claude.ai/settings/connectors'; Msg 'Disconnect it on claude.ai, then press Check all.' }
        'codex' { & codex logout 2>$null | Out-Null; Run-Py 'Check Codex' 'connections.py' @('check', '--service', 'codex') { Update-Connections } }
        'fal' {
            Remove-Secret 'fal'; [Environment]::SetEnvironmentVariable('FAL_KEY', $null, 'User'); Remove-Item Env:FAL_KEY -ErrorAction Ignore
            Run-Py 'Check fal.ai' 'connections.py' @('check', '--service', 'fal') { Update-Connections }
        }
        default { Run-Py "Disconnect $key" 'connections.py' @('clear', '--service', $key) { Update-Connections } }
    }
}
Update-Connections

# ---------------------------------------------------------------- setup wizard (first start, and Settings > Setup wizard...)
# Walks through every optional connection. Each step can be skipped; nothing here is required to make videos.
$script:SetupDoneFile = Join-Path $Shared 'setup-done.json'
$script:wiz = $null
function Wiz-ConnText([string[]]$keys) {
    $c = Get-Connections
    $lines = foreach ($k in $keys) {
        if ($k -eq 'hf') { 'Hugging Face token: ' + $(if (Test-Secret 'hf') { 'saved (encrypted)' } else { 'not saved' }); continue }
        $e = $c.services.$k
        $name = ($connList | Where-Object { $_[0] -eq $k } | Select-Object -First 1)[1]
        if ($e) { '{0}: {1} - {2}' -f $name, $(if ($e.connected) { 'connected' } else { 'not connected' }), $e.detail }
        else { "${name}: not checked yet" }
    }
    return ($lines -join "`r`n")
}
function Wiz-Check([string[]]$keys) {
    $svc = @($keys | Where-Object { $_ -ne 'hf' })
    if (-not $svc) { Wiz-Refresh; return }
    $argv = @('check'); if ($svc.Count -eq 1) { $argv += @('--service', $svc[0]) }
    Run-Py ('Check ' + ($svc -join ', ')) 'connections.py' $argv { Update-Connections }
}
function Get-WizSteps {
    return @(
        @{ title = 'Welcome to Podcast Studio'; keys = @()
           body = ("Making videos needs no account: the language model, voice, captions and editing all run on this PC.`r`n`r`n" +
                   "The next steps connect optional extras: Claude Code (AI editing), Higgsfield and vidIQ (through Claude), Codex, " +
                   "YouTube upload, a Google Drive folder, Riverside tracks and cloud keys. Skip any step; you can come back from " +
                   "Settings > Setup wizard...`r`n`r`n" +
                   "Security: keys and the YouTube sign-in are encrypted with Windows (DPAPI) so only your Windows account on this PC " +
                   "can read them. They are never put in environment variables, profile exports or logs. Claude Code, Codex and " +
                   "claude.ai keep their own sign-ins; Podcast Studio never sees those passwords.")
           actions = @() },
        @{ title = 'Claude Code (optional: AI editing)'; keys = @('claude')
           body = ("Claude Code edits recordings with the Herk Edit Kit and polishes social posts. It uses your Claude subscription.`r`n`r`n" +
                   "1. Press 'Sign in to Claude Code'. A window opens; type /login if asked and finish in your browser.`r`n" +
                   "2. Close that window and press 'Check'.")
           actions = @(@('Sign in to Claude Code', { Connect-Service 'claude' }), @('Check', { Wiz-Check @('claude') })) },
        @{ title = 'Higgsfield and vidIQ (optional, through Claude)'; keys = @('higgsfield', 'vidiq')
           body = ("These are connected to your Claude account, not to this app.`r`n`r`n" +
                   "1. Press 'Open claude.ai connectors' and connect Higgsfield and/or vidIQ there.`r`n" +
                   "2. Press 'Check' (it asks Claude Code which connectors it can use).`r`n`r`n" +
                   "Each project still decides whether they may be used, with a credit cap (Services tab).")
           actions = @(@('Open claude.ai connectors', { Start-Process 'https://claude.ai/settings/connectors' }), @('Check', { Wiz-Check @('higgsfield', 'vidiq') })) },
        @{ title = 'Codex (optional: second AI editor)'; keys = @('codex')
           body = ("Codex can be chosen as the editor in the Edit recording tab. It signs in with your ChatGPT plan.`r`n`r`n" +
                   "It is installed only when setup ran with -WithCodex. Press 'Sign in to Codex', finish in the browser, then 'Check'.")
           actions = @(@('Sign in to Codex', { Connect-Service 'codex' }), @('Check', { Wiz-Check @('codex') })) },
        @{ title = 'YouTube upload (optional)'; keys = @('youtube')
           body = ("Uploads use your own Google sign-in. One-time setup in Google Cloud Console:`r`n" +
                   "1. Create a project, enable 'YouTube Data API v3'.`r`n" +
                   "2. OAuth consent screen: External, add yourself as a test user.`r`n" +
                   "3. Credentials > Create credentials > OAuth client ID > Desktop app > Download JSON.`r`n" +
                   "4. Press 'Choose sign-in file...' (it is stored encrypted; delete the download afterwards).`r`n" +
                   "5. Press 'Sign in (browser)'.`r`n`r`n" +
                   "Each profile signs in to its own channel.")
           actions = @(@('Open Google Cloud Console', { Start-Process 'https://console.cloud.google.com/apis/credentials' }),
                       @('Choose sign-in file...', { if (Save-YouTubeFile) { Wiz-Check @('youtube') } }),
                       @('Sign in (browser)', { Connect-Service 'youtube' })) },
        @{ title = 'Folders: Google Drive and Riverside (optional)'; keys = @('drive', 'riverside')
           body = ("Google Drive: choose a folder that Google Drive for desktop syncs; finished videos can be copied there.`r`n`r`n" +
                   "Riverside: choose the folder you download a session's separate tracks into. No Riverside login is needed.")
           actions = @(@('Choose Drive folder...', { Connect-Service 'drive' }), @('Choose Riverside folder...', { Connect-Service 'riverside' })) },
        @{ title = 'Cloud keys (optional)'; keys = @('fal', 'hf')
           body = ("fal.ai key: only for the optional Cloud tab (paid cloud video models).`r`n" +
                   "Hugging Face token: only for who-said-what labels with WhisperX.`r`n`r`n" +
                   "Keys are typed into a hidden box and saved encrypted for your Windows account. 'Remove keys' deletes both.")
           actions = @(@('Set fal.ai key...', { if (Set-FalKey) { Wiz-Check @('fal') } }),
                       @('Set Hugging Face token...', { if (Set-HfToken) { Wiz-Refresh } }),
                       @('Remove keys', { Remove-Secret 'fal'; Remove-Secret 'hf'; Load-SecretsIntoProcess; Wiz-Check @('fal') })) },
        @{ title = 'Your show (optional)'; keys = @(); profile = $true
           body = ("Each show or persona is a profile: brand kit, style, house rules, voices, footage and YouTube sign-in.`r`n`r`n" +
                   "Type a name and press 'Create profile' to start one now, or keep using 'Main'.")
           actions = @() },
        @{ title = 'All set'; keys = @('claude', 'higgsfield', 'vidiq', 'codex', 'youtube', 'drive', 'riverside', 'fal', 'hf')
           body = ("Press 'Check all' to see where everything stands, then 'Finish'.`r`n`r`n" +
                   "Anything not connected simply cannot be chosen in a project. Open this again from Settings > Setup wizard...")
           actions = @(@('Check all', { Wiz-Check @('claude', 'codex', 'youtube', 'drive', 'riverside', 'fal') })) }
    )
}
function New-SetupWizard {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Podcast Studio setup'; $f.Size = New-Object System.Drawing.Size(720, 520); $f.StartPosition = 'CenterParent'
    $f.Font = $form.Font; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $w = @{ form = $f; steps = (Get-WizSteps); index = 0; buttons = @() }
    $w.step = Add-Label $f '' 20 12 660
    $w.title = Add-Label $f '' 20 34 660
    $w.title.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 13, [System.Drawing.FontStyle]::Bold); $w.title.Height = 30
    $w.body = Add-Label $f '' 20 72 660; $w.body.Size = New-Object System.Drawing.Size(660, 190)
    $w.status = New-Object System.Windows.Forms.TextBox
    $w.status.Multiline = $true; $w.status.ReadOnly = $true; $w.status.ScrollBars = 'Vertical'
    $w.status.Location = New-Object System.Drawing.Point(20, 320); $w.status.Size = New-Object System.Drawing.Size(660, 95)
    $f.Controls.Add($w.status)
    $w.name = Add-Text $f 20 275 300; $w.makeProfile = Add-Button $f 'Create profile' 330 273 140
    $w.makeProfile.Add_Click({
        $n = $script:wiz.name.Text.Trim(); if (-not $n) { Msg 'Type a name first.'; return }
        $out = & $Py -u (Join-Path $App 'profiles.py') create --name $n 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { Msg ('Could not create the profile: ' + $out.Trim()); return }
        Fill-ProfileList; Switch-Profile $n; Fill-ProfileList
        $script:wiz.status.Text = "Profile '$n' created and selected."
    })
    $w.back = Add-Button $f '< Back' 340 430 100; $w.back.Add_Click({ Wiz-Go ($script:wiz.index - 1) })
    $w.next = Add-Button $f 'Next >' 450 430 100; $w.next.Add_Click({ Wiz-Go ($script:wiz.index + 1) })
    $w.finish = Add-Button $f 'Finish' 560 430 120; $w.finish.Add_Click({ Wiz-Finish; $script:wiz.form.Close() })
    $w.later = Add-Button $f 'Skip setup for now' 20 430 160; $w.later.Add_Click({ Wiz-Finish; $script:wiz.form.Close() })
    $f.Add_FormClosed({ $script:wiz = $null })
    $script:wiz = $w
    Wiz-Go 0
    return $w
}
function Wiz-Go([int]$i) {
    $w = $script:wiz
    if (-not $w) { return }
    $i = [Math]::Max(0, [Math]::Min($i, $w.steps.Count - 1))
    $w.index = $i
    $s = $w.steps[$i]
    $w.step.Text = "Step $($i + 1) of $($w.steps.Count)"
    $w.title.Text = $s.title
    $w.body.Text = $s.body
    foreach ($old in $w.buttons) { $w.form.Controls.Remove($old); $old.Dispose() }
    $w.buttons = @()
    $x = 20
    foreach ($a in $s.actions) {
        $width = [Math]::Max(110, 22 + 7 * $a[0].Length)
        $btn = Add-Button $w.form $a[0] $x 273 $width
        $btn.Tag = $a[1]
        $btn.Add_Click({ & ([scriptblock]$this.Tag) })
        $w.buttons += $btn
        $x += $width + 10
    }
    $w.name.Visible = [bool]$s.profile; $w.makeProfile.Visible = [bool]$s.profile
    $w.back.Enabled = $i -gt 0
    $w.next.Enabled = $i -lt ($w.steps.Count - 1)
    $w.next.Visible = $w.next.Enabled
    $w.form.AcceptButton = if ($w.next.Enabled) { $w.next } else { $w.finish }
    Wiz-Refresh
}
function Wiz-Refresh {
    $w = $script:wiz
    if (-not $w) { return }
    $s = $w.steps[$w.index]
    if ($s.keys.Count) { $w.status.Text = Wiz-ConnText $s.keys }
    elseif (-not $s.profile) { $w.status.Text = '' }
}
function Wiz-Finish {
    New-Item -ItemType Directory -Force -Path (Split-Path $script:SetupDoneFile) | Out-Null
    [System.IO.File]::WriteAllText($script:SetupDoneFile, (@{ done = (Get-Date).ToString('yyyy-MM-dd HH:mm') } | ConvertTo-Json))
}
function Show-SetupWizard {
    $w = New-SetupWizard
    [void]$w.form.ShowDialog($form)
    Update-Connections
}
$b = Add-Button $tG 'Setup wizard...' 690 8 220
$b.Add_Click({ Show-SetupWizard })

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
$b.Add_Click({ [void](Set-FalKey) })
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
$script:allPages = @($tabs.TabPages | ForEach-Object { $_ })
Fill-ProfileList
Apply-ProfileDefaults
$uiFile = Join-Path $Shared 'ui.json'
if ((Test-Path $uiFile) -and -not $script:Smoke) {
    try { if (([System.IO.File]::ReadAllText($uiFile) | ConvertFrom-Json).simple) { $cSimple.Checked = $true } } catch { }
}

# ---------------------------------------------------------------- startup checks
$form.Add_Shown({
    Log "Podcast Studio  |  root: $Root"
    foreach ($tool in 'ffmpeg', 'yt-dlp', 'ollama', 'node', 'claude') {
        if (Get-Command $tool -ErrorAction SilentlyContinue) { Log "  [ok] $tool" } else { Log "  [missing] $tool - re-run setup" }
    }
    if (Test-Path $Py) { Log '  [ok] python venv' } else { Log '  [missing] python venv - re-run setup' }
    if (-not (Test-Path (Join-Path $Shared 'connections.json'))) { Log '  [info] outside services are not connected (optional): Settings tab > Check all' }
    if (Test-Path (Join-Path $Work 'library\index.json')) { Log '  [ok] footage library indexed' } else { Log '  [info] no footage library yet (Create tab > Index footage)' }
    if (-not (Test-Path $script:SetupDoneFile) -and -not $script:Smoke) { Show-SetupWizard }
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
    Expect ($tabs.TabPages.Count -eq 11) "expected 11 tabs, found $($tabs.TabPages.Count)"
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
Check 'settings tab shows connection status' {
    Expect ($script:connRows.Count -eq 9) "expected 9 services, found $($script:connRows.Count)"
    $f = Join-Path $Shared 'connections.json'
    $had = Test-Path $f
    $keep = if ($had) { [System.IO.File]::ReadAllText($f) } else { '' }
    [System.IO.File]::WriteAllText($f, '{"services":{"vidiq":{"connected":true,"detail":"ok","checked":"2099-01-01 10:00"},"codex":{"connected":false,"detail":"no","checked":"2099-01-01 10:00"}},"folders":{}}')
    Update-Connections
    Expect ($script:connRows['vidiq'].status.Text -eq 'connected' -and $script:connRows['codex'].status.Text -eq 'not connected') 'status labels are wrong'
    Expect ($script:connRows['youtube'].status.Text -eq 'not checked') 'unchecked services must say so'
    Expect ((Test-Connected 'vidiq') -and -not (Test-Connected 'codex') -and -not (Test-Connected 'higgsfield')) 'Test-Connected is wrong'
    $rEditor.SelectedIndex = 1
    Expect ($rEditor.SelectedIndex -eq 0) 'Codex must not be selectable while it is not connected'
    $script:connFileBackup = @{ had = $had; text = $keep }
    'connected, not connected and not checked shown; Codex blocked'
}
Check 'services are off by default and save per project' {
    $vScope.SelectedIndex = 0
    Load-Services $true
    Expect (-not $vHigg.Checked -and -not $vVid.Checked -and -not $vDrive.Checked) 'services must start switched off'
    Expect ($vVid.Enabled -and -not $vHigg.Enabled -and -not $vDrive.Enabled) 'only connected services can be ticked'
    Expect ($vHigg.Text -match 'not connected') 'disconnected services must say so'
    $vVid.Checked = $true; $vVidCap.Text = '40'
    Expect (Save-Services $false) 'saving failed'
    $saved = [System.IO.File]::ReadAllText((Join-Path $smokeDir 'services.json')) | ConvertFrom-Json
    Expect ($saved.services.vidiq -and -not $saved.services.higgsfield -and $saved.caps.vidiq -eq 40) 'saved switches are wrong'
    $rules = Get-ServicesBlock $smokeDir 'claude'
    Expect ($rules -match 'vidIQ: allowed, up to 40 credits' -and $rules -match 'Higgsfield: (OFF|NOT CONNECTED)') 'prompt rules do not follow the switches'
    Expect ((Get-ServicesBlock $smokeDir 'codex') -match 'only connected to Claude') 'Codex must be told vidIQ is not available to it'
    $vVid.Checked = $false
    [void](Save-Services $false)
    $out = & $Py -u (Join-Path $App 'services.py') task --project $smokeDir --kind ideas 2>&1 | Out-String
    Expect ($LASTEXITCODE -ne 0 -and $out -match 'is off for this project') 'a task must refuse while its service is off'
    $f = Join-Path $Shared 'connections.json'
    if ($script:connFileBackup.had) { [System.IO.File]::WriteAllText($f, $script:connFileBackup.text) } else { Remove-Item $f -Force }
    Update-Connections
    'off by default, only connected services tickable, saved per project, rules reach the prompt, tasks refuse when off'
}
Check 'guide ships with the app' {
    Expect (Test-Path $Guide) "guide.html is missing from $App"
    $html = [System.IO.File]::ReadAllText($Guide)
    Expect ($html -match '<!doctype html>' -and $html -match '<title>Podcast Studio Guide</title>') 'guide.html is not a complete page'
    Expect ($html -notmatch 'fonts\.googleapis') 'the guide must work offline'
    Expect ($btnGuide.Text -eq 'Guide') 'Guide button missing'
    "$([math]::Round($html.Length / 1024)) KB"
}
Check 'profiles and simple mode' {
    Expect ($pCombo.Items.Count -ge 1 -and $pCombo.SelectedIndex -ge 0) 'the profile list is empty'
    $keepWork = $Work
    $tmpWork = Join-Path $smokeDir 'profile-smoke'
    Set-Workspace $tmpWork
    Expect ($Work -eq $tmpWork -and $env:PSTUDIO_WORKSPACE -eq $tmpWork -and $RulesFile -eq (Join-Path $tmpWork 'house-rules.md')) 'switching workspace did not reach every setting'
    Expect (Test-Path (Join-Path $tmpWork 'projects')) 'profile folders were not created'
    $cSecs.Text = '33'; $cFmt.SelectedItem = '1:1'; $cFrame.SelectedItem = 'Side by side'; $cBites.Checked = $false
    Save-ProfileDefaults
    $cSecs.Text = '45'; $cFmt.SelectedItem = '9:16'; $cFrame.SelectedIndex = 0; $cBites.Checked = $true
    Apply-ProfileDefaults
    Expect ($cSecs.Text -eq '33' -and [string]$cFmt.SelectedItem -eq '1:1' -and [string]$cFrame.SelectedItem -eq 'Side by side' -and -not $cBites.Checked) 'profile defaults did not round-trip'
    Set-Workspace $keepWork
    $cSecs.Text = '45'; $cFmt.SelectedItem = '9:16'; $cFrame.SelectedIndex = 0; $cBites.Checked = $true
    $all = $tabs.TabPages.Count
    $cSimple.Checked = $true
    $simple = $tabs.TabPages.Count
    $names = @($tabs.TabPages | ForEach-Object { $_.Text }) -join ', '
    $cSimple.Checked = $false
    Expect ($simple -eq 4 -and $tabs.TabPages.Count -eq $all) "simple mode shows $simple tabs ($names), then $($tabs.TabPages.Count) of $all"
    "profile switch, defaults round-trip, simple mode $simple of $all tabs"
}
Check 'secrets are encrypted (DPAPI) and readable by Python' {
    $keepWork = $Work
    Set-Workspace (Join-Path $smokeDir 'secret-smoke')
    Protect-Secret 'selftest' 'smoke-secret-123'
    $raw = [System.IO.File]::ReadAllText((Secret-Path 'selftest'))
    Expect ($raw.StartsWith('dpapi1:') -and $raw -notmatch 'smoke-secret') 'the secret file is not DPAPI-encrypted'
    Expect ((Unprotect-Secret 'selftest') -eq 'smoke-secret-123') 'the secret did not round-trip'
    $py = (& $Py -u (Join-Path $App 'secretstore.py') has --name selftest --workspace $Work 2>&1 | Out-String).Trim()
    Expect ($py -match 'yes') "Python could not read the PowerShell secret: $py"
    [System.IO.File]::WriteAllText((Join-Path $Work 'youtube_client_secret.json'), '{"installed":{"client_id":"x"}}')
    Migrate-Secrets
    Expect (-not (Test-Path (Join-Path $Work 'youtube_client_secret.json'))) 'the plain-text sign-in file was not removed'
    Expect ((Unprotect-Secret 'youtube_client') -match 'client_id') 'the plain-text sign-in file was not moved into encrypted storage'
    Remove-Secret 'selftest'
    Set-Workspace $keepWork
    'DPAPI round trip, PowerShell -> Python, plain-text migration'
}
Check 'setup wizard walks every step' {
    $keepDone = $script:SetupDoneFile
    $script:SetupDoneFile = Join-Path $smokeDir 'setup-done.json'
    $w = New-SetupWizard
    $titles = @()
    for ($i = 0; $i -lt $w.steps.Count; $i++) {
        Wiz-Go $i
        Expect ($w.title.Text -and $w.body.Text) "step $($i + 1) is empty"
        if ($w.steps[$i].keys.Count) { Expect ($w.status.Text) "step $($i + 1) shows no status" }
        foreach ($btn in $w.buttons) { Expect ($btn.Tag -is [scriptblock]) "step $($i + 1) button '$($btn.Text)' has no action" }
        $titles += $w.title.Text
    }
    Expect (-not $w.next.Enabled -and $w.back.Enabled) 'the last step should offer Back and Finish only'
    Expect ($titles -match 'YouTube' -and $titles -match 'Claude Code' -and $titles -match 'keys') 'a connection step is missing'
    Wiz-Finish
    Expect (Test-Path $script:SetupDoneFile) 'Finish did not record that setup was done'
    $w.form.Dispose(); $script:wiz = $null
    $script:SetupDoneFile = $keepDone
    "$($titles.Count) steps"
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

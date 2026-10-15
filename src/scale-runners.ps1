# Docker Runner Autoscaler - console view and control
#   Up/Down : change target (Enter applies, switches to manual mode)
#   A       : target = recommended
#   Enter   : apply manual target
#   M       : toggle automatic / manual mode
#   S       : settings (minimum / maximum runners, language)
#   Q / Esc : quit (the autoscaler keeps running)
# -OpenSettings: open the settings screen directly (tray menu)
param([switch]$OpenSettings)

. (Join-Path $PSScriptRoot 'runner-lib.ps1')

function Read-KeyTimeout($seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if ([Console]::KeyAvailable) { return [Console]::ReadKey($true) }
        Start-Sleep -Milliseconds 100
    }
    $null
}

function Clear-Screen {
    $e = [char]27
    Write-Host -NoNewline "$e[H$e[J"
}

# [###|....]  # = up to $value, | = recommended; green up to recommended, yellow up to CPU threads, red above
function Write-Scale([int]$value, [int]$ideal, [int]$cpu, [int]$length) {
    Write-Host -NoNewline "  ["
    for ($i = 1; $i -le $length; $i++) {
        $color = if ($i -le $ideal) { 'Green' } elseif ($i -le $cpu) { 'Yellow' } else { 'Red' }
        $ch    = if ($i -le $value) { '#' } elseif ($i -eq $ideal) { '|' } else { '.' }
        Write-Host -NoNewline $ch -ForegroundColor $color
    }
    Write-Host "]"
}

function Show-State($st, $ctl, $rec, $lim, $target, $pending, $msg) {
    Clear-Screen
    Write-Host (T 'ConsoleTitle' "$(T 'AppName') $(Get-AppVersion)") -ForegroundColor Cyan

    if (-not $st -or $st.error) {
        Write-Host ""
        if ($st -and $st.error) { Write-Host (T 'Error' $st.error) -ForegroundColor Red }
        else { Write-Host (T 'Starting') -ForegroundColor Yellow }
        Write-Host ""
        Write-Host (T 'KeysError') -ForegroundColor DarkGray
        return
    }

    $age = Get-StatusAge $st
    if ($ctl.Mode -eq 'auto') { Write-Host (T 'ModeAuto') -ForegroundColor Green }
    else                      { Write-Host (T 'ModeManual') -ForegroundColor Yellow }
    if ($age -gt 3 * [int]$st.poll) { Write-Host (T 'Stale' $age) -ForegroundColor Red }
    Write-Host ""
    Write-Host (T 'Running' $st.running)
    Write-Host (T 'Busy' $st.busy) -ForegroundColor Magenta
    Write-Host (T 'Idle' $st.idle)
    $tLabel = if ($pending) { T 'TargetPending' $target } else { "$target" }
    Write-Host (T 'Target' $tLabel) -ForegroundColor Yellow
    Write-Host (T 'Recommended' $rec.Ideal $rec.Cpu $rec.MemGb) -ForegroundColor Green
    Write-Host (T 'Limits' $lim.Min $lim.Max)
    Write-Host ""

    Write-Scale $target $rec.Ideal $rec.Cpu ([math]::Max([math]::Max($lim.Max, $rec.Cpu), $target))
    if ($target -gt $rec.Cpu)       { Write-Host (T 'OverCpu') -ForegroundColor Red }
    elseif ($target -gt $rec.Ideal) { Write-Host (T 'OverIdeal') -ForegroundColor Yellow }

    Write-Host ""
    $left = Get-ScaleDownLeft $st
    if ($left -ge 0) { Write-Host (T 'DownIn' ($st.running - $st.target) $left) -ForegroundColor Yellow }
    Write-Host (T 'LastAction' $st.last_action) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host (T 'KeyHelp') -ForegroundColor DarkGray
    if ($msg) { Write-Host ""; Write-Host "  $msg" -ForegroundColor Green }
}

# --- Settings screen ------------------------------------------------------------------

$Languages = @('auto', 'en', 'hu')

function Get-LanguageName([string]$lang) {
    switch ($lang) { 'en' { T 'LangEn' } 'hu' { T 'LangHu' } default { T 'LangAuto' } }
}

# One settings row: "> Label:   value   <- recommended" + hint line
function Write-SettingRow([bool]$selected, [string]$label, [string]$value, [string]$color, [string]$tag, [string]$hint) {
    $prefix = if ($selected) { '> ' } else { '  ' }
    Write-Host -NoNewline ("  $prefix" + "$label".PadRight(22)) -ForegroundColor $(if ($selected) { 'Cyan' } else { 'Gray' })
    Write-Host -NoNewline $value.PadRight(6) -ForegroundColor $color
    if ($tag) { Write-Host -NoNewline $tag -ForegroundColor $color }
    Write-Host ""
    if ($hint) { Write-Host "        $hint" -ForegroundColor DarkGray }
}

function Show-Settings($rec, $ed, [int]$row, [string]$msg) {
    Clear-Screen
    Write-Host (T 'ConsoleTitle' "$(T 'AppName') $(Get-AppVersion) - $(T 'SetTitle')") -ForegroundColor Cyan
    Write-Host ""
    Write-Host (T 'SetRecommended' $rec.Ideal $rec.Cpu $rec.MemGb $GbPerRunner) -ForegroundColor Green
    Write-Host ""

    $minColor = if ($ed.Min -eq 1) { 'Green' } else { 'White' }
    $minTag   = if ($ed.Min -eq 1) { T 'SetRecTag' } else { '' }
    Write-SettingRow ($row -eq 0) (T 'SetMin') "$($ed.Min)" $minColor $minTag (T 'SetMinHint')

    $maxColor = if ($ed.Max -eq $rec.Ideal) { 'Green' } elseif ($ed.Max -gt $rec.Cpu) { 'Red' } elseif ($ed.Max -gt $rec.Ideal) { 'Yellow' } else { 'White' }
    $maxTag   = if ($ed.Max -eq $rec.Ideal) { T 'SetRecTag' } elseif ($ed.Max -gt $rec.Cpu) { (T 'OverCpu').Trim() } elseif ($ed.Max -gt $rec.Ideal) { (T 'OverIdeal').Trim() } else { '' }
    Write-SettingRow ($row -eq 1) (T 'SetMax') "$($ed.Max)" $maxColor $maxTag (T 'SetMaxHint')

    Write-SettingRow ($row -eq 2) (T 'SetLang') (Get-LanguageName $ed.Language) 'White' '' ''
    Write-Host ""
    Write-Scale $ed.Max $rec.Ideal $rec.Cpu ([math]::Max($rec.Cpu, $ed.Max))
    Write-Host ""
    Write-Host (T 'SetKeys') -ForegroundColor DarkGray
    if ($msg) { Write-Host ""; Write-Host "  $msg" -ForegroundColor Green }
}

# Edits MinRunners / MaxRunners / Language; returns when the user saves or goes back
function Edit-Settings {
    $rec = Get-StatusRecommended (Get-RunnerStatus)
    $lim = Get-RunnerLimits $rec.Ideal
    $ed  = @{ Min = $MinRunners; Max = $lim.Max; Language = "$($Settings.Language)" }
    if ($Languages -notcontains $ed.Language) { $ed.Language = 'auto' }
    $row = 0
    $msg = ''
    $limit = [math]::Max(100, 4 * $rec.Cpu)

    while ($true) {
        Show-Settings $rec $ed $row $msg
        $key = Read-KeyTimeout 1
        if (-not $key) { $rec = Get-StatusRecommended (Get-RunnerStatus); continue }
        $msg = ''
        $step = 0
        switch ($key.Key) {
            'UpArrow'    { $row = ($row + 2) % 3 }
            'DownArrow'  { $row = ($row + 1) % 3 }
            'Tab'        { $row = ($row + 1) % 3 }
            'LeftArrow'  { $step = -1 }
            'RightArrow' { $step = 1 }
            'Subtract'   { $step = -1 }
            'Add'        { $step = 1 }
            'OemMinus'   { $step = -1 }
            'OemPlus'    { $step = 1 }
            'R' {
                switch ($row) { 0 { $ed.Min = 1 } 1 { $ed.Max = $rec.Ideal } 2 { $ed.Language = 'auto' } }
                $ed.Min = [math]::Min($ed.Min, $ed.Max)
            }
            'Enter' {
                # the recommended maximum is stored as 0, so it follows the hardware
                $maxSetting = if ($ed.Max -eq $rec.Ideal) { 0 } else { $ed.Max }
                Save-Settings @{ MinRunners = $ed.Min; MaxRunners = $maxSetting; Language = $ed.Language }
                return (T 'SetSaved')
            }
            'Escape' { return '' }
            'Q'      { return '' }
        }
        if ($step) {
            switch ($row) {
                0 { $ed.Min = [math]::Max(0, [math]::Min($limit, $ed.Min + $step)); if ($ed.Min -gt $ed.Max) { $ed.Max = $ed.Min } }
                1 { $ed.Max = [math]::Max(1, [math]::Min($limit, $ed.Max + $step)); if ($ed.Min -gt $ed.Max) { $ed.Min = $ed.Max } }
                2 { $ed.Language = $Languages[([array]::IndexOf($Languages, $ed.Language) + $step + $Languages.Count) % $Languages.Count] }
            }
        }
    }
}

# --- Main loop ------------------------------------------------------------------------

Start-Autoscaler

$target  = 0
$pending = $false
$msg     = ''
$msgTime = Get-Date

if ($OpenSettings) { $msg = Edit-Settings; $msgTime = Get-Date }

while ($true) {
    [void](Update-Settings)
    $st  = Get-RunnerStatus
    $ctl = Get-RunnerControl
    $rec = Get-StatusRecommended $st
    $lim = Get-RunnerLimits $rec.Ideal
    if (-not $pending) {
        $target = if ($ctl.Mode -eq 'manual') { $ctl.Target } elseif ($st) { [int]$st.target } else { 0 }
    }
    if ($msg -and ((Get-Date) - $msgTime).TotalSeconds -gt 5) { $msg = '' }

    Show-State $st $ctl $rec $lim $target $pending $msg

    $key = Read-KeyTimeout 1
    if (-not $key) { continue }

    switch ($key.Key) {
        'UpArrow'   { if ($target -lt $lim.Max) { $target++; $pending = $true } }
        'DownArrow' { if ($target -gt $lim.Min) { $target--; $pending = $true } }
        'A'         { $target = [math]::Max($lim.Min, [math]::Min($lim.Max, $rec.Ideal)); $pending = $true }
        'Enter'     {
            Set-RunnerControl 'manual' $target
            $pending = $false
            $msg = T 'MsgManual' $target; $msgTime = Get-Date
        }
        'M' {
            if ($ctl.Mode -eq 'auto') {
                $t = if ($st) { [int]$st.running } else { $target }
                Set-RunnerControl 'manual' $t
                $msg = T 'MsgManual' $t
            } else {
                Set-RunnerControl 'auto' $target
                $msg = T 'MsgAuto'
            }
            $pending = $false; $msgTime = Get-Date
        }
        'S' {
            $msg = Edit-Settings
            $pending = $false; $msgTime = Get-Date
        }
        'Q'      { Clear-Host; return }
        'Escape' { Clear-Host; return }
    }
}

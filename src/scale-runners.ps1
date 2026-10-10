# Docker Runner Autoscaler - console view and control
#   Up/Down : change target (Enter applies, switches to manual mode)
#   A       : target = recommended
#   Enter   : apply manual target
#   M       : toggle automatic / manual mode
#   Q / Esc : quit (the autoscaler keeps running)

. (Join-Path $PSScriptRoot 'runner-lib.ps1')

function Read-KeyTimeout($seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if ([Console]::KeyAvailable) { return [Console]::ReadKey($true) }
        Start-Sleep -Milliseconds 100
    }
    $null
}

function Show-State($st, $ctl, $target, $pending, $msg) {
    $e = [char]27
    Write-Host -NoNewline "$e[H$e[J"
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
    Write-Host (T 'Recommended' $st.ideal $st.cpu $st.mem_gb) -ForegroundColor Cyan
    Write-Host ""

    Write-Host -NoNewline "  ["
    for ($i = 1; $i -le $Max; $i++) {
        $color = if ($i -le $st.ideal) { 'Green' } elseif ($i -le $st.cpu) { 'Yellow' } else { 'Red' }
        $ch    = if ($i -le $target) { '#' } elseif ($i -eq $st.ideal) { '|' } else { '.' }
        Write-Host -NoNewline $ch -ForegroundColor $color
    }
    Write-Host "]"
    if ($target -gt $st.cpu)       { Write-Host (T 'OverCpu') -ForegroundColor Red }
    elseif ($target -gt $st.ideal) { Write-Host (T 'OverIdeal') -ForegroundColor Yellow }

    Write-Host ""
    $left = Get-ScaleDownLeft $st
    if ($left -ge 0) { Write-Host (T 'DownIn' ($st.running - $st.target) $left) -ForegroundColor Yellow }
    Write-Host (T 'LastAction' $st.last_action) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host (T 'KeyHelp') -ForegroundColor DarkGray
    if ($msg) { Write-Host ""; Write-Host "  $msg" -ForegroundColor Green }
}

Start-Autoscaler

$target  = 0
$pending = $false
$msg     = ''
$msgTime = Get-Date

while ($true) {
    $st  = Get-RunnerStatus
    $ctl = Get-RunnerControl
    if (-not $pending) {
        $target = if ($ctl.Mode -eq 'manual') { $ctl.Target } elseif ($st) { [int]$st.target } else { 0 }
    }
    if ($msg -and ((Get-Date) - $msgTime).TotalSeconds -gt 5) { $msg = '' }

    Show-State $st $ctl $target $pending $msg

    $key = Read-KeyTimeout 1
    if (-not $key) { continue }

    switch ($key.Key) {
        'UpArrow'   { if ($target -lt $Max) { $target++; $pending = $true } }
        'DownArrow' { if ($target -gt 0)    { $target--; $pending = $true } }
        'A'         { if ($st) { $target = [int]$st.ideal; $pending = $true } }
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
        'Q'      { Clear-Host; return }
        'Escape' { Clear-Host; return }
    }
}

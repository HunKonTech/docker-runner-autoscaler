# Docker Runner Autoscaler - system tray app
#  - Starts (and keeps alive) the hidden runner-autoscale.ps1 background process
#  - Icon shows the number of running runners; color: green = idle, orange = busy, red = all busy, gray = error
#  - Click: console view (scale-runners.ps1)
#  - Right click: automatic mode on/off, settings (min / max runners, language), check for updates, uninstall,
#    exit (also stops the autoscaler)
#  - Checks GitHub Releases for updates and installs them automatically (settings.json: AutoUpdate)
param([switch]$Restarted)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. (Join-Path $PSScriptRoot 'runner-lib.ps1')
. (Join-Path $PSScriptRoot 'updater.ps1')

# Single instance (after an update the new instance waits for the old one to exit)
$mutex = New-Object System.Threading.Mutex($false, $TrayMutexName)
try {
    if (-not $mutex.WaitOne($(if ($Restarted) { 30000 } else { 0 }))) { exit }
} catch [System.Threading.AbandonedMutexException] { }

$script:uiProc      = $null
$script:setProc     = $null
$script:iconKey     = ''
$script:lastAction  = $null
$script:lastEnsure  = [datetime]::MinValue
$script:nextUpdate  = (Get-Date).AddSeconds(30)

# Installed apps entry (also refreshes the version shown there after an update)
try { Register-Uninstaller } catch { }

function New-CountIcon([string]$text, [System.Drawing.Color]$bg) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $bg), 0, 0, 31, 31)
    $size = if ($text.Length -ge 2) { 15 } else { 19 }
    $font = New-Object System.Drawing.Font('Segoe UI', $size, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString($text, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 0, 32, 32)), $sf)
    $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function Set-TrayIcon([string]$text, [System.Drawing.Color]$color) {
    $key = "$text|$color"
    if ($key -eq $script:iconKey) { return }
    $old = $tray.Icon
    $tray.Icon = New-CountIcon $text $color
    if ($old) { $old.Dispose() }
    $script:iconKey = $key
}

function Set-TrayText([string]$text) {
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }   # NotifyIcon limit
    $tray.Text = $text
}

function Show-Balloon([string]$text) {
    $tray.BalloonTipTitle = T 'AppName'
    $tray.BalloonTipText  = $text
    $tray.ShowBalloonTip(4000)
}

# Balloons can be hidden by Windows (notifications off, Focus Assist), so menu actions answer in a dialog
function Show-Message([string]$text, [System.Windows.Forms.MessageBoxIcon]$icon = 'Information') {
    [void][System.Windows.Forms.MessageBox]::Show($text, (T 'AppName'), 'OK', $icon)
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon    = New-CountIcon '?' ([System.Drawing.Color]::Gray)
$tray.Text    = T 'AppName'
$tray.Visible = $true

$menu      = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen    = $menu.Items.Add('')
$miOpen.Font = New-Object System.Drawing.Font($miOpen.Font, [System.Drawing.FontStyle]::Bold)
$miAuto    = New-Object System.Windows.Forms.ToolStripMenuItem
[void]$menu.Items.Add($miAuto)
$miSet     = $menu.Items.Add('')
[void]$menu.Items.Add('-')
$miUpdate  = $menu.Items.Add('')
$miVersion = $menu.Items.Add('')
$miVersion.Enabled = $false
[void]$menu.Items.Add('-')
$miUninst  = $menu.Items.Add('')
$miExit    = $menu.Items.Add('')
$tray.ContextMenuStrip = $menu

# (again after the language is changed in the settings)
function Set-MenuTexts {
    $miOpen.Text    = T 'TrayOpen'
    $miAuto.Text    = T 'TrayAuto'
    $miSet.Text     = T 'TraySettings'
    $miUpdate.Text  = T 'TrayUpdate'
    $miVersion.Text = T 'TrayVersion' (Get-AppVersion)
    $miUninst.Text  = T 'TrayUninstall'
    $miExit.Text    = T 'TrayExit'
}
Set-MenuTexts

function Open-Ui {
    if ($script:uiProc -and -not $script:uiProc.HasExited) { return }
    $script:uiProc = Start-Process powershell -PassThru -WorkingDirectory $HomeDir -ArgumentList @(
        '-NoLogo', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $AppDir 'scale-runners.ps1')`"")
}

function Open-Settings {
    if ($script:setProc -and -not $script:setProc.HasExited) { return }
    $script:setProc = Start-Process powershell -PassThru -WorkingDirectory $HomeDir -ArgumentList @(
        '-NoLogo', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $AppDir 'scale-runners.ps1')`"", '-OpenSettings')
}

function Exit-Tray {
    $timer.Stop()
    $tray.Visible = $false
    $tray.Dispose()
    $mutex.ReleaseMutex()
    [System.Windows.Forms.Application]::Exit()
}

function Invoke-UpdateCheck([bool]$interactive) {
    $script:nextUpdate = (Get-Date).AddHours([double]$Settings.UpdateCheckHours)
    try {
        $rel = Find-Update
        if (-not $rel) {
            if ($interactive) { Show-Message (T 'UpdNone' (Get-AppVersion)) }
            return
        }
        Show-Balloon (T 'UpdAvailable' (Get-AppVersion) $rel.tag_name)
        Install-Update $rel
        Show-Balloon (T 'UpdDone' $rel.tag_name)
        # restart: new autoscaler + new tray (waits for this one to exit)
        Stop-AppProcesses @('runner-autoscale.ps1')
        Start-Process powershell -WindowStyle Hidden -WorkingDirectory $HomeDir -ArgumentList @(
            '-STA', '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$(Join-Path $AppDir 'runner-tray.ps1')`"", '-Restarted')
        Exit-Tray
    } catch {
        if ($interactive) { Show-Message (T 'UpdFailed' $_.Exception.Message) 'Error' }
    }
}

function Update-Tray {
    if (Update-Settings) { Set-MenuTexts }
    if ((Get-Date) - $script:lastEnsure -gt [timespan]::FromSeconds(10)) {
        Start-Autoscaler
        $script:lastEnsure = Get-Date
    }
    if ($Settings.AutoUpdate -and (Get-Date) -ge $script:nextUpdate) { Invoke-UpdateCheck $false }

    $st  = Get-RunnerStatus
    $ctl = Get-RunnerControl
    $miAuto.Checked = ($ctl.Mode -eq 'auto')

    if (-not $st -or (Get-StatusAge $st) -gt 3 * [int]$st.poll -or $st.error) {
        Set-TrayText $(if ($st -and $st.error) { T 'TrayErr' $st.error } else { T 'TrayNoResponse' })
        Set-TrayIcon '!' ([System.Drawing.Color]::Gray)
        return
    }

    $mode  = if ($ctl.Mode -eq 'auto') { T 'TrayModeAuto' } else { T 'TrayModeManual' }
    $left  = Get-ScaleDownLeft $st
    $extra = if ($left -ge 0) { T 'TrayTipDown' $left } else { '' }
    Set-TrayText (T 'TrayTip' $st.running $st.busy $mode $extra)

    $color = if ([int]$st.running -eq 0) { [System.Drawing.Color]::Gray }
             elseif ([int]$st.busy -ge [int]$st.running) { [System.Drawing.Color]::OrangeRed }
             elseif ([int]$st.busy -gt 0) { [System.Drawing.Color]::DarkOrange }
             else { [System.Drawing.Color]::SeaGreen }
    Set-TrayIcon ([string]$st.running) $color

    # notify on scale up / down
    if ($script:lastAction -and $st.last_action -ne $script:lastAction -and $st.last_action -notmatch 'started|elindult') {
        Show-Balloon $st.last_action
    }
    $script:lastAction = $st.last_action
}

$tray.add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Open-Ui } })
$miOpen.add_Click({ Open-Ui })
$miAuto.add_Click({
    $ctl = Get-RunnerControl
    $st  = Get-RunnerStatus
    if ($ctl.Mode -eq 'auto') {
        Set-RunnerControl 'manual' $(if ($st) { [int]$st.running } else { $ctl.Target })
    } else {
        Set-RunnerControl 'auto' $ctl.Target
    }
    Update-Tray
})
$miSet.add_Click({ Open-Settings })
$miUpdate.add_Click({ Invoke-UpdateCheck $true })
$miUninst.add_Click({
    # the uninstaller asks for confirmation, then stops this tray app too
    Start-Process powershell -WorkingDirectory $env:TEMP -ArgumentList @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $AppDir 'uninstall.ps1')`"", '-Interactive')
})
$miExit.add_Click({
    Stop-AppProcesses @('runner-autoscale.ps1')
    Exit-Tray
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.add_Tick({
    try { Update-Tray } catch { Set-TrayText (T 'TrayErr' $_.Exception.Message) }
})

Update-Tray
$timer.Start()
[System.Windows.Forms.Application]::Run()

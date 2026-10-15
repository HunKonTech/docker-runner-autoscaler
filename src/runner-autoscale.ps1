# Docker Runner Autoscaler - hidden background process (started by the tray app)
# Control: <home>\state\control.conf  (MODE=auto|manual, TARGET=N)
# Status:  <home>\state\status.json   (read by the tray app and the console)

. (Join-Path $PSScriptRoot 'runner-lib.ps1')

# Single instance
$mutex = New-Object System.Threading.Mutex($false, $AutoscaleMutexName)
try { if (-not $mutex.WaitOne(0)) { exit } } catch [System.Threading.AbandonedMutexException] { }

$surplusSince = $null
$lastAction   = T 'Started' (Get-Date -Format 'HH:mm:ss')

while ($true) {
    [void](Update-Settings)   # limits / language changed from the settings menu
    $err = $null
    $ctl = Get-RunnerControl
    $rec = $null; $lim = $null; $running = 0; $busy = 0; $target = 0; $downIn = -1
    $now = Get-Date -Format 'HH:mm:ss'

    try {
        if (-not $ComposeDir) { throw (T 'ErrNoCompose' $HomeDir) }
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw (T 'ErrNoDockerCli') }
        $rec = Get-Recommended
        if (-not $rec) { throw (T 'ErrDockerDown' $script:DockerError) }

        $ids     = Get-RunnerIds
        $running = $ids.Count
        $busy    = @($ids | Where-Object { Test-Busy $_ }).Count

        $lim = Get-RunnerLimits $rec.Ideal
        if ($ctl.Mode -eq 'auto') {
            $target = [int][math]::Min($lim.Max, [math]::Max($lim.Min, $busy + $IdleBuffer))
            $delay  = $ScaleDownDelay
        } else {
            $target = [int][math]::Max($lim.Min, [math]::Min($lim.Max, $ctl.Target))
            $delay  = 0
        }

        if ($target -gt $running) {
            $surplusSince = $null
            Start-Runners $target
            $lastAction = T 'ScaledUp' $now $running $target
        } elseif ($target -lt $running) {
            if (-not $surplusSince) { $surplusSince = Get-Date }
            $elapsed = ((Get-Date) - $surplusSince).TotalSeconds
            if ($elapsed -ge $delay) {
                $stopped = Stop-IdleRunners $ids ($running - $target)
                $lastAction = if ($stopped -gt 0) { T 'StoppedIdle' $now $stopped } else { T 'StopWaiting' $now }
                $surplusSince = $null
            } else {
                $downIn = [int][math]::Ceiling($delay - $elapsed)
            }
        } else {
            $surplusSince = $null
        }
    } catch {
        $err = $_.Exception.Message
    }

    Write-RunnerStatus ([ordered]@{
        updated       = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        version       = Get-AppVersion
        mode          = $ctl.Mode
        running       = $running
        busy          = $busy
        idle          = $running - $busy
        target        = $target
        ideal         = if ($rec) { $rec.Ideal } else { 0 }
        cpu           = if ($rec) { $rec.Cpu } else { 0 }
        mem_gb        = if ($rec) { $rec.MemGb } else { 0 }
        min_runners   = if ($lim) { $lim.Min } else { $MinRunners }
        max_runners   = if ($lim) { $lim.Max } else { $Max }
        scale_down_in = $downIn
        poll          = $PollSec
        last_action   = $lastAction
        error         = $err
        docker        = (Get-Command docker -ErrorAction SilentlyContinue).Source
    })

    Start-Sleep -Seconds $PollSec
}

# Shared settings and functions (runner-autoscale.ps1, scale-runners.ps1, runner-tray.ps1, updater.ps1)
#
# Layout (installed):            Layout (repository):
#   <home>\app\*.ps1               <repo>\src\*.ps1
#   <home>\docker-compose.yml      <repo>\docker-compose.yml
#   <home>\.env                    <repo>\.env
#   <home>\settings.json           <repo>\settings.json   (optional)
#   <home>\state\                  <repo>\state\
# <home> can be overridden with the DRA_HOME environment variable.

$AppDir  = $PSScriptRoot
$HomeDir = if ($env:DRA_HOME) { $env:DRA_HOME } else { Split-Path $AppDir -Parent }

. (Join-Path $AppDir 'i18n.ps1')

# --- Settings (defaults, overridable in settings.json) ---------------------------
$Settings = [ordered]@{
    Language         = 'auto'    # auto | en | hu
    ServiceName      = 'runner'  # compose service name
    MaxRunners       = 50
    MinRunners       = 1         # auto mode: always keep this many
    IdleBuffer       = 1         # auto mode: keep this many idle runners ready
    GbPerRunner      = 2         # estimated memory per busy runner (GB)
    PollSec          = 10        # check interval (s)
    ScaleDownDelay   = 120       # auto mode: surplus must persist this long before stopping (s)
    StopTimeout      = 60        # time given to deregister on stop (s)
    AutoUpdate       = $true
    UpdateRepo       = 'HunKonTech/docker-runner-autoscaler'
    UpdateCheckHours = 6
}
$SettingsFile = Join-Path $HomeDir 'settings.json'
if (Test-Path $SettingsFile) {
    try {
        $user = Get-Content -Raw -Encoding UTF8 $SettingsFile | ConvertFrom-Json
        foreach ($p in $user.PSObject.Properties) { if ($Settings.Contains($p.Name)) { $Settings[$p.Name] = $p.Value } }
    } catch { Write-Warning "settings.json: $($_.Exception.Message)" }
}
Set-Language $Settings.Language

$Service        = $Settings.ServiceName
$Max            = [int]$Settings.MaxRunners
$MinRunners     = [int]$Settings.MinRunners
$IdleBuffer     = [int]$Settings.IdleBuffer
$GbPerRunner    = [double]$Settings.GbPerRunner
$PollSec        = [int]$Settings.PollSec
$ScaleDownDelay = [int]$Settings.ScaleDownDelay
$StopTimeout    = [int]$Settings.StopTimeout

$ComposeDir  = if (Test-Path (Join-Path $HomeDir 'docker-compose.yml')) { $HomeDir } else { $null }
$StateDir    = Join-Path $HomeDir 'state'
$StatusFile  = Join-Path $StateDir 'status.json'
$ControlFile = Join-Path $StateDir 'control.conf'
$VersionFile = Join-Path $AppDir 'VERSION'
$AutoscaleMutexName = 'Local\DockerRunnerAutoscaler.Autoscale'
$TrayMutexName      = 'Local\DockerRunnerAutoscaler.Tray'

function Get-AppVersion {
    if (Test-Path $VersionFile) { (Get-Content -Raw $VersionFile).Trim() } else { '0.0.0-dev' }
}

# --- State / control files ----------------------------------------------------------

function Get-RunnerStatus {
    try { Get-Content -Raw -Encoding UTF8 -LiteralPath $StatusFile -ErrorAction Stop | ConvertFrom-Json } catch { $null }
}

function Write-RunnerStatus($obj) {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
    $tmp = "$StatusFile.tmp"
    [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Compress))
    Move-Item -LiteralPath $tmp -Destination $StatusFile -Force
}

function Get-RunnerControl {
    $c = [pscustomobject]@{ Mode = 'auto'; Target = 1 }
    try {
        foreach ($l in Get-Content -LiteralPath $ControlFile -ErrorAction Stop) {
            if ($l -match '^MODE=(auto|manual)') { $c.Mode = $Matches[1] }
            if ($l -match '^TARGET=(\d+)')       { $c.Target = [int]$Matches[1] }
        }
    } catch { }
    $c
}

function Set-RunnerControl([string]$mode, [int]$target) {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
    $target = [math]::Max(0, [math]::Min($Max, $target))
    [IO.File]::WriteAllText($ControlFile, "MODE=$mode`nTARGET=$target`n")
}

function Get-StatusAge($st) {
    if (-not $st) { return [int]::MaxValue }
    [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$st.updated
}

# Seconds left until scale-down (live countdown), -1 if none pending
function Get-ScaleDownLeft($st) {
    if (-not $st -or [int]$st.scale_down_in -lt 0) { return -1 }
    [math]::Max(0, [int]$st.scale_down_in - (Get-StatusAge $st))
}

# --- Processes ---------------------------------------------------------------------

function Test-AutoscalerRunning {
    $m = $null
    if ([Threading.Mutex]::TryOpenExisting($AutoscaleMutexName, [ref]$m)) { $m.Dispose(); return $true }
    $false
}

function Start-Autoscaler {
    if (Test-AutoscalerRunning) { return }
    Start-Process powershell -WindowStyle Hidden -WorkingDirectory $HomeDir -ArgumentList @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$(Join-Path $AppDir 'runner-autoscale.ps1')`"")
}

function Stop-AppProcesses([string[]]$scripts = @('runner-autoscale.ps1')) {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $cl = $_.CommandLine; $cl -and ($scripts | Where-Object { $cl -like "*$_*" }) -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# --- Docker -------------------------------------------------------------------------

# If docker is not on PATH (hidden process, fresh install), try the Docker Desktop locations
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $dockerBin = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\bin'),   # per-user install
        (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin')              # machine-wide install
    ) | Where-Object { Test-Path (Join-Path $_ 'docker.exe') } | Select-Object -First 1
    if ($dockerBin) { $env:Path = "$dockerBin;$env:Path" }
}

$script:DockerError = $null

# Physical RAM of the host (GB), queried once; 0 if unavailable
function Get-HostMemGb {
    if ($null -eq $script:HostMemGb) {
        $script:HostMemGb = 0
        try { $script:HostMemGb = [math]::Round([double](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB, 1) } catch { }
    }
    $script:HostMemGb
}

function Get-Recommended {
    # capture stderr too, so the real Docker message is shown on failure
    $out  = @(docker info --format '{{.NCPU}} {{.MemTotal}}' 2>&1 | ForEach-Object { "$_".Trim() })
    $line = $out | Where-Object { $_ -match '^\d+\s+\d+$' } | Select-Object -First 1
    if (-not $line) {
        $script:DockerError = ($out | Where-Object { $_ -and $_ -notmatch '^WARNING' } | Select-Object -First 1)
        if (-not $script:DockerError) { $script:DockerError = T 'ErrEmptyInfo' }
        return $null
    }
    $script:DockerError = $null
    $cpu, $mem = $line -split '\s+'
    $cpu   = [int]$cpu
    $memGb = [math]::Round([double]$mem / 1GB, 1)
    # Docker Desktop's WSL2 VM only reports ~half of the host RAM by default,
    # so count with the machine's physical memory when it is larger
    $hostGb = Get-HostMemGb
    if ($hostGb -gt $memGb) { $memGb = $hostGb }
    $ideal = [math]::Max(1, [math]::Min($cpu, [math]::Floor($memGb / $GbPerRunner)))
    [pscustomobject]@{ Cpu = $cpu; MemGb = $memGb; Ideal = [int]$ideal }
}

function Get-RunnerIds {
    $ids = docker compose --project-directory $ComposeDir ps -q --status running $Service 2>$null
    if ($ids) { @($ids) } else { @() }
}

# Busy = a Runner.Worker process is running ([R] so pgrep does not match its own command line)
function Test-Busy($id) {
    docker exec $id pgrep -f '[R]unner.Worker' 2>$null | Out-Null
    $LASTEXITCODE -eq 0
}

function Start-Runners([int]$target) {
    docker compose --project-directory $ComposeDir up -d --no-recreate --scale "$Service=$target" $Service 2>$null | Out-Null
}

# Stops idle runners only; returns how many were stopped
function Stop-IdleRunners([string[]]$ids, [int]$count) {
    $victims = @($ids | Where-Object { -not (Test-Busy $_) } | Select-Object -First $count)
    $victims = @($victims | Where-Object { -not (Test-Busy $_) })   # last check
    if ($victims.Count -gt 0) {
        docker stop -t $StopTimeout @victims 2>$null | Out-Null
        docker rm @victims 2>$null | Out-Null
    }
    $victims.Count
}

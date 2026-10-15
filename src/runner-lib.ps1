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
$SettingsFile = Join-Path $HomeDir 'settings.json'

# Loads settings.json over the defaults (again on every call, so changes apply without a restart)
function Import-Settings {
    $s = [ordered]@{
        Language         = 'auto'    # auto | en | hu
        DockerEngine     = 'desktop' # desktop (Docker Desktop) | wsl (Docker Engine inside a WSL distro)
        WslDistro        = ''        # DockerEngine=wsl: distro name, empty = default distro
        ServiceName      = 'runner'  # compose service name
        MaxRunners       = 0         # upper limit, 0 = recommended (from CPU / RAM)
        MinRunners       = 1         # always keep this many
        IdleBuffer       = 1         # auto mode: keep this many idle runners ready
        GbPerRunner      = 2         # estimated memory per busy runner (GB)
        PollSec          = 10        # check interval (s)
        ScaleDownDelay   = 120       # auto mode: surplus must persist this long before stopping (s)
        StopTimeout      = 60        # time given to deregister on stop (s)
        AutoUpdate       = $true
        UpdateRepo       = 'HunKonTech/docker-runner-autoscaler'
        UpdateCheckHours = 6
    }
    $script:SettingsStamp = [datetime]::MinValue
    if (Test-Path $SettingsFile) {
        try {
            $script:SettingsStamp = (Get-Item -LiteralPath $SettingsFile).LastWriteTimeUtc
            $user = Get-Content -Raw -Encoding UTF8 $SettingsFile | ConvertFrom-Json
            foreach ($p in $user.PSObject.Properties) { if ($s.Contains($p.Name)) { $s[$p.Name] = $p.Value } }
        } catch { Write-Warning "settings.json: $($_.Exception.Message)" }
    }
    Set-Language $s.Language

    $script:Settings       = $s
    $script:Service        = $s.ServiceName
    $script:Max            = [math]::Max(0, [int]$s.MaxRunners)
    $script:MinRunners     = [math]::Max(0, [int]$s.MinRunners)
    $script:IdleBuffer     = [int]$s.IdleBuffer
    $script:GbPerRunner    = [double]$s.GbPerRunner
    $script:PollSec        = [int]$s.PollSec
    $script:ScaleDownDelay = [int]$s.ScaleDownDelay
    $script:StopTimeout    = [int]$s.StopTimeout
}

# Reloads settings.json if it changed since the last load; $true if it did
function Update-Settings {
    $stamp = if (Test-Path $SettingsFile) { (Get-Item -LiteralPath $SettingsFile).LastWriteTimeUtc } else { [datetime]::MinValue }
    if ($stamp -eq $script:SettingsStamp) { return $false }
    Import-Settings
    $true
}

# Writes the given keys into settings.json (other keys are kept) and reloads it
function Save-Settings([hashtable]$values) {
    $obj = [ordered]@{}
    if (Test-Path $SettingsFile) {
        try {
            $cur = Get-Content -Raw -Encoding UTF8 $SettingsFile | ConvertFrom-Json
            foreach ($p in $cur.PSObject.Properties) { $obj[$p.Name] = $p.Value }
        } catch { }
    }
    foreach ($k in $values.Keys) { $obj[$k] = $values[$k] }
    [IO.File]::WriteAllText($SettingsFile, ([pscustomobject]$obj | ConvertTo-Json))
    Import-Settings
}

Import-Settings

# Recommended runner count: one per CPU thread, GbPerRunner of memory each
function Get-IdealRunners([int]$cpu, [double]$memGb) {
    [int][math]::Max(1, [math]::Min($cpu, [math]::Floor($memGb / $GbPerRunner)))
}

# Effective lower / upper runner limits (MaxRunners = 0 -> the recommended count)
function Get-RunnerLimits([int]$ideal) {
    $hi = if ($Max -gt 0) { $Max } else { [math]::Max(1, $ideal) }
    [pscustomobject]@{ Min = [int][math]::Min($MinRunners, $hi); Max = [int]$hi }
}

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
    $target = [math]::Max(0, $target)
    if ($Max -gt 0) { $target = [math]::Min($Max, $target) }
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

# --- Windows "Installed apps" entry ---------------------------------------------------

$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DockerRunnerAutoscaler'

# Installed layout (<home>\app); a repository checkout (src\) is never registered or deleted
function Test-InstalledLayout { (Split-Path $AppDir -Leaf) -eq 'app' }

# Adds / refreshes the entry in Settings -> Apps -> Installed apps (per user, no admin rights)
function Register-Uninstaller {
    if (-not (Test-InstalledLayout)) { return }
    $ps  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $cmd = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $AppDir 'uninstall.ps1')`""
    if (-not (Test-Path $UninstallKey)) { New-Item -Path $UninstallKey -Force | Out-Null }
    $values = [ordered]@{
        DisplayName          = T 'AppName'
        DisplayVersion       = Get-AppVersion
        Publisher            = ($Settings.UpdateRepo -split '/')[0]
        URLInfoAbout         = "https://github.com/$($Settings.UpdateRepo)"
        InstallLocation      = $HomeDir
        DisplayIcon          = $ps
        UninstallString      = "$cmd -Interactive"
        QuietUninstallString = "$cmd -StopRunners"
    }
    foreach ($k in $values.Keys) { New-ItemProperty -Path $UninstallKey -Name $k -Value $values[$k] -PropertyType String -Force | Out-Null }
    foreach ($k in 'NoModify', 'NoRepair') { New-ItemProperty -Path $UninstallKey -Name $k -Value 1 -PropertyType DWord -Force | Out-Null }
}

function Unregister-Uninstaller {
    if (Test-Path $UninstallKey) { Remove-Item $UninstallKey -Recurse -Force }
}

# --- Docker -------------------------------------------------------------------------

if ($Settings.DockerEngine -eq 'wsl') {
    # Docker Engine inside WSL: every docker call goes through wsl.exe (-e: no shell, args passed as-is)
    $script:WslArgs = @(if ($Settings.WslDistro) { '-d', $Settings.WslDistro }) + '-e'

    # Windows path -> WSL path (wslpath, falling back to the default /mnt/<drive> mount)
    function ConvertTo-WslPath([string]$path) {
        $p = @(wsl.exe @script:WslArgs wslpath -a $path 2>$null) | Select-Object -First 1
        if ($LASTEXITCODE -eq 0 -and $p) { return "$p".Trim() }
        if ($path -match '^([A-Za-z]):\\?(.*)$') { return "/mnt/$($Matches[1].ToLower())/$($Matches[2] -replace '\\', '/')" }
        $path
    }

    $script:WslComposeDir = $null
    function docker {
        $a = @($args | ForEach-Object {
            if ($ComposeDir -and $_ -eq $ComposeDir) {
                if (-not $script:WslComposeDir) { $script:WslComposeDir = ConvertTo-WslPath $ComposeDir }
                $script:WslComposeDir
            } else { $_ }
        })
        wsl.exe @script:WslArgs docker @a
    }
} elseif (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    # docker is not on PATH (hidden process, fresh install): try the Docker Desktop locations
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
    [pscustomobject]@{ Cpu = $cpu; MemGb = $memGb; Ideal = (Get-IdealRunners $cpu $memGb) }
}

# Recommendation without Docker (CPU threads and physical RAM of this machine)
function Get-LocalRecommended {
    $cpu = [Environment]::ProcessorCount
    $mem = Get-HostMemGb
    [pscustomobject]@{ Cpu = $cpu; MemGb = $mem; Ideal = (Get-IdealRunners $cpu $mem) }
}

# Recommendation from the autoscaler's status, or computed locally when it has none
function Get-StatusRecommended($st) {
    if ($st -and [int]$st.ideal -gt 0) { return [pscustomobject]@{ Cpu = [int]$st.cpu; MemGb = $st.mem_gb; Ideal = [int]$st.ideal } }
    Get-LocalRecommended
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

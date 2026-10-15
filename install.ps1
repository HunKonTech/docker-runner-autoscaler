# Docker Runner Autoscaler - installer
#
# One-liner (latest release):
#   irm https://github.com/HunKonTech/docker-runner-autoscaler/releases/latest/download/install.ps1 | iex
#
# From a local checkout (development):
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Source .
#
# Docker engine (asked on first install, kept in settings.json):
#   -DockerEngine desktop   Docker Desktop
#   -DockerEngine wsl       Docker Engine installed inside a WSL distro (no Docker Desktop), see -WslDistro
#
# Installs to %LOCALAPPDATA%\DockerRunnerAutoscaler, adds a Startup shortcut, registers it in
# Settings -> Apps -> Installed apps (uninstall from there) and starts the tray app.
# Re-running updates the app; .env, settings.json and docker-compose.yml are kept.
param(
    [string]$Version    = 'latest',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'DockerRunnerAutoscaler'),
    [string]$Repo       = 'HunKonTech/docker-runner-autoscaler',
    [string]$Source,                 # local repo folder instead of downloading
    [ValidateSet('desktop', 'wsl')]
    [string]$DockerEngine,           # empty = keep the current setting, or ask on first install
    [string]$WslDistro,              # DockerEngine=wsl: distro name (empty = default distro)
    [switch]$NoStart
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Step($t) { Write-Host ">> $t" -ForegroundColor Cyan }

# Installed WSL distros (from the registry, so no UTF-16 wsl.exe output parsing); default first
function Get-WslDistros {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path $key)) { return @() }
    $default = (Get-ItemProperty $key -ErrorAction SilentlyContinue).DefaultDistribution
    @(Get-ChildItem $key | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath
        if ($p.DistributionName) { [pscustomobject]@{ Name = $p.DistributionName; Default = ($_.PSChildName -eq $default) } }
    } | Sort-Object { -not $_.Default }, Name)
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("dra-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # 1. Package
    if ($Source) {
        Step "Using local source: $Source"
        $pkg = Join-Path $tmp 'pkg'
        New-Item -ItemType Directory -Path (Join-Path $pkg 'app') | Out-Null
        Copy-Item (Join-Path $Source 'src\*') (Join-Path $pkg 'app') -Recurse
        foreach ($f in 'docker-compose.yml', '.env.example', 'settings.example.json') { Copy-Item (Join-Path $Source $f) $pkg }
        if (-not (Test-Path (Join-Path $pkg 'app\VERSION'))) { Set-Content (Join-Path $pkg 'app\VERSION') '0.0.0-dev' }
    } else {
        $api = if ($Version -eq 'latest') { "https://api.github.com/repos/$Repo/releases/latest" }
               else { "https://api.github.com/repos/$Repo/releases/tags/v$($Version.TrimStart('v'))" }
        $headers = @{ 'User-Agent' = 'docker-runner-autoscaler' }
        $rel = Invoke-RestMethod $api -Headers $headers
        Step "Downloading $($rel.tag_name)"
        $zipAsset = $rel.assets | Where-Object { $_.name -like 'docker-runner-autoscaler-*.zip' } | Select-Object -First 1
        $shaAsset = $rel.assets | Where-Object { $_.name -eq "$($zipAsset.name).sha256" } | Select-Object -First 1
        if (-not $zipAsset -or -not $shaAsset) { throw 'Release package not found.' }
        $zip = Join-Path $tmp $zipAsset.name
        Invoke-WebRequest $zipAsset.browser_download_url -OutFile $zip -Headers $headers -UseBasicParsing
        $sha = Join-Path $tmp 'sha256'
        Invoke-WebRequest $shaAsset.browser_download_url -OutFile $sha -Headers $headers -UseBasicParsing
        $expected = (Get-Content $sha -Raw).Trim().Split(' ')[0].ToUpper()
        if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $expected) { throw 'Checksum mismatch.' }
        $pkg = Join-Path $tmp 'pkg'
        Expand-Archive $zip -DestinationPath $pkg
    }

    # 2. Stop running instances
    Step 'Stopping running instances'
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -match 'runner-(autoscale|tray)\.ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    # 3. Copy files
    Step "Installing to $InstallDir"
    $appDir = Join-Path $InstallDir 'app'
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null
    Copy-Item (Join-Path $pkg 'app\*') $appDir -Recurse -Force
    Get-ChildItem $appDir -Recurse -File | Unblock-File
    foreach ($f in 'docker-compose.yml', '.env.example', 'settings.example.json') {
        $dst = Join-Path $InstallDir $f
        if ($f -eq 'docker-compose.yml' -and (Test-Path $dst)) { $dst = "$dst.new" }
        Copy-Item (Join-Path $pkg $f) $dst -Force
    }

    # 4. .env (first install)
    $envFile = Join-Path $InstallDir '.env'
    if (-not (Test-Path $envFile)) {
        Step 'Configuration (.env)'
        $org = Read-Host 'GitHub organization (ORG_NAME)'
        $tok = Read-Host 'Fine-grained PAT (Self-hosted runners: Read and write)' -AsSecureString
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($tok))
        $content = (Get-Content (Join-Path $InstallDir '.env.example') -Raw) `
            -replace '(?m)^GH_PAT=.*$', "GH_PAT=$plain" -replace '(?m)^ORG_NAME=.*$', "ORG_NAME=$org"
        [IO.File]::WriteAllText($envFile, $content)
    }

    # 5. Docker engine (settings.json)
    $settingsFile = Join-Path $InstallDir 'settings.json'
    $cfg = if (Test-Path $settingsFile) { Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json }
           else { Get-Content (Join-Path $InstallDir 'settings.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
    $engine = if ($DockerEngine) { $DockerEngine } elseif ((Test-Path $settingsFile) -and $cfg.DockerEngine) { $cfg.DockerEngine } else { $null }
    $distro = if ($PSBoundParameters.ContainsKey('WslDistro')) { $WslDistro } else { $cfg.WslDistro }
    if (-not $engine) {
        Step 'Docker engine'
        Write-Host '  1) Docker Desktop'
        Write-Host '  2) Docker Engine inside WSL (no Docker Desktop)'
        $engine = if ((Read-Host 'Which one is installed on this machine? [1]').Trim() -eq '2') { 'wsl' } else { 'desktop' }
        if ($engine -eq 'wsl' -and -not $PSBoundParameters.ContainsKey('WslDistro')) {
            $distros = Get-WslDistros
            if ($distros.Count -eq 0) { Write-Warning 'No WSL distro found. Install one (wsl --install) with Docker Engine in it.' }
            for ($i = 0; $i -lt $distros.Count; $i++) {
                $mark = if ($distros[$i].Default) { ' (default)' } else { '' }
                Write-Host "  $($i + 1)) $($distros[$i].Name)$mark"
            }
            $pick = (Read-Host 'WSL distro running Docker [1]').Trim()
            $n = 0
            $distro = if (-not $pick -and $distros.Count) { $distros[0].Name }
                      elseif ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $distros.Count) { $distros[$n - 1].Name }
                      else { $pick }
        }
    }
    if ($engine -ne 'wsl') { $distro = '' }
    $cfg | Add-Member -NotePropertyName DockerEngine -NotePropertyValue $engine -Force
    $cfg | Add-Member -NotePropertyName WslDistro -NotePropertyValue ([string]$distro) -Force
    [IO.File]::WriteAllText($settingsFile, ($cfg | ConvertTo-Json))
    if ($engine -eq 'wsl') {
        $wslArgs = @(if ($distro) { '-d', $distro }) + '-e'
        $v = @(wsl.exe @wslArgs docker version --format '{{.Server.Version}}' 2>$null) | Select-Object -First 1
        $where = if ($distro) { $distro } else { 'the default WSL distro' }
        if ($LASTEXITCODE -eq 0 -and $v) { Write-Host "  Docker $("$v".Trim()) in $where" }
        else { Write-Warning "Docker did not answer in $where. Install Docker Engine there and make sure the daemon starts (e.g. enable systemd)." }
    }

    # 6. Startup shortcut
    Step 'Startup shortcut'
    $lnkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Docker Runner Autoscaler.lnk'
    $ws  = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($lnkPath)
    $lnk.TargetPath       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $lnk.Arguments        = "-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$appDir\runner-tray.ps1`""
    $lnk.WorkingDirectory = $InstallDir
    $lnk.WindowStyle      = 7
    $lnk.Description      = 'Docker Runner Autoscaler'
    $lnk.Save()

    # 7. Installed apps entry (child scope, so runner-lib does not touch this script's variables)
    Step 'Installed apps entry'
    & { . (Join-Path $appDir 'runner-lib.ps1'); Register-Uninstaller }

    # 8. Start
    if (-not $NoStart) {
        Step 'Starting tray app'
        Start-Process $lnk.TargetPath -ArgumentList $lnk.Arguments -WorkingDirectory $InstallDir -WindowStyle Hidden
    }
    Write-Host "Installed $(Get-Content (Join-Path $appDir 'VERSION')) -> $InstallDir" -ForegroundColor Green
    Write-Host 'Look for the icon in the system tray (it may be hidden under ^).'
    Write-Host ''
    Write-Host 'Like it? Support the project:' -ForegroundColor Yellow
    Write-Host '  - Sponsor:     https://github.com/sponsors/BenKoncsik'
    Write-Host "  - Star it:     https://github.com/$Repo"
    Write-Host "  - Report bugs: https://github.com/$Repo/issues"
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

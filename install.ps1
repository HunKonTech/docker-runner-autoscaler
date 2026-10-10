# Docker Runner Autoscaler - installer
#
# One-liner (latest release):
#   irm https://github.com/HunKonTech/docker-runner-autoscaler/releases/latest/download/install.ps1 | iex
#
# From a local checkout (development):
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Source .
#
# Installs to %LOCALAPPDATA%\DockerRunnerAutoscaler, adds a Startup shortcut, registers it in
# Settings -> Apps -> Installed apps (uninstall from there) and starts the tray app.
# Re-running updates the app; .env, settings.json and docker-compose.yml are kept.
param(
    [string]$Version    = 'latest',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'DockerRunnerAutoscaler'),
    [string]$Repo       = 'HunKonTech/docker-runner-autoscaler',
    [string]$Source,                 # local repo folder instead of downloading
    [switch]$NoStart
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Step($t) { Write-Host ">> $t" -ForegroundColor Cyan }

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

    # 5. Startup shortcut
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

    # 6. Installed apps entry (child scope, so runner-lib does not touch this script's variables)
    Step 'Installed apps entry'
    & { . (Join-Path $appDir 'runner-lib.ps1'); Register-Uninstaller }

    # 7. Start
    if (-not $NoStart) {
        Step 'Starting tray app'
        Start-Process $lnk.TargetPath -ArgumentList $lnk.Arguments -WorkingDirectory $InstallDir -WindowStyle Hidden
    }
    Write-Host "Installed $(Get-Content (Join-Path $appDir 'VERSION')) -> $InstallDir" -ForegroundColor Green
    Write-Host 'Look for the icon in the system tray (it may be hidden under ^).'
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

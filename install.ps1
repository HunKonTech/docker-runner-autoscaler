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
# Language (asked on every interactive install, kept in settings.json): -Language en | hu | auto
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
    [ValidateSet('auto', 'en', 'hu')]
    [string]$Language,               # empty = ask (default: current setting or the Windows language)
    [switch]$NoStart
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Step($t) { Write-Host ">> $t" -ForegroundColor Cyan }

# Installer messages. Kept ASCII (\uXXXX escapes, decoded below) so they survive 'irm | iex'.
$Msg = @{
    en = @{
        Language       = 'Language / Nyelv'
        LangPick       = 'Choose / V\u00e1lassz'
        LocalSource    = 'Using local source: {0}'
        Downloading    = 'Downloading {0}'
        NoPackage      = 'Release package not found.'
        Checksum       = 'Checksum mismatch.'
        Stopping       = 'Stopping running instances'
        Installing     = 'Installing to {0}'
        EnvStep        = 'Configuration (.env)'
        AskOrg         = 'GitHub organization (ORG_NAME)'
        AskPat         = 'Fine-grained PAT (Self-hosted runners: Read and write)'
        EngineStep     = 'Docker engine'
        EngineDesktop  = 'Docker Desktop'
        EngineWsl      = 'Docker Engine inside WSL (no Docker Desktop)'
        EngineAsk      = 'Which one is installed on this machine? [1]'
        NoDistro       = 'No WSL distro found. Install one (wsl --install) with Docker Engine in it.'
        DistroDefault  = ' (default)'
        DistroAsk      = 'WSL distro running Docker [1]'
        DefaultDistro  = 'the default WSL distro'
        DockerFound    = 'Docker {0} in {1}'
        DockerNoAnswer = 'Docker did not answer in {0}. Install Docker Engine there and make sure the daemon starts (e.g. enable systemd).'
        Shortcut       = 'Startup shortcut'
        AppsEntry      = 'Installed apps entry'
        StartTray      = 'Starting tray app'
        Installed      = 'Installed {0} -> {1}'
        LookTray       = 'Look for the icon in the system tray (it may be hidden under ^).'
        LimitsHint     = 'Minimum / maximum runners and language: right-click the tray icon -> Settings.'
        Support        = 'Like it? Support the project:'
        Sponsor        = '  - Sponsor:     {0}'
        Star           = '  - Star it:     {0}'
        Bugs           = '  - Report bugs: {0}'
    }
    hu = @{
        Language       = 'Language / Nyelv'
        LangPick       = 'Choose / V\u00e1lassz'
        LocalSource    = 'Helyi forr\u00e1s: {0}'
        Downloading    = 'Let\u00f6lt\u00e9s: {0}'
        NoPackage      = 'A kiad\u00e1sban nincs telep\u00edt\u0151csomag.'
        Checksum       = 'Ellen\u0151rz\u0151\u00f6sszeg elt\u00e9r\u00e9s.'
        Stopping       = 'Fut\u00f3 p\u00e9ld\u00e1nyok le\u00e1ll\u00edt\u00e1sa'
        Installing     = 'Telep\u00edt\u00e9s ide: {0}'
        EnvStep        = 'Be\u00e1ll\u00edt\u00e1sok (.env)'
        AskOrg         = 'GitHub organization (ORG_NAME)'
        AskPat         = 'Fine-grained PAT (Self-hosted runners: Read and write jog)'
        EngineStep     = 'Docker motor'
        EngineDesktop  = 'Docker Desktop'
        EngineWsl      = 'Docker Engine WSL-ben (Docker Desktop n\u00e9lk\u00fcl)'
        EngineAsk      = 'Melyik van telep\u00edtve ezen a g\u00e9pen? [1]'
        NoDistro       = 'Nem tal\u00e1lhat\u00f3 WSL disztrib\u00faci\u00f3. Telep\u00edts egyet (wsl --install), benne Docker Engine-nel.'
        DistroDefault  = ' (alap\u00e9rtelmezett)'
        DistroAsk      = 'Melyik WSL disztrib\u00faci\u00f3ban fut a Docker? [1]'
        DefaultDistro  = 'az alap\u00e9rtelmezett WSL disztrib\u00faci\u00f3'
        DockerFound    = 'Docker {0}: {1}'
        DockerNoAnswer = 'A Docker nem v\u00e1laszolt: {0}. Telep\u00edtsd ott a Docker Engine-t, \u00e9s gondoskodj r\u00f3la, hogy a daemon elinduljon (pl. systemd bekapcsol\u00e1s\u00e1val).'
        Shortcut       = 'Ind\u00edt\u00e1si parancsikon'
        AppsEntry      = 'Bejegyz\u00e9s a telep\u00edtett alkalmaz\u00e1sok k\u00f6z\u00e9'
        StartTray      = 'T\u00e1lcaalkalmaz\u00e1s ind\u00edt\u00e1sa'
        Installed      = 'Telep\u00edtve: {0} -> {1}'
        LookTray       = 'Keresd az ikont a t\u00e1lc\u00e1n (lehet, hogy a ^ alatt van elrejtve).'
        LimitsHint     = 'Minimum / maximum runner \u00e9s nyelv: jobb klikk a t\u00e1lcaikonon -> Be\u00e1ll\u00edt\u00e1sok.'
        Support        = 'Tetszik? T\u00e1mogasd a projektet:'
        Sponsor        = '  - T\u00e1mogat\u00e1s:   {0}'
        Star           = '  - Csillag:     {0}'
        Bugs           = '  - Hibajelent\u00e9s: {0}'
    }
}
foreach ($t in $Msg.Values) { foreach ($k in @($t.Keys)) { $t[$k] = [regex]::Unescape($t[$k]) } }
$script:InstLang = 'en'

# M 'Key' arg1 arg2 ...  -> message in the installer language
function M([string]$Key) {
    $fmt = $Msg[$script:InstLang][$Key]
    if ($args.Count) { $fmt -f $args } else { $fmt }
}

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

# 0. Language (installer + app)
$settingsFile = Join-Path $InstallDir 'settings.json'
$curLang = $null
if (Test-Path $settingsFile) { try { $curLang = (Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json).Language } catch { } }
$winLang = if ((Get-Culture).TwoLetterISOLanguageName -eq 'hu') { 'hu' } else { 'en' }
if (-not $Language) {
    $def = if ($curLang -in 'en', 'hu') { $curLang } else { $winLang }
    Step (M 'Language')
    Write-Host '  1) English'
    Write-Host '  2) Magyar'
    $defNum = if ($def -eq 'hu') { 2 } else { 1 }
    $pick = (Read-Host "$(M 'LangPick') [$defNum]").Trim()
    $Language = switch ($pick) { '1' { 'en' } '2' { 'hu' } default { $def } }
}
$script:InstLang = if ($Language -eq 'auto') { $winLang } else { $Language }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("dra-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # 1. Package
    if ($Source) {
        Step (M 'LocalSource' $Source)
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
        Step (M 'Downloading' $rel.tag_name)
        $zipAsset = $rel.assets | Where-Object { $_.name -like 'docker-runner-autoscaler-*.zip' } | Select-Object -First 1
        $shaAsset = $rel.assets | Where-Object { $_.name -eq "$($zipAsset.name).sha256" } | Select-Object -First 1
        if (-not $zipAsset -or -not $shaAsset) { throw (M 'NoPackage') }
        $zip = Join-Path $tmp $zipAsset.name
        Invoke-WebRequest $zipAsset.browser_download_url -OutFile $zip -Headers $headers -UseBasicParsing
        $sha = Join-Path $tmp 'sha256'
        Invoke-WebRequest $shaAsset.browser_download_url -OutFile $sha -Headers $headers -UseBasicParsing
        $expected = (Get-Content $sha -Raw).Trim().Split(' ')[0].ToUpper()
        if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $expected) { throw (M 'Checksum') }
        $pkg = Join-Path $tmp 'pkg'
        Expand-Archive $zip -DestinationPath $pkg
    }

    # 2. Stop running instances
    Step (M 'Stopping')
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -match 'runner-(autoscale|tray)\.ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    # 3. Copy files
    Step (M 'Installing' $InstallDir)
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
        Step (M 'EnvStep')
        $org = Read-Host (M 'AskOrg')
        $tok = Read-Host (M 'AskPat') -AsSecureString
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($tok))
        $content = (Get-Content (Join-Path $InstallDir '.env.example') -Raw) `
            -replace '(?m)^GH_PAT=.*$', "GH_PAT=$plain" -replace '(?m)^ORG_NAME=.*$', "ORG_NAME=$org"
        [IO.File]::WriteAllText($envFile, $content)
    }

    # 5. Docker engine, language (settings.json)
    $cfg = if (Test-Path $settingsFile) { Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json }
           else { Get-Content (Join-Path $InstallDir 'settings.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
    $engine = if ($DockerEngine) { $DockerEngine } elseif ((Test-Path $settingsFile) -and $cfg.DockerEngine) { $cfg.DockerEngine } else { $null }
    $distro = if ($PSBoundParameters.ContainsKey('WslDistro')) { $WslDistro } else { $cfg.WslDistro }
    if (-not $engine) {
        Step (M 'EngineStep')
        Write-Host "  1) $(M 'EngineDesktop')"
        Write-Host "  2) $(M 'EngineWsl')"
        $engine = if ((Read-Host (M 'EngineAsk')).Trim() -eq '2') { 'wsl' } else { 'desktop' }
        if ($engine -eq 'wsl' -and -not $PSBoundParameters.ContainsKey('WslDistro')) {
            $distros = Get-WslDistros
            if ($distros.Count -eq 0) { Write-Warning (M 'NoDistro') }
            for ($i = 0; $i -lt $distros.Count; $i++) {
                $mark = if ($distros[$i].Default) { M 'DistroDefault' } else { '' }
                Write-Host "  $($i + 1)) $($distros[$i].Name)$mark"
            }
            $pick = (Read-Host (M 'DistroAsk')).Trim()
            $n = 0
            $distro = if (-not $pick -and $distros.Count) { $distros[0].Name }
                      elseif ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $distros.Count) { $distros[$n - 1].Name }
                      else { $pick }
        }
    }
    if ($engine -ne 'wsl') { $distro = '' }
    $cfg | Add-Member -NotePropertyName DockerEngine -NotePropertyValue $engine -Force
    $cfg | Add-Member -NotePropertyName WslDistro -NotePropertyValue ([string]$distro) -Force
    $cfg | Add-Member -NotePropertyName Language -NotePropertyValue $Language -Force
    # MaxRunners 50 was the old default: switch to 0 = the recommended count (from CPU / RAM)
    if ($null -eq $cfg.MaxRunners -or [int]$cfg.MaxRunners -eq 50) { $cfg | Add-Member -NotePropertyName MaxRunners -NotePropertyValue 0 -Force }
    if ($null -eq $cfg.MinRunners) { $cfg | Add-Member -NotePropertyName MinRunners -NotePropertyValue 1 -Force }
    [IO.File]::WriteAllText($settingsFile, ($cfg | ConvertTo-Json))
    if ($engine -eq 'wsl') {
        $wslArgs = @(if ($distro) { '-d', $distro }) + '-e'
        $v = @(wsl.exe @wslArgs docker version --format '{{.Server.Version}}' 2>$null) | Select-Object -First 1
        $where = if ($distro) { $distro } else { M 'DefaultDistro' }
        if ($LASTEXITCODE -eq 0 -and $v) { Write-Host "  $(M 'DockerFound' "$v".Trim() $where)" }
        else { Write-Warning (M 'DockerNoAnswer' $where) }
    }

    # 6. Startup shortcut
    Step (M 'Shortcut')
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
    Step (M 'AppsEntry')
    & { . (Join-Path $appDir 'runner-lib.ps1'); Register-Uninstaller }

    # 8. Start
    if (-not $NoStart) {
        Step (M 'StartTray')
        Start-Process $lnk.TargetPath -ArgumentList $lnk.Arguments -WorkingDirectory $InstallDir -WindowStyle Hidden
    }
    Write-Host (M 'Installed' (Get-Content (Join-Path $appDir 'VERSION')) $InstallDir) -ForegroundColor Green
    Write-Host (M 'LookTray')
    Write-Host (M 'LimitsHint')
    Write-Host ''
    Write-Host (M 'Support') -ForegroundColor Yellow
    Write-Host (M 'Sponsor' 'https://github.com/sponsors/BenKoncsik')
    Write-Host (M 'Star' "https://github.com/$Repo")
    Write-Host (M 'Bugs' "https://github.com/$Repo/issues")
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

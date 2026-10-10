# Uninstalls Docker Runner Autoscaler
#   -Interactive : ask before each step (Windows "Installed apps" and the tray menu use this)
#   -StopRunners : also stop and remove the runner containers (docker compose down) and the offline runners on GitHub
#   -Purge       : also delete the configuration (.env, settings.json, docker-compose.yml), i.e. the whole install folder
# Without -Purge the program files (app\, state\) are removed and the configuration is kept.
param([switch]$Interactive, [switch]$StopRunners, [switch]$Purge)

. (Join-Path $PSScriptRoot 'runner-lib.ps1')

function Read-YesNo([string]$question, [bool]$default) {
    $q = if ($default) { T 'UnPromptYes' $question } else { T 'UnPromptNo' $question }
    $a = (Read-Host $q).Trim().ToLower()
    if (-not $a) { return $default }
    $a -match '^(y|yes|i|igen)$'
}

function Exit-Uninstall([int]$code) {
    if ($Interactive) { [void](Read-Host (T 'UnPressEnter')) }
    exit $code
}

if ($Interactive) {
    $Host.UI.RawUI.WindowTitle = T 'UnTitle'
    if (-not (Read-YesNo (T 'UnConfirm') $false)) { Write-Host (T 'UnCancelled'); Exit-Uninstall 1 }
    if ($ComposeDir) { $StopRunners = Read-YesNo (T 'UnAskStop') $true }
    if (Test-InstalledLayout) { $Purge = Read-YesNo (T 'UnAskPurge') $false }
}

Stop-AppProcesses @('runner-autoscale.ps1', 'runner-tray.ps1', 'scale-runners.ps1')

$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Docker Runner Autoscaler.lnk'
if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host (T 'UnRemoved' $lnk) }
Unregister-Uninstaller

if ($StopRunners -and $ComposeDir) {
    Write-Host (T 'UnStopping')
    docker compose --project-directory $ComposeDir down --remove-orphans
    # runners deregister themselves on stop; remove the ones that could not (needs .env)
    $eap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'
        & (Join-Path $AppDir 'cleanup-runners.ps1')
    } catch {
        Write-Warning (T 'UnCleanupFailed' $_.Exception.Message)
    } finally {
        $ErrorActionPreference = $eap
    }
}

# Files are removed only from an installed layout (<home>\app), never from a repository checkout
if (Test-InstalledLayout) {
    Set-Location $env:TEMP
    $targets = if ($Purge) { @($HomeDir) } else { @($AppDir, $StateDir) }
    foreach ($t in $targets) {
        if (Test-Path $t) { Remove-Item $t -Recurse -Force; Write-Host (T 'UnRemoved' $t) }
    }
    if (-not $Purge) { Write-Host (T 'UnKept' $HomeDir) }
}
Write-Host (T 'UnDone') -ForegroundColor Green
Exit-Uninstall 0

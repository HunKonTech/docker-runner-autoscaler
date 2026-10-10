# Uninstalls Docker Runner Autoscaler
#   -StopRunners : also stop and remove the runner containers (docker compose down)
#   -Purge       : also delete the install folder (including .env and settings)
param([switch]$StopRunners, [switch]$Purge)

. (Join-Path $PSScriptRoot 'runner-lib.ps1')

Stop-AppProcesses @('runner-autoscale.ps1', 'runner-tray.ps1', 'scale-runners.ps1')

$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Docker Runner Autoscaler.lnk'
if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "Removed: $lnk" }

if ($StopRunners -and $ComposeDir) {
    docker compose --project-directory $ComposeDir down
}

if ($Purge) {
    Set-Location $env:TEMP
    Remove-Item $HomeDir -Recurse -Force
    Write-Host "Removed: $HomeDir"
}
Write-Host 'Uninstalled.'

# Removes offline runners (matching RUNNER_NAME_PREFIX) from the GitHub organization / repository.
# Reads GH_PAT, RUNNER_SCOPE, ORG_NAME, REPO_URL, RUNNER_NAME_PREFIX from <home>\.env
# Usage: powershell -ExecutionPolicy Bypass -File cleanup-runners.ps1

. (Join-Path $PSScriptRoot 'runner-lib.ps1')
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$envFile = Join-Path $HomeDir '.env'
$cfg = @{}
foreach ($l in Get-Content $envFile) {
    if ($l -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') { $cfg[$Matches[1]] = $Matches[2].Trim('"') }
}
if (-not $cfg.GH_PAT) { throw "GH_PAT missing in $envFile" }

$prefix = if ($cfg.RUNNER_NAME_PREFIX) { $cfg.RUNNER_NAME_PREFIX } else { 'dd' }
$base = if ($cfg.RUNNER_SCOPE -eq 'repo') {
    $repo = $cfg.REPO_URL -replace '^https://github\.com/', '' -replace '/$', ''
    "https://api.github.com/repos/$repo/actions/runners"
} else {
    "https://api.github.com/orgs/$($cfg.ORG_NAME)/actions/runners"
}

$h = @{ Authorization = "Bearer $($cfg.GH_PAT)"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'docker-runner-autoscaler' }
$url = "$base`?per_page=100"
$deleted = 0
do {
    $resp = Invoke-WebRequest $url -Headers $h -UseBasicParsing
    ($resp.Content | ConvertFrom-Json).runners |
        Where-Object { $_.name -like "$prefix-*" -and $_.status -eq 'offline' } |
        ForEach-Object {
            Invoke-RestMethod -Method Delete "$base/$($_.id)" -Headers $h | Out-Null
            Write-Output "Removed: $($_.name)"
            $deleted++
        }
    $url = $null
    if ($resp.Headers['Link'] -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1] }
} while ($url)
Write-Output "Done. Removed runners: $deleted"

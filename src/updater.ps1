# Self-update from GitHub Releases
# A release must contain:  docker-runner-autoscaler-<version>.zip  and  <same>.zip.sha256
# Only the app folder is replaced; docker-compose.yml, .env, settings.json and state\ are kept.

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function ConvertTo-SemVer([string]$v) {
    $v = $v.Trim().TrimStart('v') -replace '-.*$', ''
    try { [version]$v } catch { [version]'0.0.0' }
}

function Get-LatestRelease {
    $headers = @{ 'User-Agent' = 'docker-runner-autoscaler'; Accept = 'application/vnd.github+json' }
    Invoke-RestMethod -Uri "https://api.github.com/repos/$($Settings.UpdateRepo)/releases/latest" -Headers $headers -TimeoutSec 20
}

# Returns the release object if newer than the installed version, otherwise $null
function Find-Update {
    $rel = Get-LatestRelease
    if ((ConvertTo-SemVer $rel.tag_name) -gt (ConvertTo-SemVer (Get-AppVersion))) { $rel } else { $null }
}

# Downloads, verifies and installs the release into $AppDir
function Install-Update($rel) {
    $zipAsset = $rel.assets | Where-Object { $_.name -like 'docker-runner-autoscaler-*.zip' } | Select-Object -First 1
    $shaAsset = $rel.assets | Where-Object { $_.name -eq "$($zipAsset.name).sha256" } | Select-Object -First 1
    if (-not $zipAsset -or -not $shaAsset) { throw (T 'UpdNoAsset') }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dra-update-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp $zipAsset.name
        $headers = @{ 'User-Agent' = 'docker-runner-autoscaler' }
        Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile $zip -Headers $headers -UseBasicParsing
        $expected = ((Invoke-WebRequest -Uri $shaAsset.browser_download_url -Headers $headers -UseBasicParsing).Content |
                     ForEach-Object { if ($_ -is [byte[]]) { [Text.Encoding]::UTF8.GetString($_) } else { $_ } }).Trim().Split(' ')[0]
        $actual = (Get-FileHash -Algorithm SHA256 $zip).Hash
        if ($actual -ne $expected.ToUpper()) { throw (T 'UpdChecksum') }

        $ex = Join-Path $tmp 'x'
        Expand-Archive -Path $zip -DestinationPath $ex -Force
        $newApp = Join-Path $ex 'app'
        if (-not (Test-Path (Join-Path $newApp 'runner-lib.ps1'))) { throw (T 'UpdNoAsset') }

        Copy-Item -Path (Join-Path $newApp '*') -Destination $AppDir -Recurse -Force
        # Ship the new defaults next to the user's files without overwriting them
        foreach ($f in 'docker-compose.yml', '.env.example', 'settings.example.json') {
            $src = Join-Path $ex $f
            if (Test-Path $src) {
                $dst = Join-Path $HomeDir $f
                if ($f -eq 'docker-compose.yml' -and (Test-Path $dst)) { $dst = "$dst.new" }
                Copy-Item $src $dst -Force
            }
        }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

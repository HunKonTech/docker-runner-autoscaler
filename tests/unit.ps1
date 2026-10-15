# Unit tests without Docker: settings, i18n, control/status files, version compare
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$env:DRA_HOME = Join-Path ([IO.Path]::GetTempPath()) ("dra-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $env:DRA_HOME | Out-Null
Copy-Item (Join-Path $repo 'docker-compose.yml') $env:DRA_HOME
'{ "Language": "hu", "MinRunners": 2, "MaxRunners": 10 }' | Set-Content (Join-Path $env:DRA_HOME 'settings.json') -Encoding UTF8

$script:fail = 0
function Assert($cond, $name) {
    if ($cond) { Write-Host "PASS $name" } else { Write-Host "FAIL $name" -ForegroundColor Red; $script:fail++ }
}

try {
    . (Join-Path $repo 'src\runner-lib.ps1')
    . (Join-Path $repo 'src\updater.ps1')

    Assert ($MinRunners -eq 2 -and $Max -eq 10) 'settings.json overrides defaults'
    Assert ($Settings.PollSec -eq 10) 'defaults kept for missing keys'
    Assert ($script:Lang -eq 'hu') 'language from settings'
    Assert ((T 'MsgManual' 5) -eq 'Kézi mód, cél: 5') 'hu translation + format'
    Set-Language 'en'
    Assert ((T 'MsgManual' 5) -eq 'Manual mode, target: 5') 'en translation'
    Assert ((T 'NoSuchKey') -eq 'NoSuchKey') 'missing key falls back to key'
    foreach ($k in @($script:Strings['en'].get_Keys())) { if (-not $script:Strings['hu'].ContainsKey($k)) { Assert $false "hu has key $k" } }
    Assert ($script:Strings.hu.Count -eq $script:Strings.en.Count) 'en/hu key sets match'

    Assert ($ComposeDir -eq $env:DRA_HOME) 'compose dir resolved from DRA_HOME'
    Assert (-not (Test-InstalledLayout)) 'repository checkout is not an installed layout'

    Set-RunnerControl 'manual' 7
    $c = Get-RunnerControl
    Assert ($c.Mode -eq 'manual' -and $c.Target -eq 7) 'control file round-trip'
    Set-RunnerControl 'auto' 999
    Assert ((Get-RunnerControl).Target -eq $Max) 'target clamped to MaxRunners'
    Assert (-not ([IO.File]::ReadAllText($ControlFile).Contains("`r"))) 'control file uses LF'

    # runner limits: 1 runner per CPU thread, GbPerRunner (2) GB each
    Assert ((Get-IdealRunners 8 32) -eq 8) 'ideal limited by CPU'
    Assert ((Get-IdealRunners 16 12) -eq 6) 'ideal limited by RAM'
    Assert ((Get-IdealRunners 4 1) -eq 1) 'ideal is at least 1'
    $lim = Get-RunnerLimits 6
    Assert ($lim.Min -eq 2 -and $lim.Max -eq 10) 'explicit min / max'
    $st0 = [pscustomobject]@{ ideal = 6; cpu = 8; mem_gb = 12 }
    Assert ((Get-StatusRecommended $st0).Ideal -eq 6) 'recommendation from status'
    Assert ((Get-StatusRecommended $null).Ideal -ge 1) 'local recommendation without status'

    Save-Settings @{ MinRunners = 3; MaxRunners = 0; Language = 'en' }
    Assert ($MinRunners -eq 3 -and $Max -eq 0 -and $script:Lang -eq 'en') 'Save-Settings reloads'
    $saved = Get-Content -Raw (Join-Path $env:DRA_HOME 'settings.json') | ConvertFrom-Json
    Assert ($saved.MinRunners -eq 3 -and $saved.Language -eq 'en') 'Save-Settings writes settings.json'
    $lim = Get-RunnerLimits 6
    Assert ($lim.Min -eq 3 -and $lim.Max -eq 6) 'MaxRunners 0 = recommended'
    Assert ((Get-RunnerLimits 2).Min -eq 2) 'min never above max'
    Assert (-not (Update-Settings)) 'no reload when settings.json is unchanged'
    '{ "MinRunners": 1, "Language": "hu" }' | Set-Content (Join-Path $env:DRA_HOME 'settings.json') -Encoding UTF8
    (Get-Item (Join-Path $env:DRA_HOME 'settings.json')).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(1)
    Assert ((Update-Settings) -and $MinRunners -eq 1 -and $script:Lang -eq 'hu') 'reload when settings.json changes'
    Set-RunnerControl 'manual' 999
    Assert ((Get-RunnerControl).Target -eq 999) 'no clamp when MaxRunners is 0 (autoscaler clamps)'

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Write-RunnerStatus ([ordered]@{ updated = $now - 5; scale_down_in = 60; last_action = 'Kézi árvíztűrő' })
    $st = Get-RunnerStatus
    Assert ($st.last_action -eq 'Kézi árvíztűrő') 'status file UTF-8 round-trip'
    $left = Get-ScaleDownLeft $st
    Assert ($left -ge 54 -and $left -le 55) 'scale-down countdown'

    Assert ((ConvertTo-SemVer 'v1.2.10') -gt (ConvertTo-SemVer '1.2.9')) 'semver compare'
    Assert ((ConvertTo-SemVer '0.0.0-dev') -lt (ConvertTo-SemVer 'v1.0.1')) 'dev version is older'

    $shaFile = Join-Path $env:DRA_HOME 'test.sha256'
    [IO.File]::WriteAllText($shaFile, "532b9b16abc  docker-runner-autoscaler-1.0.2.zip`n")
    Assert ((Read-Sha256File $shaFile) -ceq '532B9B16ABC') 'sha256 file parsed'
} finally {
    Remove-Item $env:DRA_HOME -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:fail) { Write-Host "$script:fail test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green

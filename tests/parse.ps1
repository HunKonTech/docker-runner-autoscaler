# Parses every .ps1 in the repository and fails on syntax errors
$failed = $false
Get-ChildItem (Split-Path $PSScriptRoot -Parent) -Recurse -Filter *.ps1 | ForEach-Object {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors) {
        $failed = $true
        $errors | ForEach-Object { Write-Host "$($_.Extent.File):$($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
    } else {
        Write-Host "OK  $($_.Name)"
    }
}
if ($failed) { exit 1 }

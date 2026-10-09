# Publishes a release on the public repo: the one-file setup, its SHA-256 (which every setup
# checks before running a newer one it downloaded) and the zip with the README and licences.
# Build first: tools\build_release.ps1 -Version <version>.
# Usage: powershell -ExecutionPolicy Bypass -File tools\publish_release.ps1 -Version 0.4.0 [-Notes "..."]

param([Parameter(Mandatory = $true)][string]$Version, [string]$Notes = "")
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root "dist"
$setup = Join-Path $dist "WandsongSetup-$Version.exe"
$zip = Join-Path $dist "Wandsong-$Version.zip"
foreach ($f in $setup, $zip) { if (-not (Test-Path $f)) { throw "Missing ${f}: run tools\build_release.ps1 -Version $Version first." } }

$hash = (Get-FileHash -Algorithm SHA256 $setup).Hash.ToLower()
$sum = "$setup.sha256"
[System.IO.File]::WriteAllText($sum, "$hash  WandsongSetup-$Version.exe")   # (Set-Content wrote nothing here)
if (-not (Test-Path $sum)) { throw "Couldn't write $sum" }

if (-not $Notes) {
    $Notes = "Download WandsongSetup-$Version.exe and run it with Hogwarts Legacy closed. It finds the game, " +
             "says what's installed, and Enter installs or updates Wandsong. Setups from now on check here " +
             "for newer versions themselves."
}
& gh release create "v$Version" $setup $sum $zip -R matalvernaz/wandsong --title "Wandsong $Version" --notes $Notes
if ($LASTEXITCODE -ne 0) { throw "Publishing failed." }
Write-Output "Published Wandsong $Version (sha256 $hash)"

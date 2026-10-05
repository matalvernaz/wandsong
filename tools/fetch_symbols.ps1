# Dev helper: fetch UE4SS.pdb for crash forensics into symbols\ (gitignored).
# The zDEV release's UE4SS.dll is byte-identical to the normal v3.0.1 release, so its PDB
# matches the DLL the game runs. Then: python tools\symbolize_crash.py symbols
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$sym = Join-Path $root "symbols"
New-Item -ItemType Directory -Force $sym | Out-Null
$zip = Join-Path $sym "zDEV-UE4SS_v3.0.1.zip"
if (-not (Test-Path $zip)) {
    gh release download v3.0.1 -R UE4SS-RE/RE-UE4SS -p "zDEV-UE4SS_v3.0.1.zip" -D $sym --clobber
}
$tmp = Join-Path $sym "x"
Expand-Archive $zip -DestinationPath $tmp -Force
Copy-Item (Join-Path $tmp "UE4SS.dll"), (Join-Path $tmp "UE4SS.pdb") $sym -Force
Remove-Item -Recurse -Force $tmp
Write-Host "symbols ready in $sym (needs LLVM's llvm-symbolizer: winget install LLVM.LLVM)"

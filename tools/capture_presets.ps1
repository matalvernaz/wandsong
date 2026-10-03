# Dev helper: select each character-creator preset through the mod and photograph the
# character's head, composing them into one contact sheet for writing descriptions.
# Run with the Presets tab open. It checks that every step really landed on "Preset N"
# before pressing anything, and stops otherwise (so it can never press "Start Game").
# Usage: capture_presets.ps1 -Start 19 -End 30 -Out sheet.png
param([int]$Start = 1, [int]$End = 30, [string]$Out = "presets.png")

Add-Type @'
using System; using System.Runtime.InteropServices;
public class Cap { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
'@
[void][Cap]::SetProcessDPIAware()
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$keys = Join-Path $PSScriptRoot "sendkeys.ps1"
$log = "C:\Program Files (x86)\Steam\steamapps\common\Hogwarts Legacy\Phoenix\Binaries\Win64\UE4SS.log"
function Last-Say { ((Select-String -Path $log -Pattern '\[Wandsong\] say ' -Encoding UTF8 | Select-Object -Last 1).Line -replace '^.*\] say\+? ', '') }

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$crop = New-Object Drawing.Rectangle ([int]($screen.Width * 0.66)), ([int]($screen.Height * 0.13)), ([int]($screen.Width * 0.14)), ([int]($screen.Height * 0.30))
$count = $End - $Start + 1
$cellW = 200; $cellH = [int](200 * $crop.Height / $crop.Width); $cols = 6
$sheet = New-Object Drawing.Bitmap ($cellW * $cols), (($cellH + 24) * [Math]::Ceiling($count / $cols))
$sg = [Drawing.Graphics]::FromImage($sheet); $sg.Clear([Drawing.Color]::Black)
$font = New-Object Drawing.Font "Arial", 14

# Walk to the first wanted preset, one step at a time, checking what was said.
& $keys -Keys "ctrl+lbr" -DelayMs 600 | Out-Null
for ($guard = 0; $guard -lt 60; $guard++) {
    $said = Last-Say
    if ($said -like "Preset $Start of *") { break }
    & $keys -Keys "rbr" -DelayMs 350 | Out-Null
}

for ($n = $Start; $n -le $End; $n++) {
    $said = Last-Say
    if ($said -notlike "Preset $n of *") { "stopped: expected Preset $n, heard '$said'"; break }
    & $keys -Keys "bslash" -DelayMs 1800 | Out-Null
    $shot = New-Object Drawing.Bitmap $crop.Width, $crop.Height
    $g = [Drawing.Graphics]::FromImage($shot)
    $g.CopyFromScreen($crop.Location, [Drawing.Point]::Empty, $crop.Size)
    $i = $n - $Start
    $x = ($i % $cols) * $cellW; $y = [Math]::Floor($i / $cols) * ($cellH + 24)
    $sg.DrawImage($shot, $x, $y + 24, $cellW, $cellH)
    $sg.DrawString("$n", $font, [Drawing.Brushes]::Yellow, $x + 4, $y + 2)
    $g.Dispose(); $shot.Dispose()
    if ($n -lt $End) { & $keys -Keys "rbr" -DelayMs 500 | Out-Null }
}
$sheet.Save($Out, [Drawing.Imaging.ImageFormat]::Png)
"saved $Out"

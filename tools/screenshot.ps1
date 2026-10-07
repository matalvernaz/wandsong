# Dev helper: save a screenshot of the Hogwarts Legacy window (for Claude to look at while
# testing). Usage: screenshot.ps1 [-Out path.png] [-Width 1280]
param([string]$Out = "$env:TEMP\hl_shot.png", [int]$Width = 1280)
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public class HaShot {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
[void][HaShot]::SetProcessDPIAware()
$p = Get-Process HogwartsLegacy -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 1
if (-not $p) { Write-Output "Hogwarts Legacy is not running."; exit 1 }
$r = New-Object HaShot+RECT
[void][HaShot]::GetWindowRect($p.MainWindowHandle, [ref]$r)
$w = $r.R - $r.L; $h = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
if ($w -gt $Width) {
    $nh = [int]($h * $Width / $w)
    $small = New-Object System.Drawing.Bitmap $bmp, $Width, $nh
    $bmp.Dispose(); $bmp = $small
}
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Output $Out

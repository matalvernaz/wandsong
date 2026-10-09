# Dev helper: save a screenshot of the Hogwarts Legacy window (for Claude to look at while
# testing). Usage: screenshot.ps1 [-Out path.jpg] [-Width 960] [-Quality 70]
# JPEG, small: a tool result over 1 MiB (a big PNG) once killed the claude-web session.
param([string]$Out = "$env:TEMP\hl_shot.jpg", [int]$Width = 960, [int]$Quality = 70)
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public class WsShot {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
[void][WsShot]::SetProcessDPIAware()
$p = Get-Process HogwartsLegacy -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 1
if (-not $p) { Write-Output "Hogwarts Legacy is not running."; exit 1 }
$r = New-Object WsShot+RECT
[void][WsShot]::GetWindowRect($p.MainWindowHandle, [ref]$r)
$w = $r.R - $r.L; $h = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
if ($w -gt $Width) {
    $nh = [int]($h * $Width / $w)
    $small = New-Object System.Drawing.Bitmap $bmp, $Width, $nh
    $bmp.Dispose(); $bmp = $small
}
$codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" }
$params = New-Object System.Drawing.Imaging.EncoderParameters 1
$params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), ([long]$Quality)
$bmp.Save($Out, $codec, $params)
$g.Dispose(); $bmp.Dispose()
Write-Output $Out

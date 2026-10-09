# Dev helper: move the mouse by relative steps in Hogwarts Legacy (what the game reads for
# camera and minigame cursors). Usage: mouse.ps1 -Dx 50 -Dy -20 [-Steps 10] [-DelayMs 10]
# Aborts without moving if the game isn't the foreground window.
param([int]$Dx = 0, [int]$Dy = 0, [int]$Steps = 10, [int]$DelayMs = 10)
Add-Type @'
using System; using System.Runtime.InteropServices;
public class WsMouse {
 [StructLayout(LayoutKind.Sequential)] public struct MI { public int dx, dy; public uint data, flags, time; public UIntPtr extra; }
 [StructLayout(LayoutKind.Sequential)] public struct IN { public uint type; public uint pad; public MI mi; }
 [DllImport("user32.dll")] public static extern uint SendInput(uint n, IN[] i, int size);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 public static void Move(int dx, int dy){ var a=new IN[1]; a[0].type=0; a[0].mi.dx=dx; a[0].mi.dy=dy; a[0].mi.flags=1; SendInput(1,a,Marshal.SizeOf(typeof(IN))); }
}
'@
$p = Get-Process HogwartsLegacy -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 1
if (-not $p) { Write-Output "Hogwarts Legacy is not running."; exit 1 }
if ([WsMouse]::GetForegroundWindow() -ne $p.MainWindowHandle) { Write-Output "ABORT: Hogwarts Legacy is not in front"; exit 2 }
for ($i = 0; $i -lt $Steps; $i++) {
    [WsMouse]::Move([int]($Dx / $Steps), [int]($Dy / $Steps))
    Start-Sleep -Milliseconds $DelayMs
}

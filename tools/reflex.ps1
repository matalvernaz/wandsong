# Dev helper for playing fights from the tools, where each drive.ps1 call takes seconds: watches
# the mod's log and presses the block key when the mod calls "Protego" (or an incoming attack),
# and the dodge key when it calls "Dodge" (or an unblockable attack), within about 100 ms.
# Never takes focus: a key goes out only while the game is the window in front.
#   powershell -ExecutionPolicy Bypass -File tools\reflex.ps1 [-Seconds 300] [-Block 0x51] [-Dodge 0xA2]
# Block and Dodge are virtual-key codes (Q and Left Control by default, the game's defaults).
param([int]$Seconds = 300, [int]$Block = 0x51, [int]$Dodge = 0xA2)

Add-Type @'
using System; using System.Runtime.InteropServices;
public class HaReflex {
 [StructLayout(LayoutKind.Sequential)] public struct KI { public ushort vk, scan; public uint flags, time; public UIntPtr extra; public long padA; }
 [StructLayout(LayoutKind.Sequential)] public struct IN { public uint type; public uint pad; public KI ki; }
 [DllImport("user32.dll")] public static extern uint SendInput(uint n, IN[] i, int size);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
 public static void Key(ushort vk, bool up){
  var a=new IN[1]; a[0].type=1;
  uint scan=MapVirtualKey(vk,4);
  a[0].ki.vk=vk; a[0].ki.scan=(ushort)(scan & 0xff);
  a[0].ki.flags=(uint)((((scan & 0xff00)==0xe000)?1:0)|(up?2:0));
  SendInput(1,a,Marshal.SizeOf(typeof(IN)));
 }
}
'@

$p = Get-Process HogwartsLegacy -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 1
if (-not $p) { Write-Output "Hogwarts Legacy is not running."; exit 1 }
$hwnd = $p.MainWindowHandle
$log = Join-Path (Split-Path $p.Path) "Mods\Wandsong\Wandsong.log"
$fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
[void]$fs.Seek(0, 'End')
$reader = New-Object IO.StreamReader($fs)

function Press([int]$vk, [string]$why) {
    if ([HaReflex]::GetForegroundWindow() -ne $hwnd) { Write-Output "$(Get-Date -Format HH:mm:ss.fff) skipped ($why): the game isn't in front"; return }
    [HaReflex]::Key([uint16]$vk, $false); Start-Sleep -Milliseconds 120; [HaReflex]::Key([uint16]$vk, $true)
    Write-Output "$(Get-Date -Format HH:mm:ss.fff) pressed $why"
}

$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
    $line = $reader.ReadLine()
    if ($null -eq $line) { Start-Sleep -Milliseconds 25; continue }
    if ($line -match 'callout: Protego|Incoming attack\. Block') { Press $Block "block" }
    elseif ($line -match 'callout: Dodge|Unblockable attack') { Press $Dodge "dodge" }
}
$reader.Close()

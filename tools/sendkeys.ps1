# Dev helper: focus Hogwarts Legacy and send keys as real input events.
# Usage: sendkeys.ps1 -Keys "ctrl+rbr","bslash" [-DelayMs 700]
# Key names: num0-num9, space, esc, enter, up/down/left/right, f, r, lbr ([), rbr (]),
# bslash (\), quote ('), semi (;), minus, equals, pageup/pagedown/home/end, grave (`), comma, period,
# slash, f1-f12; prefix ctrl+ or shift+. Suffix @ms holds the key that long ("space@2500").
param([string[]]$Keys, [int]$DelayMs = 700)

Add-Type @'
using System; using System.Runtime.InteropServices;
public class HaKeys {
 [StructLayout(LayoutKind.Sequential)] public struct KI { public ushort vk, scan; public uint flags, time; public UIntPtr extra; public long padA; }
 [StructLayout(LayoutKind.Sequential)] public struct IN { public uint type; public uint pad; public KI ki; }
 [DllImport("user32.dll")] public static extern uint SendInput(uint n, IN[] i, int size);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
 [DllImport("user32.dll")] public static extern void keybd_event(byte v,byte s,uint f,UIntPtr e);
 [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
 public static void Key(ushort vk, bool ext, bool up){ var a=new IN[1]; a[0].type=1; a[0].ki.vk=vk; a[0].ki.scan=(ushort)MapVirtualKey(vk,0); a[0].ki.flags=(uint)((ext?1:0)|(up?2:0)); SendInput(1,a,Marshal.SizeOf(typeof(IN))); }
}
'@

$map = @{
    'num0'=0x60; 'num1'=0x61; 'num2'=0x62; 'num3'=0x63; 'num4'=0x64; 'num5'=0x65
    'num6'=0x66; 'num7'=0x67; 'num8'=0x68; 'num9'=0x69; 'space'=0x20; 'esc'=0x1B
    'lbr'=0xDB; 'rbr'=0xDD; 'bslash'=0xDC; 'quote'=0xDE; 'semi'=0xBA; 'minus'=0xBD; 'equals'=0xBB
    'up'=0x26; 'down'=0x28; 'left'=0x25; 'right'=0x27; 'enter'=0x0D; 'f'=0x46; 'r'=0x52; 'f9'=0x78; 'f11'=0x7A; 'q'=0x51; 'e'=0x45
    'pageup'=0x21; 'pagedown'=0x22; 'end'=0x23; 'home'=0x24; 'insert'=0x2D; 'delete'=0x2E; 'tab'=0x09
    'grave'=0xC0; 'comma'=0xBC; 'period'=0xBE; 'slash'=0xBF
    'f1'=0x70; 'f2'=0x71; 'f3'=0x72; 'f4'=0x73; 'f5'=0x74; 'f6'=0x75; 'f7'=0x76; 'f8'=0x77; 'f10'=0x79; 'f12'=0x7B
}
$extended = @('up','down','left','right','numenter','pageup','pagedown','end','home','insert','delete')

$p = Get-Process HogwartsLegacy -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 1
if (-not $p) { Write-Output "Hogwarts Legacy is not running; no keys sent."; exit 1 }
$hwnd = $p.MainWindowHandle

# Other windows (like the Claude app) can grab focus back at any moment, so (re)focus the
# game and confirm it before every key.
function Focus-Game {
    for ($i = 0; $i -lt 20; $i++) {
        if ([HaKeys]::GetForegroundWindow() -eq $hwnd) { return $true }
        [HaKeys]::keybd_event(0x12,0,0,[UIntPtr]::Zero)
        [void][HaKeys]::SetForegroundWindow($hwnd)
        [HaKeys]::keybd_event(0x12,0,2,[UIntPtr]::Zero)
        Start-Sleep -Milliseconds 100
    }
    return $false
}

foreach ($k in $Keys) {
    # Never type into another window: if the game isn't (or stops being) in front, abort.
    if (-not (Focus-Game)) { Write-Output "ABORT: Hogwarts Legacy lost focus before $k"; exit 2 }
    Start-Sleep -Milliseconds 150
    if ([HaKeys]::GetForegroundWindow() -ne $hwnd) { Write-Output "ABORT: focus changed before $k"; exit 2 }
    $ctrl = $k -match '(^|\+)ctrl\+'
    $shift = $k -match '(^|\+)shift\+'
    $name = $k -replace '^((ctrl|shift)\+)+',''
    $hold = 200   # UE4SS polls key state; 90 ms taps were missed
    if ($name -match '^(.+)@(\d+)$') { $name = $matches[1]; $hold = [int]$matches[2] }
    if ($name -eq 'numenter') { $vk = 0x0D }
    elseif ($name -eq 'backspace') { $vk = 0x08 }
    elseif ($name -match '^[a-z0-9]$') { $vk = [int][char]$name.ToUpper() }
    else { $vk = $map[$name] }
    if ($ctrl) { [HaKeys]::Key(0x11, $false, $false) }
    if ($shift) { [HaKeys]::Key(0x10, $false, $false) }
    [HaKeys]::Key($vk, $extended -contains $name, $false)
    Start-Sleep -Milliseconds $hold
    [HaKeys]::Key($vk, $extended -contains $name, $true)
    if ($shift) { [HaKeys]::Key(0x10, $false, $true) }
    if ($ctrl) { [HaKeys]::Key(0x11, $false, $true) }
    Start-Sleep -Milliseconds $DelayMs
}

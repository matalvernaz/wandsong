# Dev helper: focus Hogwarts Legacy and send keys as real input events.
# Usage: sendkeys.ps1 -Keys "ctrl+rbr","bslash" [-DelayMs 700]
# Key names: num0-num9, space, esc, enter, up/down/left/right, f, r, lbr ([), rbr (]),
# bslash (\), quote ('), semi (;), minus, equals, pageup/pagedown/home/end, grave (`), comma, period,
# slash, f1-f12; prefix ctrl+ or shift+. Suffix @ms holds the key that long ("space@2500").
# -Probe first checks that injected letters land (it types an unbound B: never use it while a
# text field such as a character name has focus).
# -Post posts the key messages to the game's window instead of injecting input: they reach the
# game (not the mod's own key handling, which reads the keyboard state) and can't land in any
# other window. For when something on the PC filters injected letters, digits, space, enter
# and arrows (Oct 7 and Oct 8; F-keys, brackets and backslash still passed).
# Before every key, any keyboard or mouse input since this tool's last key that is under
# -IdleSeconds old means someone is using the PC: the run stops and nothing more is sent (Oct 8:
# the game came to the front at launch and Matt was reading its start screen himself). Run
# tools/input_watch.ps1 alongside: it tells real keyboard and mouse use from injected input.
# Without it, the tools' own keys are told apart by the time of the last key sent (kept in
# %TEMP%), but the mod's own camera turns still look like someone at the PC.
param([string[]]$Keys, [int]$DelayMs = 700, [switch]$Probe, [switch]$Post, [int]$IdleSeconds = 10)
# powershell -File passes "a,b" as one string: split it.
$Keys = @($Keys | ForEach-Object { $_ -split "," } | Where-Object { $_ })

Add-Type @'
using System; using System.Runtime.InteropServices;
public class WsKeys {
 [StructLayout(LayoutKind.Sequential)] public struct KI { public ushort vk, scan; public uint flags, time; public UIntPtr extra; public long padA; }
 [StructLayout(LayoutKind.Sequential)] public struct IN { public uint type; public uint pad; public KI ki; }
 [DllImport("user32.dll")] public static extern uint SendInput(uint n, IN[] i, int size);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
 [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int v);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
 [StructLayout(LayoutKind.Sequential)] public struct LII { public uint cbSize; public uint dwTime; }
 [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LII i);
 [DllImport("kernel32.dll")] public static extern uint GetTickCount();
 public static uint LastInput(){ var i=new LII(); i.cbSize=8; GetLastInputInfo(ref i); return i.dwTime; }
 public static void Post(IntPtr h, uint vk, bool ext, bool up){
  uint sc = MapVirtualKey(vk, 0);
  long l = 1 | ((long)sc << 16) | (ext ? (1L << 24) : 0) | (up ? ((1L << 30) | (1L << 31)) : 0);
  PostMessage(h, up ? 0x0101u : 0x0100u, (IntPtr)vk, (IntPtr)l);
 }
 // Virtual key plus its scan code, like a real keyboard driver reports. Scan-code-only
 // input (KEYEVENTF_SCANCODE) was never seen by the game or UE4SS for F or Enter (Oct 7).
 public static void Key(ushort vk, bool ext, bool up){
  var a=new IN[1]; a[0].type=1;
  uint scan=MapVirtualKey(vk,4);
  a[0].ki.vk=vk;
  a[0].ki.scan=(ushort)(scan & 0xff);
  a[0].ki.flags=(uint)(((ext || (scan & 0xff00)==0xe000)?1:0)|(up?2:0));
  if(SendInput(1,a,Marshal.SizeOf(typeof(IN)))!=1) throw new InvalidOperationException("Windows rejected the key input");
 }
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
if ($hwnd -eq [IntPtr]::Zero) { Write-Output "Hogwarts Legacy has no game window yet; no keys sent."; exit 1 }

# Never take focus: the game must already be the window in front. The old way (an Alt tap
# plus SetForegroundWindow, in a loop) sent those Alt taps into whatever was in front when
# Windows refused the switch, and after crashes that was the desktop: NVDA read out desktop
# icons and menus to Matt (Oct 7). If the game isn't in front, nothing is sent at all.
function Game-In-Front { return [WsKeys]::GetForegroundWindow() -eq $hwnd }

$sentFile = Join-Path $env:TEMP 'wandsong_keys_sent.txt'
$watchFile = Join-Path $env:TEMP 'wandsong_physical_input.txt'
function Mark-Sent { Set-Content -Path $sentFile -Value ([WsKeys]::GetTickCount()) }
function Others-Active {
    # tools/input_watch.ps1, when running, knows real keyboard and mouse use from injected input.
    $now = [int64][WsKeys]::GetTickCount()
    $w = Get-Content $watchFile -Raw -ErrorAction SilentlyContinue
    if ($w -match '^(\d+) (\d+)' -and $now - [int64]$matches[1] -lt 3000) {
        $idle = $now - [int64]$matches[2]
        return ($idle -ge 0) -and ($idle -lt $IdleSeconds * 1000)
    }
    # Without it, any input after this tool's last key counts, the mod's own camera turns too.
    $sent = [uint32]0
    $t = Get-Content $sentFile -Raw -ErrorAction SilentlyContinue
    if ($t) { [void][uint32]::TryParse($t.Trim(), [ref]$sent) }
    $last = [int64][WsKeys]::LastInput()
    $idle = [int64][WsKeys]::GetTickCount() - $last
    return ($last -gt [int64]$sent + 300) -and ($idle -ge 0) -and ($idle -lt $IdleSeconds * 1000)
}

# A key left down (a helper stopped between a key's press and its release) makes the mod read
# every later key as a chord with it, so all its keys go dead: Oct 8, a stopped attack loop left
# forward slash down, and F7 did nothing until it was released. The tools note each key they
# hold in %TEMP% until it's released; one still noted (and still down) was left behind. Only
# those are released: the mod's own autowalk holds keys too.
$heldFile = Join-Path $env:TEMP 'wandsong_keys_held.txt'
function Note-Held([int[]]$vks) { Set-Content -Path $heldFile -Value ($vks -join ' ') }
function Release-Stuck {
    # This tool's note, and reflex.ps1's (wandsong_keys_held_reflex.txt).
    foreach ($f in Get-ChildItem (Join-Path $env:TEMP 'wandsong_keys_held*.txt') -ErrorAction SilentlyContinue) {
        $t = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        foreach ($v in ("$t".Trim() -split '\s+')) {
            $vk = 0
            if ([int]::TryParse($v, [ref]$vk) -and ([WsKeys]::GetAsyncKeyState($vk) -band 0x8000)) {
                [WsKeys]::Key([uint16]$vk, $false, $true)
                Write-Output ("Released a key a stopped helper left down (virtual key 0x{0:X2})." -f $vk)
            }
        }
        Remove-Item $f.FullName -ErrorAction SilentlyContinue
    }
}

$checked = $false
foreach ($k in $Keys) {
    # Never type into another window: if the game isn't (or stops being) in front, abort.
    if (-not (Game-In-Front)) { Write-Output "ABORT: Hogwarts Legacy is not the window in front; switch to it and run again. Nothing was sent."; exit 2 }
    # Never play over someone using the PC, the game included.
    if (Others-Active) { Write-Output "ABORT: someone used the PC in the last $IdleSeconds s; no more keys sent."; exit 3 }
    if (-not $checked) { $checked = $true; Release-Stuck }
    Start-Sleep -Milliseconds 150
    if ([WsKeys]::GetForegroundWindow() -ne $hwnd) { Write-Output "ABORT: focus changed before $k"; exit 2 }
    Write-Output "Game foreground verified (PID $($p.Id)): $k"
    if ($Probe -and -not $script:probed) {
        # Some minutes after a launch, a Windows overlay (Game Bar's launch panel, it seems)
        # can swallow injected letters, digits, space, enter and arrows while F-keys and
        # modifiers still pass (Oct 7). Probe once with an unused key pair before sending.
        $script:probed = $true
        [WsKeys]::Key(0x7E, $false, $false); Start-Sleep -Milliseconds 40
        $fkey = [WsKeys]::GetAsyncKeyState(0x7E); [WsKeys]::Key(0x7E, $false, $true)
        if ($fkey -band 0x8000) {
            # F15 lands; does a letter? (B: bound by neither the game nor the mod.)
            [WsKeys]::Key(0x42, $false, $false); Start-Sleep -Milliseconds 40
            $letter = [WsKeys]::GetAsyncKeyState(0x42); [WsKeys]::Key(0x42, $false, $true)
            if (-not ($letter -band 0x8000)) { Write-Output "WARNING: injected letters are being swallowed (an overlay holds the keyboard); keys may not reach the game." }
        }
    }
    $ctrl = $k -match '(^|\+)ctrl\+'
    $shift = $k -match '(^|\+)shift\+'
    $name = $k -replace '^((ctrl|shift)\+)+',''
    $hold = 400   # UE4SS polls key state; even 200 ms taps were missed during game-PC tests
    if ($name -match '^(.+)@(\d+)$') { $name = $matches[1]; $hold = [int]$matches[2] }
    if ($name -eq 'numenter') { $vk = 0x0D }
    elseif ($name -eq 'backspace') { $vk = 0x08 }
    elseif ($name -match '^[a-z0-9]$') { $vk = [int][char]$name.ToUpper() }
    else { $vk = $map[$name] }
    if (-not $vk) { Write-Output "Unknown key: $name; no keys sent."; exit 1 }
    if ($Post) {
        # Straight to the game's window: nothing can reach another window this way.
        $ext = $extended -contains $name
        if ($ctrl) { [WsKeys]::Post($hwnd, 0x11, $false, $false) }
        if ($shift) { [WsKeys]::Post($hwnd, 0x10, $false, $false) }
        [WsKeys]::Post($hwnd, $vk, $ext, $false)
        Start-Sleep -Milliseconds $hold
        [WsKeys]::Post($hwnd, $vk, $ext, $true)
        if ($shift) { [WsKeys]::Post($hwnd, 0x10, $false, $true) }
        if ($ctrl) { [WsKeys]::Post($hwnd, 0x11, $false, $true) }
        Start-Sleep -Milliseconds $DelayMs
        continue
    }
    $lostFocus = $false
    $holding = @($vk)
    if ($shift) { $holding += 0x10 }
    if ($ctrl) { $holding += 0x11 }
    Note-Held $holding
    try {
        if ($ctrl) { [WsKeys]::Key(0x11, $false, $false) }
        if ($shift) { [WsKeys]::Key(0x10, $false, $false) }
        [WsKeys]::Key($vk, $extended -contains $name, $false)
        $held = [Diagnostics.Stopwatch]::StartNew()
        while ($held.ElapsedMilliseconds -lt $hold) {
            if ([WsKeys]::GetForegroundWindow() -ne $hwnd) { $lostFocus = $true; break }
            Start-Sleep -Milliseconds 20
        }
    } finally {
        [WsKeys]::Key($vk, $extended -contains $name, $true)
        if ($shift) { [WsKeys]::Key(0x10, $false, $true) }
        if ($ctrl) { [WsKeys]::Key(0x11, $false, $true) }
        Mark-Sent
        Remove-Item $heldFile -ErrorAction SilentlyContinue
    }
    if ($lostFocus) { Write-Output "ABORT: Hogwarts Legacy lost focus while holding $k; keys released."; exit 2 }
    Start-Sleep -Milliseconds $DelayMs
}
exit 0

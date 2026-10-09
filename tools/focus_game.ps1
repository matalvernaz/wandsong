# Dev helper: bring Hogwarts Legacy to the front, so tools/sendkeys.ps1 and drive.ps1 can play.
# Matt (Oct 8): the tools may switch to the game themselves while testing. No key is ever sent to
# get focus: the old Alt-tap trick sent Alt into whatever was in front when Windows refused the
# switch, and NVDA read the desktop to Matt (Oct 7). This joins the foreground window's input
# queue (AttachThreadInput) for one SetForegroundWindow call, then tries SwitchToThisWindow.
# Someone using the PC (any input in the last -IdleSeconds) is left alone: nothing is switched.
# Then the game window's keyboard focus is cleared and set again, which fires the focus event
# NVDA follows. Without it NVDA stayed on Chrome's page in browse mode and swallowed letters,
# digits, space, enter, arrows and comma as quick-navigation keys (Oct 8: the "overlay" that
# ate injected keys on Oct 7 too); F-keys, brackets and backslash, not NVDA's, still passed.
#   powershell -ExecutionPolicy Bypass -File tools\focus_game.ps1 [-IdleSeconds 15]
param([int]$IdleSeconds = 15)

Add-Type @'
using System; using System.Runtime.InteropServices;
public class WsFocus {
 [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
 [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO i);
 [DllImport("kernel32.dll")] public static extern uint GetTickCount();
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
 [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
 [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr h, bool altTab);
 [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
 // Clear and set the window's keyboard focus from inside its own input queue: a focus event
 // the screen reader sees (EVENT_OBJECT_FOCUS), even when the window already had focus.
 public static void NudgeFocus(IntPtr h) {
  uint t = GetWindowThreadProcessId(h, IntPtr.Zero); uint me = GetCurrentThreadId();
  bool a = t != 0 && t != me && AttachThreadInput(me, t, true);
  try { SetFocus(IntPtr.Zero); System.Threading.Thread.Sleep(200); SetFocus(h); }
  finally { if (a) AttachThreadInput(me, t, false); }
 }
 public static uint IdleMs() {
  var i = new LASTINPUTINFO(); i.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
  if (!GetLastInputInfo(ref i)) return 0;
  return GetTickCount() - i.dwTime;
 }
}
'@

$p = Get-Process HogwartsLegacy -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 1
if (-not $p -or $p.MainWindowHandle -eq [IntPtr]::Zero) { Write-Output "Hogwarts Legacy has no window."; exit 1 }
$hwnd = $p.MainWindowHandle
if ([WsFocus]::GetForegroundWindow() -eq $hwnd) { [WsFocus]::NudgeFocus($hwnd); Write-Output "Hogwarts Legacy is already in front."; exit 0 }
$idle = [WsFocus]::IdleMs() / 1000
if ($idle -lt $IdleSeconds) {
    Write-Output ("Someone is using the PC (input {0:N0} s ago): not switching to the game." -f $idle)
    exit 2
}
for ($i = 0; $i -lt 4; $i++) {
    if ([WsFocus]::IsIconic($hwnd)) { [void][WsFocus]::ShowWindow($hwnd, 9) }   # SW_RESTORE
    $fg = [WsFocus]::GetForegroundWindow()
    $fgThread = [WsFocus]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
    $me = [WsFocus]::GetCurrentThreadId()
    $attached = $false
    if ($fgThread -ne 0 -and $fgThread -ne $me) { $attached = [WsFocus]::AttachThreadInput($me, $fgThread, $true) }
    try {
        [void][WsFocus]::BringWindowToTop($hwnd)
        [void][WsFocus]::SetForegroundWindow($hwnd)
    } finally {
        if ($attached) { [void][WsFocus]::AttachThreadInput($me, $fgThread, $false) }
    }
    Start-Sleep -Milliseconds 300
    if ([WsFocus]::GetForegroundWindow() -eq $hwnd) { [WsFocus]::NudgeFocus($hwnd); Write-Output "Hogwarts Legacy is in front."; exit 0 }
    [WsFocus]::SwitchToThisWindow($hwnd, $true)
    Start-Sleep -Milliseconds 500
    if ([WsFocus]::GetForegroundWindow() -eq $hwnd) { [WsFocus]::NudgeFocus($hwnd); Write-Output "Hogwarts Legacy is in front."; exit 0 }
}
Write-Output "Windows didn't let the game come to the front; nothing was sent."
exit 1

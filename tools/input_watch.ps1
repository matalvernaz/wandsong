# Dev helper for the test tools: records when a real keyboard or mouse was last used, so
# sendkeys.ps1 can leave the game alone while Matt plays. Windows' own idle time can't tell:
# the mod turns the camera and walks with injected input (input_bridge), and those turns
# counted as someone at the PC after every Home or autowalk (Oct 8). Raw Input reports
# injected keys and mouse moves without a device, so only physical input is recorded here.
# Writes "<now> <last physical input>" (GetTickCount ms) to %TEMP% four times a second.
#   Start-Process powershell -WindowStyle Hidden -ArgumentList '-ExecutionPolicy','Bypass','-File','tools\input_watch.ps1'
param([int]$Minutes = 240)

Add-Type -ReferencedAssemblies System.Windows.Forms @'
using System; using System.Runtime.InteropServices; using System.Windows.Forms;
public class HaInputWatch : NativeWindow {
 [StructLayout(LayoutKind.Sequential)] struct RID { public ushort page, usage; public uint flags; public IntPtr target; }
 [StructLayout(LayoutKind.Sequential)] struct HDR { public uint type, size; public IntPtr device, wparam; }
 [StructLayout(LayoutKind.Sequential)] struct LII { public uint cbSize; public uint dwTime; }
 [DllImport("user32.dll")] static extern bool RegisterRawInputDevices(RID[] d, uint n, uint size);
 [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr h, uint cmd, out HDR data, ref uint size, uint hsize);
 [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LII i);
 [DllImport("kernel32.dll")] public static extern uint GetTickCount();
 public static uint LastPhysical;
 public HaInputWatch() {
  // Input before the watch started may have been anyone's: count it as physical.
  var l = new LII(); l.cbSize = 8; GetLastInputInfo(ref l); LastPhysical = l.dwTime;
  CreateHandle(new CreateParams());
  var d = new RID[2];
  d[0].page = 1; d[0].usage = 6; d[0].flags = 0x100; d[0].target = Handle;   // keyboard, RIDEV_INPUTSINK
  d[1].page = 1; d[1].usage = 2; d[1].flags = 0x100; d[1].target = Handle;   // mouse
  if (!RegisterRawInputDevices(d, 2, (uint)Marshal.SizeOf(typeof(RID)))) throw new InvalidOperationException("RegisterRawInputDevices failed");
 }
 protected override void WndProc(ref Message m) {
  if (m.Msg == 0x00FF) {   // WM_INPUT: injected input has no device
   HDR h; uint size = (uint)Marshal.SizeOf(typeof(HDR));
   if (GetRawInputData(m.LParam, 0x10000005, out h, ref size, size) != uint.MaxValue && h.device != IntPtr.Zero)
    LastPhysical = GetTickCount();
  }
  base.WndProc(ref m);
 }
}
'@

$file = Join-Path $env:TEMP 'wandsong_physical_input.txt'
$watch = New-Object HaInputWatch
$end = (Get-Date).AddMinutes($Minutes)
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.add_Tick({
    Set-Content -Path $file -Value ("{0} {1}" -f [HaInputWatch]::GetTickCount(), [HaInputWatch]::LastPhysical)
    if ((Get-Date) -gt $end) { $timer.Stop(); [System.Windows.Forms.Application]::Exit() }
})
$timer.Start()
[System.Windows.Forms.Application]::Run()
Remove-Item $file -ErrorAction SilentlyContinue

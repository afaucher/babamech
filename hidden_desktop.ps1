# hidden_desktop.ps1 - run a program on a separate, invisible Windows desktop (ported from felt's tools\hidden_desktop.ps1;
# flap's test_lib.ps1 does the same). Dot-source it and call Invoke-HiddenDesktop. A windowed Godot run started this
# way renders normally on the real GPU, but its window is never on screen, never in the taskbar and can't take focus.
# (flap: an off-screen --position can be clamped back onto the screen, and a minimized window stops Godot drawing.)
# The desktop object exists only while a process uses it; nothing is installed or changed.
#
#   . .\hidden_desktop.ps1
#   $code = Invoke-HiddenDesktop -Exe $godot -Arguments "--path . -- --scene ..." -TimeoutSec 120
#
# The program has no console there: have it write a log (Godot: --log-file <path>). BABAMECH_SHOW_WINDOWS=1 runs it on
# your own desktop instead, to watch.
# It still uses the GPU: each run takes the shared GPU lock (godot_env.ps1, Enter-BabamechGpu) and waits its turn.
if (-not (Get-Command Enter-BabamechGpu -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\godot_env.ps1" }
if (-not ("BabamechHiddenDesktop" -as [type])) {
    Add-Type @"
using System; using System.Runtime.InteropServices;
public static class BabamechHiddenDesktop {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct STARTUPINFO { public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
    public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
  [StructLayout(LayoutKind.Sequential)]
  struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern IntPtr CreateDesktop(string name, IntPtr dev, IntPtr mode, int flags, uint access, IntPtr sa);
  [DllImport("user32.dll", SetLastError = true)] static extern bool CloseDesktop(IntPtr h);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags,
    IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint code);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  // Runs `exe args` on `desktop` (null: the user's own), waits up to timeoutMs, returns its exit code (124 on timeout).
  public static int Run(string desktop, string exe, string args, string dir, int timeoutMs) {
    IntPtr d = IntPtr.Zero;
    if (desktop != null) {
      d = CreateDesktop(desktop, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000 /*GENERIC_ALL*/, IntPtr.Zero);
      if (d == IntPtr.Zero) throw new Exception("CreateDesktop failed: " + Marshal.GetLastWin32Error());
    }
    try {
      var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(typeof(STARTUPINFO)); si.lpDesktop = desktop;
      PROCESS_INFORMATION pi;
      string cmd = "\"" + exe + "\" " + args;
      if (!CreateProcess(null, cmd, IntPtr.Zero, IntPtr.Zero, false, 0x08000000 /*CREATE_NO_WINDOW*/, IntPtr.Zero, dir, ref si, out pi))
        throw new Exception("CreateProcess failed: " + Marshal.GetLastWin32Error());
      try {
        if (WaitForSingleObject(pi.hProcess, (uint)timeoutMs) != 0) { TerminateProcess(pi.hProcess, 124); return 124; }
        uint code; GetExitCodeProcess(pi.hProcess, out code); return (int)code;
      } finally { CloseHandle(pi.hThread); CloseHandle(pi.hProcess); }
    } finally { if (d != IntPtr.Zero) CloseDesktop(d); }
  }
}
"@
}

function Invoke-HiddenDesktop([string]$Exe, [string]$Arguments = "", [string]$WorkDir = $PSScriptRoot, [int]$TimeoutSec = 120) {
    $desk = if ($env:BABAMECH_SHOW_WINDOWS -eq "1") { $null } else { "BabamechHidden" }
    if (-not (Enter-BabamechGpu "hidden-desktop run")) { throw "GPU busy: gave up waiting for the GPU lock (see above)." }
    try { return [BabamechHiddenDesktop]::Run($desk, $Exe, $Arguments, $WorkDir, $TimeoutSec * 1000) } finally { Exit-BabamechGpu }
}

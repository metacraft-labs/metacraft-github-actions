# One incident's repair, identified by the read-only diagnostic at d5059a8.
# Refuse identity drift, an active parent, another owner, or another file user.
param([switch]$ValidateOnly)
$ErrorActionPreference = 'Stop'
& "$PSScriptRoot/inspect-windows-checkout-lock.ps1" -ValidateOnly
# Open the measured process directly. Get-Process can omit a process still
# visible to Restart Manager and Win32_Process; its enumeration is not proof
# that the kernel process object has exited.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class ExactCheckoutOwner {
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool GetProcessTimes(IntPtr h, out long created, out long exited,
    out long kernel, out long user);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool QueryFullProcessImageName(IntPtr h, uint flags,
    StringBuilder path, ref uint size);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool TerminateProcess(IntPtr h, uint code);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern uint WaitForSingleObject(IntPtr h, uint milliseconds);
  [DllImport("kernel32.dll")]
  static extern bool CloseHandle(IntPtr h);
  static void Require(bool ok) {
    if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error());
  }
  public static void Stop(int pid, long expectedStart, string expectedImage) {
    // Query + synchronize + terminate, with a single retained kernel handle.
    IntPtr h = OpenProcess(0x00101001, false, pid);
    Require(h != IntPtr.Zero);
    try {
      long created, exited, kernel, user;
      Require(GetProcessTimes(h, out created, out exited, out kernel, out user));
      var image = new StringBuilder(32768);
      uint size = (uint)image.Capacity, code;
      Require(QueryFullProcessImageName(h, 0, image, ref size));
      Require(GetExitCodeProcess(h, out code));
      Console.WriteLine("Kernel process: PID={0} created={1} image={2} exitCode={3}",
        pid, created, image, code);
      if (created != expectedStart ||
          !String.Equals(image.ToString(), expectedImage, StringComparison.OrdinalIgnoreCase))
        throw new InvalidOperationException("The kernel process identity changed");
      uint state = WaitForSingleObject(h, 0);
      if (state == 0) {
        Console.WriteLine("The measured process has already exited");
        return;
      }
      if (state != 258) throw new Win32Exception(Marshal.GetLastWin32Error());
      Console.WriteLine("Stopping the verified orphaned PowerShell owner from 2026-09-18");
      Require(TerminateProcess(h, 1));
      if (WaitForSingleObject(h, 10000) != 0)
        throw new InvalidOperationException("The stale process did not exit within 10 seconds");
    } finally { CloseHandle(h); }
  }
}
'@
if ($ValidateOnly) { return }
if (-not $IsWindows -or $env:RUNNER_NAME -ne 'win-ci-bare-001') {
  throw 'This repair is scoped to win-ci-bare-001'
}
$workRoot = Split-Path (Split-Path $env:GITHUB_WORKSPACE -Parent) -Parent
$file = Join-Path $workRoot 'runquota/runquota/reprobuild/build/lib/librepro_monitor_shim.dll'
if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
  Write-Host 'The retained file is already absent'
  return
}
$expectedProcessId = 9600
$expectedStart = ([long]31278879 -shl 32) -bor [long]745382979
$rows = @([CheckoutLockInspector]::Inspect($file))
if ($rows.Count -eq 0) {
  Write-Host 'The retained file no longer has a Restart Manager user'
  return
}
if ($rows.Count -ne 1) { throw 'The retained file has a different set of users' }
$row = $rows[0]
$rowStart = ([long][uint32]$row.Identity.Started.dwHighDateTime -shl 32) -bor
  [long][uint32]$row.Identity.Started.dwLowDateTime
if ($row.Identity.ProcessId -ne $expectedProcessId -or $rowStart -ne $expectedStart -or
    $row.Application -ne 'pwsh' -or $row.Service) {
  throw 'The retained file user does not match the measured process identity'
}
$target = Get-CimInstance Win32_Process -Filter "ProcessId=$expectedProcessId"
if (-not $target -or $target.Name -ne 'pwsh.exe' -or
    $target.ExecutablePath -ne 'C:\pwsh\pwsh.exe') {
  throw 'The measured process image changed'
}
$parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($target.ParentProcessId)"
$target | Select-Object ProcessId, ParentProcessId, Name, ExecutablePath, CreationDate |
  ConvertTo-Json
if ($parent) {
  $parent | Select-Object ProcessId, ParentProcessId, Name, ExecutablePath, CreationDate |
    ConvertTo-Json
  if ($parent.CreationDate -le $target.CreationDate) {
    throw 'The process still has a live parent; refusing to stop it'
  }
}
$current = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
$owner = Invoke-CimMethod -InputObject $target -MethodName GetOwnerSid
$currentOwner = Invoke-CimMethod -InputObject $current -MethodName GetOwnerSid
if ($owner.ReturnValue -ne 0 -or $currentOwner.ReturnValue -ne 0 -or -not $owner.Sid -or
    $owner.Sid -ne $currentOwner.Sid) {
  throw 'The process is not owned by this runner account'
}
# Recheck the exact creation time and image through the retained kernel handle.
# Parent and owner checks above remain mandatory.
[ExactCheckoutOwner]::Stop($expectedProcessId, $expectedStart, 'C:\pwsh\pwsh.exe')
$remaining = @([CheckoutLockInspector]::Inspect($file))
if ($remaining.Count -ne 0) { throw 'The DLL still has a live file user' }
$probe = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read,
  [IO.FileShare]::None)
$probe.Dispose()
Write-Host 'The retained DLL has no registered users and opens exclusively; normal checkout can retry'

# One incident's repair, identified by the read-only diagnostic at d5059a8.
# Refuse identity drift, an active parent, another owner, or another file user.
param([switch]$ValidateOnly)
$ErrorActionPreference = 'Stop'
& "$PSScriptRoot/inspect-windows-checkout-lock.ps1" -ValidateOnly
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
# Retain the kernel process handle and compare its creation time immediately
# before termination. A recycled PID must never select a different process.
$process = Get-Process -Id $expectedProcessId -ErrorAction Stop
try {
  $null = $process.SafeHandle
  if ($process.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $expectedStart -or
      $process.HasExited) {
    throw 'The process identity changed before termination'
  }
  Write-Host 'Stopping the verified orphaned PowerShell file owner from 2026-09-18'
  $process.Kill()
  if (-not $process.WaitForExit(10000)) { throw 'The stale process did not exit' }
} finally { $process.Dispose() }
$remaining = @([CheckoutLockInspector]::Inspect($file))
if ($remaining.Count -ne 0) { throw 'The DLL still has a live file user' }
$probe = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read,
  [IO.FileShare]::None)
$probe.Dispose()
Write-Host 'The retained DLL has no registered users and opens exclusively; normal checkout can retry'

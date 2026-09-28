$ErrorActionPreference = 'Stop'
# Read-only: list process identities/CPU and output timestamps, never command
# lines, environments, credentials or file contents from another job.
$all = @(Get-CimInstance Win32_Process)
$selected = @{}
foreach ($process in $all) {
  if ($process.CommandLine -match '(?i)\\_work\\runquota\\') {
    $selected[[int]$process.ProcessId] = $true
  }
}
do {
  $added = $false
  foreach ($process in $all) {
    if ($selected.ContainsKey([int]$process.ParentProcessId) -and -not $selected.ContainsKey([int]$process.ProcessId)) {
      $selected[[int]$process.ProcessId] = $true
      $added = $true
    }
  }
} while ($added)
foreach ($process in $all) {
  if (-not $selected.ContainsKey([int]$process.ProcessId)) { continue }
  $cpu = ([double]$process.KernelModeTime + [double]$process.UserModeTime) / 10000000
  [pscustomobject]@{ Id = $process.ProcessId; Parent = $process.ParentProcessId; Name = $process.Name; Started = $process.CreationDate; CpuSeconds = $cpu; Executable = $process.ExecutablePath } | Format-List
}
foreach ($root in @('C:\actions-runner\_work\runquota\runquota', 'C:\actions-runner-2\_work\runquota\runquota')) {
  foreach ($relative in @('.reprobuild-src\build', 'reprobuild\build')) {
    $path = Join-Path $root $relative
    if (-not (Test-Path $path)) { continue }
    Write-Host "Recent build outputs: $path"
    Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 20 FullName,Length,LastWriteTimeUtc | Format-Table -AutoSize
  }
}

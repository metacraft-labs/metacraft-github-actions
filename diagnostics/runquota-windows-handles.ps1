# Diagnostic runs of the real daemon and unchanged connection assertions.
# The stats-disabled arm is a causal control, never a replacement CI gate.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$Target = 'windows-x86_64'
$env:RELEASE_TOOLS = Join-Path $PWD '.release-tools/release-tools'
. "$env:RELEASE_TOOLS/common.ps1"
Get-ReleaseDependency 'nim-shm-lease' 'SHM_LEASE_SRC'
$evidence = Join-Path $PWD 'build/windows-handle-evidence'
New-Item -ItemType Directory -Force $evidence, 'build/bin' | Out-Null
$sqlite = Join-Path $env:RUNNER_TEMP 'handle-diagnostic-sqlite'
Invoke-WebRequest 'https://sqlite.org/2026/sqlite-tools-win-x64-3530400.zip' -OutFile "$sqlite.zip"
if ((Get-FileHash "$sqlite.zip" -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'f46ee2475de4cbe287e6e5f7d43c838796b14e7379cd216bdbb28d391429f9fc') {
    throw 'SQLite archive checksum mismatch'
}
Expand-Archive "$sqlite.zip" $sqlite -Force
$env:PATH = "$sqlite;$env:PATH"
& sqlite3 --version > "$evidence/sqlite.txt"
if ($LASTEXITCODE -ne 0) { throw 'SQLite CLI failed' }
$snapshot = Join-Path $evidence 'windows-process-handles.exe'
& $env:RELEASE_CC -Wall -Wextra -Werror "$PSScriptRoot/windows-process-handles.c" -o $snapshot *> "$evidence/build-snapshot.log"
if ($LASTEXITCODE -ne 0) { throw 'Cannot build the Windows snapshot diagnostic' }
& $snapshot *> "$evidence/snapshot-control.log"
if ($LASTEXITCODE -ne 0) { throw 'Named-event snapshot positive/negative control failed' }
$env:RUNQUOTA_DIAGNOSTIC_HANDLES = $snapshot
$fixture = Join-Path $PWD 'tests/integration/t_connection_failure_does_not_stop_the_daemon.nim'
$original = [IO.File]::ReadAllText($fixture)
$source = $original.Replace("`r`n", "`n")
$diagnostic = @'
proc diagnosticHandles(pid: int; phase: string) =
  let captured = execCmdEx(quoteShellCommand(@[
    getEnv("RUNQUOTA_DIAGNOSTIC_HANDLES"), $pid, phase]))
  echo captured.output
  doAssert captured.exitCode == 0, "Native handle snapshot failed"

'@
$source = $source.Replace('proc waitForSteadyState', $diagnostic + "`nproc waitForSteadyState")
$source = $source.Replace('    let descriptorsBefore = openDescriptorCount(pid)', @'
    diagnosticHandles(pid, "before")
    let descriptorsBefore = openDescriptorCount(pid)
    echo "DIAGNOSTIC baseline handles=", descriptorsBefore
'@)
$source = $source.Replace('      check descriptorsAfter - descriptorsBefore < AbortedConnections div 2', @'
      echo "DIAGNOSTIC final handles=", descriptorsAfter
      check descriptorsAfter - descriptorsBefore < AbortedConnections div 2
      diagnosticHandles(pid, "after")
      for round in 1 .. 10:
        sleep(250)
        echo "DIAGNOSTIC idle round=", round, " handles=", openDescriptorCount(pid)
      diagnosticHandles(pid, "idle")
      echo "DIAGNOSTIC observations=", observationsDoc(socketPath)
'@)
$source = $source.Replace('let process = startProcess(daemonPath(), args = [', 'let process = startProcess(daemonPath(), args = @[')
$source = $source.Replace('socketPath.parentDir / "host-id"],', @'
socketPath.parentDir / "host-id"] &
      (if getEnv("RUNQUOTA_DIAGNOSTIC_NO_STATS") == "1": @["--no-write-stats"] else: @[]),
'@)
foreach ($anchor in @('diagnosticHandles(pid, "before")', 'diagnosticHandles(pid, "after")', 'RUNQUOTA_DIAGNOSTIC_NO_STATS')) {
    if (-not $source.Contains($anchor)) { throw "Diagnostic source anchor changed: $anchor" }
}
$results = @()
$failed = $false
try {
    [IO.File]::WriteAllText($fixture, $source)
    & git diff -- tests/integration/t_connection_failure_does_not_stop_the_daemon.nim > "$evidence/source.patch"
    & git rev-parse HEAD > "$evidence/source-revision.txt"
    foreach ($app in @('runquota', 'runquotad')) {
        Invoke-ReleaseNim "apps/$app/$app.nim" "build/bin/$app.exe" *> "$evidence/build-$app.log"
    }
    $binary = Join-Path $evidence 'connection-failure.exe'
    Invoke-ReleaseNim $fixture $binary *> "$evidence/build-fixture.log"
    $hash = (Get-FileHash $binary -Algorithm SHA256).Hash
    foreach ($mode in @('enabled', 'disabled')) {
        $env:RUNQUOTA_DIAGNOSTIC_NO_STATS = if ($mode -eq 'disabled') {'1'} else {'0'}
        for ($round = 1; $round -le 3; $round++) {
            & $binary *> "$evidence/$mode-$round.log"
            $code = $LASTEXITCODE
            $results += @{mode=$mode; round=$round; exitCode=$code; sha256=$hash}
            if ($code -ne 0) { $failed = $true }
            Select-String -Path "$evidence/$mode-$round.log" -Pattern 'DIAGNOSTIC|SNAPSHOT|FAILED|Check failed'
        }
    }
} finally {
    [IO.File]::WriteAllText($fixture, $original)
    $results | ConvertTo-Json | Set-Content "$evidence/results.json"
}
if ($failed) { throw 'Connection fixture failed; original assertions and handle snapshots are retained' }

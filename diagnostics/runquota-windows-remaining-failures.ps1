# Real production graph subset, followed by the same binaries outside monitoring.
# Diagnostic edits only add failure output; every assertion/deadline is retained.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'build/windows-remaining'
New-Item -ItemType Directory -Force $evidence | Out-Null
$originals = @{}
function Edit-Diagnostic([string]$Path, [string]$Before, [string]$After) {
    $text = [IO.File]::ReadAllText((Join-Path $PWD $Path))
    if (-not $text.Contains($Before)) { throw "Missing diagnostic anchor in $Path" }
    if (-not $originals.ContainsKey($Path)) { $originals[$Path] = $text }
    [IO.File]::WriteAllText((Join-Path $PWD $Path), $text.Replace($Before, $After))
}
$names = @('t_e2e_runquota_client_exit_releases_lease', 't_observation_retention_scheduled',
    't_integration_runquota_memory_pressure_gate', 't_m5_process_exec_bench_contract',
    't_observation_store_degraded_capture_build', 't_standalone_daemonless_degradation',
    't_estimate_store_sqlite_streams')
if ($env:RUNQUOTA_CLEANUP_DIAGNOSTIC) {
    $names = @('t_m5_process_exec_bench_contract', 't_observation_store_degraded_capture_build', 't_standalone_daemonless_degradation')
}
$filter = '    testSources.sort()' + "`n" + '    var focusedSources: seq[string] = @[]' + "`n" +
    '    for source in testSources:' + "`n" + '      if source.extractFilename.changeFileExt("") in [' +
    (($names | ForEach-Object { '"' + $_ + '"' }) -join ', ') + ']:' + "`n" +
    '        focusedSources.add(source)' + "`n" + '    testSources = focusedSources'
$results = @()
try {
    Edit-Diagnostic 'repro.nim' '    testSources.sort()' $filter
    Edit-Diagnostic 'repro.nim' 'actionId = "runquota.test_execute." & name)' 'actionId = "runquota.test_execute." & name, cacheable = false)'
    Edit-Diagnostic 'libs/runquota_persistence/src/runquota_persistence.nim' '  SqliteRun(' @'
  if not captured.ok:
    echo "DIAGNOSTIC SQLite path=", path, " exit=", captured.exitCode,
      " failure=", captured.failure, " stderr=", captured.error,
      " stdout=", captured.output
    flushFile(stdout)
  SqliteRun(
'@
    Edit-Diagnostic 'tests/integration/t_observation_retention_scheduled.nim' '      reported = client.retention()' '      reported = client.retention(); echo "DIAGNOSTIC retention: ", reported'
    Edit-Diagnostic 'tests/integration/t_observation_retention_scheduled.nim' '      check healthyRemoved == 250' '      echo "DIAGNOSTIC healthy retention: ", client.retention(); check healthyRemoved == 250'
    $lifecycle = 'tests/e2e/crash-recovery/t_e2e_runquota_client_exit_releases_lease.nim'
    Edit-Diagnostic $lifecycle 'import std/[envvars, json, os, osproc, strutils, unittest]' 'import std/[envvars, json, monotimes, os, osproc, streams, strutils, times, unittest]'
    Edit-Diagnostic $lifecycle 'proc spawnHelper(mode: string; args: openArray[string] = []): owned(Process) =' @'
proc diagnosticWait(helper: Process; timeoutMillis: int): int =
  let started = getMonoTime()
  let pid = helper.processID
  result = helper.waitForExit(timeoutMillis)
  echo "DIAGNOSTIC helper pid=", pid, " elapsed_ms=",
    (getMonoTime() - started).inMilliseconds, " result=", result,
    " running=", helper.running
  if not helper.running:
    echo "DIAGNOSTIC helper output: ", helper.outputStream.readAll()

proc spawnHelper(mode: string; args: openArray[string] = []): owned(Process) =
'@
    Edit-Diagnostic $lifecycle 'helper.waitForExit(3000)' 'diagnosticWait(helper, 3000)'
    Edit-Diagnostic $lifecycle 'if helperMode.len > 0:' @'
if helperMode.len > 0:
  echo "DIAGNOSTIC helper entered mode=", helperMode
  flushFile(stdout)
'@
    if ($env:RUNQUOTA_CLEANUP_DIAGNOSTIC -eq '1') {
    Edit-Diagnostic 'tests/support/scratch_root.nim' 'import std/os' @'
import std/[os, monotimes, times]
include "../../.diagnostic-tools/diagnostics/windows_file_owners.nim"
'@
    Edit-Diagnostic 'tests/support/scratch_root.nim' @'
      except OSError:
        if retried >= SettleBudgetMillis:
          raise
'@ @'
      except OSError as cleanupError:
        if retried >= SettleBudgetMillis:
          # The original two-second deadline remains a failure. Observe what
          # releases the image afterward without turning that failure green.
          let originalFailure = cleanupError
          let diagnosticStart = getMonoTime()
          echo "DIAGNOSTIC cleanup deadline root=", root,
            " pid=", getCurrentProcessId(), " error=", cleanupError.msg
          try:
            diagnosticCleanupOwners(root)
          except CatchableError as ownerError:
            echo "DIAGNOSTIC owner query failed: ", ownerError.msg
          for attempt in 0 ..< 600:
            try:
              removeDir(root)
              echo "DIAGNOSTIC cleanup later succeeded elapsed_ms=",
                (getMonoTime() - diagnosticStart).inMilliseconds
              break
            except OSError:
              if attempt == 599:
                echo "DIAGNOSTIC cleanup still locked after observation"
              sleep(50)
          raise originalFailure
'@
    }
    git diff | Set-Content "$evidence/diagnostic.patch"
    & bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/graph.log" repro test --daemon=off --tool-provisioning=tarball "--write-report=$evidence/graph.json"
    $results += @{mode='monitored-graph'; exitCode=$LASTEXITCODE}
    # repro exec resolves every declared tool, including the Bash used by nested
    # fixtures. Merely adding SQLite to ambient PATH would compare different inputs.
    $env:REPRO_TOOL_PROVISIONING = 'tarball'
    $reproExe = (Get-Command repro).Source
    foreach ($name in $names) {
        $binary = Join-Path $PWD "build/test-bin/$name.exe"
        if (-not (Test-Path $binary)) { throw "Missing real fixture $binary" }
        $hash = (Get-FileHash $binary).Hash
        & bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/$name-native.log" repro exec -- $binary
        $results += @{name=$name; mode='native'; exitCode=$LASTEXITCODE; sha256=$hash}
        Get-Content "$evidence/$name-native.log" -Tail 25
        if ((Get-FileHash $binary).Hash -ne $hash) { throw 'Fixture changed' }
        $results | ConvertTo-Json -Depth 4 | Set-Content "$evidence/results.json"
    }
    # Preserve the graph result and compare the same binaries after compilation
    # and competing fixtures have finished. Every original deadline still applies.
    if (-not $env:RUNQUOTA_CLEANUP_DIAGNOSTIC) {
        foreach ($name in @('t_e2e_runquota_client_exit_releases_lease', 't_observation_retention_scheduled')) {
            $binary = Join-Path $PWD "build/test-bin/$name.exe"
            $hash = (Get-FileHash $binary).Hash
            foreach ($round in 1..3) {
                $prefix = "$evidence/$name-quiet-monitor-$round"
                & bash "$PSScriptRoot/capture-ci-command.sh" "$prefix.log" repro exec -- timeout --kill-after=10 600 $reproExe internal io monitor --depfile "$prefix.iomon" -- $binary
                $results += @{name=$name; mode='quiet-monitored'; round=$round; exitCode=$LASTEXITCODE; sha256=$hash}
                Get-Content "$prefix.log" -Tail 35
                if ((Get-FileHash $binary).Hash -ne $hash) { throw 'Fixture changed' }
                $results | ConvertTo-Json -Depth 4 | Set-Content "$evidence/results.json"
            }
        }
    }
} finally {
    $results | ConvertTo-Json -Depth 4 | Set-Content "$evidence/results.json"
    foreach ($path in $originals.Keys) { [IO.File]::WriteAllText((Join-Path $PWD $path), $originals[$path]) }
}
if (@($results | Where-Object { $_.exitCode -ne 0 }).Count) { throw 'A real comparison failed; inspect retained evidence' }

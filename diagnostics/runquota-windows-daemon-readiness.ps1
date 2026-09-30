# Real daemon and crash-recovery fixture; no mocks or deadline changes.
# Disposable diagnostics retain startup phases and compare identical binaries
# with and without the production monitor after the selected graph finishes.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'build/windows-readiness'
New-Item -ItemType Directory -Force $evidence | Out-Null
$originals = @{}
$results = @()
function Edit-Diagnostic([string]$Path, [string]$Before, [string]$After) {
    $text = [IO.File]::ReadAllText((Join-Path $PWD $Path))
    if (-not $text.Contains($Before)) { throw "Missing diagnostic anchor in $Path" }
    if (-not $originals.ContainsKey($Path)) { $originals[$Path] = $text }
    [IO.File]::WriteAllText((Join-Path $PWD $Path), $text.Replace($Before, $After))
}
try {
    Edit-Diagnostic 'repro.nim' '    testSources.sort()' @'
    testSources.sort()
    var selected: seq[string] = @[]
    for source in testSources:
      if source.extractFilename.changeFileExt("") == "t_e2e_runquota_client_exit_releases_lease":
        selected.add(source)
    testSources = selected
'@
    Edit-Diagnostic 'repro.nim' 'cacheable = not isolatesEnvironment,' 'cacheable = false,'
    $fixture = 'tests/e2e/crash-recovery/t_e2e_runquota_client_exit_releases_lease.nim'
    Edit-Diagnostic $fixture 'import std/[envvars, json, os, osproc, strutils, unittest]' 'import std/[envvars, json, monotimes, os, osproc, streams, strutils, times, unittest]'
    Edit-Diagnostic $fixture 'const HelperModeEnv = "RUNQUOTA_E2E_CRASH_MODE"' @'
when defined(windows):
  import std/winlean

proc diagnosticDaemonOutput(process: Process): string =
  # A descendant can retain the write end after the daemon has exited.
  # Read only bytes already present; logging must not wait for pipe EOF.
  when defined(windows):
    let stream = process.outputStream
    var buffer: array[4096, char]
    while result.len < 65536:
      var available = 0'i32
      if not winlean.peekNamedPipe(winlean.Handle(process.outputHandle),
          lpTotalBytesAvail = addr available) or available <= 0:
        break
      let count = stream.readData(addr buffer[0],
        min(min(int(available), buffer.len), 65536 - result.len))
      if count <= 0:
        break
      for index in 0 ..< count:
        result.add(buffer[index])
  else:
    result = process.outputStream.readAll()

const HelperModeEnv = "RUNQUOTA_E2E_CRASH_MODE"
'@
    Edit-Diagnostic $fixture '  let process = startProcess(' @'
  let diagnosticStart = getMonoTime()
  let process = startProcess(
'@
    Edit-Diagnostic $fixture '    waitForDaemon(socketPath)' @'
    echo "DIAGNOSTIC spawned daemon case=", daemonCounter, " pid=", process.processID,
      " elapsed_ms=", (getMonoTime() - diagnosticStart).inMilliseconds
    waitForDaemon(socketPath)
    echo "DIAGNOSTIC ready daemon case=", daemonCounter, " pid=", process.processID,
      " elapsed_ms=", (getMonoTime() - diagnosticStart).inMilliseconds
'@
    Edit-Diagnostic $fixture @'
  finally:
    if process.running:
      process.terminate()
      discard process.waitForExit(3000)
    process.close()
'@ @'
  finally:
    let diagnosticRunning = process.running
    echo "DIAGNOSTIC daemon case=", daemonCounter, " pid=", process.processID,
      " running_before_cleanup=", diagnosticRunning,
      " elapsed_ms=", (getMonoTime() - diagnosticStart).inMilliseconds
    if process.running:
      process.terminate()
      discard process.waitForExit(3000)
    if not process.running:
      echo "DIAGNOSTIC daemon exit=", process.peekExitCode(),
        " output: ", diagnosticDaemonOutput(process)
    process.close()
'@
    Edit-Diagnostic 'apps/runquotad/runquotad.nim' '  let runningAsService = beginWindowsServiceHost(windowsServiceName)' @'
  echo "DIAGNOSTIC daemon entered main pid=", getCurrentProcessId()
  flushFile(stdout)
  let runningAsService = beginWindowsServiceHost(windowsServiceName)
  echo "DIAGNOSTIC service probe returned"
  flushFile(stdout)
'@
    Edit-Diagnostic 'apps/runquotad/runquotad.nim' '  let exitCode = serve(config)' @'
  echo "DIAGNOSTIC entering serve"
  flushFile(stdout)
  let exitCode = serve(config)
'@
    Edit-Diagnostic 'libs/runquota_daemon/src/runquota_daemon.nim' '  sharedDaemon.daemon = initDaemon(config, deferCapture = true)' @'
  echo "DIAGNOSTIC entering initDaemon"
  flushFile(stdout)
  sharedDaemon.daemon = initDaemon(config, deferCapture = true)
  echo "DIAGNOSTIC initDaemon returned"
  flushFile(stdout)
'@
    git diff | Set-Content "$evidence/diagnostic.patch"
    & bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/graph.log" repro test --daemon=off --tool-provisioning=tarball "--write-report=$evidence/graph.json"
    $results += @{mode='monitored-graph'; exitCode=$LASTEXITCODE}
    $env:REPRO_TOOL_PROVISIONING = 'tarball'
    $reproExe = (Get-Command repro).Source
    $binary = Join-Path $PWD 'build/test-bin/t_e2e_runquota_client_exit_releases_lease.exe'
    if (-not (Test-Path $binary)) { throw "Missing real fixture $binary" }
    $fixtureHash = (Get-FileHash $binary).Hash
    $daemon = Join-Path $PWD 'build/bin/runquotad.exe'
    $daemonHash = (Get-FileHash $daemon).Hash
    foreach ($round in 1..8) {
        foreach ($mode in @('native', 'monitored')) {
            $prefix = "$evidence/$mode-$round"
            if ($mode -eq 'native') {
                & bash "$PSScriptRoot/capture-ci-command.sh" "$prefix.log" repro exec -- timeout --kill-after=10 600 $binary
            } else {
                & bash "$PSScriptRoot/capture-ci-command.sh" "$prefix.log" repro exec -- timeout --kill-after=10 600 $reproExe internal io monitor --depfile "$prefix.iomon" -- $binary
            }
            $code = $LASTEXITCODE
            $results += @{mode=$mode; round=$round; exitCode=$code; fixtureSha256=$fixtureHash; daemonSha256=$daemonHash}
            $results | ConvertTo-Json -Depth 4 | Set-Content "$evidence/results.json"
            if ((Get-FileHash $binary).Hash -ne $fixtureHash -or (Get-FileHash $daemon).Hash -ne $daemonHash) {
                throw 'A comparison binary changed'
            }
            Get-Content "$prefix.log" -Tail 35
        }
    }
} finally {
    $results | ConvertTo-Json -Depth 4 | Set-Content "$evidence/results.json"
    foreach ($path in $originals.Keys) { [IO.File]::WriteAllText((Join-Path $PWD $path), $originals[$path]) }
}
if (@($results | Where-Object { $_.exitCode -ne 0 }).Count) { throw 'A real comparison failed; inspect daemon startup evidence' }

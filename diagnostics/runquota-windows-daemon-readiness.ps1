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
  if ($env:RUNQUOTA_READINESS_FULL_GRAPH -ne 'true') {
    Edit-Diagnostic 'repro.nim' '    testSources.sort()' @'
    testSources.sort()
    var selected: seq[string] = @[]
    for source in testSources:
      if source.extractFilename.changeFileExt("") == "t_e2e_runquota_client_exit_releases_lease":
        selected.add(source)
    testSources = selected
'@
  }
    Edit-Diagnostic 'repro.nim' 'cacheable = not isolatesEnvironment,' 'cacheable = false,'
    $fixture = 'tests/e2e/crash-recovery/t_e2e_runquota_client_exit_releases_lease.nim'
    Edit-Diagnostic $fixture 'import std/[envvars, json, os, osproc, strutils, unittest]' 'import std/[envvars, json, monotimes, os, osproc, streams, strutils, times, unittest]'
    Edit-Diagnostic $fixture 'const HelperModeEnv = "RUNQUOTA_E2E_CRASH_MODE"' @'
when defined(windows):
  import std/winlean

# Only this fixture's child daemons may emit extra startup lines. Other real
# fixtures parse the daemon's public stdout as their readiness barrier.
putEnv("RUNQUOTA_READINESS_STARTUP_TRACE", "1")

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
    let fd = cint(process.outputHandle)
    let flags = fcntl(fd, F_GETFL)
    if flags < 0 or fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0:
      return "diagnostic pipe unavailable"
    defer: discard fcntl(fd, F_SETFL, flags)
    var buffer: array[4096, char]
    while result.len < 65536:
      let count = posix.read(fd, addr buffer[0],
        min(buffer.len, 65536 - result.len))
      if count <= 0:
        break
      for index in 0 ..< count:
        result.add(buffer[index])

proc diagnosticHelperWait(process: Process; timeoutMillis: int): int =
  let started = getMonoTime()
  result = process.waitForExit(timeoutMillis)
  echo "DIAGNOSTIC helper pid=", process.processID, " exit=", result,
    " running=", process.running,
    " wait_ms=", (getMonoTime() - started).inMilliseconds,
    " output: ", diagnosticDaemonOutput(process)

const HelperModeEnv = "RUNQUOTA_E2E_CRASH_MODE"

template diagnosticHelperPhase(label: string) =
  if getEnv(HelperModeEnv).len > 0:
    echo "DIAGNOSTIC helper pid=", getCurrentProcessId(),
      " tick_ns=", getMonoTime().ticks, " phase=", label
    flushFile(stdout)
'@
    Edit-Diagnostic $fixture '  var child = startProcess(' @'
  diagnosticHelperPhase("begin sleep child spawn")
  var child = startProcess(
'@
    Edit-Diagnostic $fixture '  writeFile(pidPath, $child.processID)' @'
  diagnosticHelperPhase("end sleep child spawn")
  writeFile(pidPath, $child.processID)
'@
    Edit-Diagnostic $fixture 'helper.waitForExit(3000)' 'diagnosticHelperWait(helper, 3000)'
    Edit-Diagnostic $fixture 'if helperMode.len > 0:' @'
if helperMode.len > 0:
  diagnosticHelperPhase("entered helper dispatcher")
'@
    # Only two-space helper-procedure statements are selected. Preserve each
    # call and its arguments; log around it without changing control flow.
    $helperText = [IO.File]::ReadAllText((Join-Path $PWD $fixture))
    foreach ($phase in @(
        @{name='connect'; pattern='(?m)^  var client = connectDefault\(\)$'},
        @{name='register'; pattern='(?m)^  var session = client\.registerSession\([^\r\n]+$'},
        @{name='request lease'; pattern='(?m)^  var lease = session\.requestLease\([^\r\n]+$'},
        @{name='mark starting'; pattern='(?m)^  lease\.markStarting\(\)$'},
        @{name='mark running'; pattern='(?m)^  lease\.markRunning\([^\r\n]+$'}
    )) {
        if (-not [regex]::IsMatch($helperText, $phase.pattern)) {
            throw "Missing helper phase $($phase.name)"
        }
        $before = "  diagnosticHelperPhase(`"begin $($phase.name)`")"
        $after = "  diagnosticHelperPhase(`"end $($phase.name)`")"
        $replacement = $before + "`n" + '$0' + "`n" + $after
        $helperText = [regex]::Replace($helperText, $phase.pattern, $replacement)
    }
    [IO.File]::WriteAllText((Join-Path $PWD $fixture), $helperText)
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
  if getEnv("RUNQUOTA_READINESS_STARTUP_TRACE") == "1":
    echo "DIAGNOSTIC daemon entered main pid=", getCurrentProcessId()
    flushFile(stdout)
  let runningAsService = beginWindowsServiceHost(windowsServiceName)
  if getEnv("RUNQUOTA_READINESS_STARTUP_TRACE") == "1":
    echo "DIAGNOSTIC service probe returned"
    flushFile(stdout)
'@
    Edit-Diagnostic 'apps/runquotad/runquotad.nim' '  let exitCode = serve(config)' @'
  if getEnv("RUNQUOTA_READINESS_STARTUP_TRACE") == "1":
    echo "DIAGNOSTIC entering serve"
    flushFile(stdout)
  let exitCode = serve(config)
'@
    Edit-Diagnostic 'libs/runquota_daemon/src/runquota_daemon.nim' '  sharedDaemon.daemon = initDaemon(config, deferCapture = true)' @'
  if getEnv("RUNQUOTA_READINESS_STARTUP_TRACE") == "1":
    echo "DIAGNOSTIC entering initDaemon"
    flushFile(stdout)
  sharedDaemon.daemon = initDaemon(config, deferCapture = true)
  if getEnv("RUNQUOTA_READINESS_STARTUP_TRACE") == "1":
    echo "DIAGNOSTIC initDaemon returned"
    flushFile(stdout)
'@
    git diff | Set-Content "$evidence/diagnostic.patch"
    & bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/graph.log" repro test --daemon=off --tool-provisioning=tarball "--write-report=$evidence/graph.json"
    $results += @{mode='monitored-graph'; exitCode=$LASTEXITCODE}
    $results | ConvertTo-Json -Depth 4 | Set-Content "$evidence/results.json"
    $env:REPRO_TOOL_PROVISIONING = 'tarball'
    if ($env:RUNQUOTA_READINESS_FULL_GRAPH -ne 'true') {
        # Materialize the dev environment once for the entire paired comparison.
        # Re-entering it for every sample dominated the earlier diagnostic.
        & bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/repetitions.log" repro exec -- pwsh -NoProfile -File "$PSScriptRoot/runquota-windows-daemon-readiness-repeat.ps1"
        if ($LASTEXITCODE) { throw 'Repeated startup comparison failed' }
    }
    $results = @(Get-Content "$evidence/results.json" -Raw | ConvertFrom-Json)
} finally {
    if (-not (Test-Path "$evidence/results.json")) {
        $results | ConvertTo-Json -Depth 4 | Set-Content "$evidence/results.json"
    }
    foreach ($path in $originals.Keys) { [IO.File]::WriteAllText((Join-Path $PWD $path), $originals[$path]) }
}
if (@($results | Where-Object { $_.exitCode -ne 0 }).Count) { throw 'A real comparison failed; inspect daemon startup evidence' }

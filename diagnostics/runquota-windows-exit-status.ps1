# No mocks: compile and run the actual atomicity and host-load programs through
# the production recipe, then compare the same bytes through native/MSYS paths.
# The local recipe edit narrows this diagnostic only; ordinary CI stays complete.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'build/windows-exit-status'
New-Item -ItemType Directory -Force $evidence | Out-Null
$monitorRoot = Split-Path $env:IO_MON_SRC
$bootstrapEvidence = @{ioMonSource=(& git -C $monitorRoot rev-parse HEAD).Trim(); repro=(Get-Command repro).Source}
if ($env:STACKABLE_HOOKS_SRC) {
    $bootstrapEvidence.hooksSource = (& git -C (Split-Path $env:STACKABLE_HOOKS_SRC) rev-parse HEAD).Trim()
}
$bootstrapEvidence | ConvertTo-Json | Set-Content "$evidence/bootstrap.json"
$recipe = Join-Path $PWD 'repro.nim'
$original = [IO.File]::ReadAllText($recipe)
$filter = @'
    testSources.sort()
    var focusedSources: seq[string] = @[]
    for source in testSources:
      if source.extractFilename in ["t_ambient_sample_atomicity.nim", "t_host_load_reading_invariants.nim"]:
        focusedSources.add(source)
    testSources = focusedSources
'@
$changed = $original.Replace('    testSources.sort()', $filter.TrimEnd())
$changed = $changed.Replace('actionId = "runquota.test_execute." & name)', 'actionId = "runquota.test_execute." & name, cacheable = false)')
if ($changed -eq $original -or -not $changed.Contains('cacheable = false')) { throw 'Diagnostic recipe anchor changed' }
$results = @()
$started = Get-Date
$dumpRoot = Join-Path $evidence 'dumps'
New-Item -ItemType Directory -Force $dumpRoot | Out-Null
foreach ($image in @('t_ambient_sample_atomicity.exe','t_host_load_reading_invariants.exe','thread-exit-probe.exe')) {
    $key = "HKCU:\Software\Microsoft\Windows\Windows Error Reporting\LocalDumps\$image"
    New-Item -Force $key | Out-Null
    New-ItemProperty $key -Name DumpFolder -Value $dumpRoot -PropertyType ExpandString -Force | Out-Null
    New-ItemProperty $key -Name DumpType -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty $key -Name DumpCount -Value 1 -PropertyType DWord -Force | Out-Null
}
try {
    [IO.File]::WriteAllText($recipe, $changed)
    git diff -- repro.nim | Set-Content "$evidence/diagnostic-subset.patch"
    for ($round = 1; $round -le 1; $round++) {
        $report = "$evidence/graph-$round.json"
        & bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/graph-$round.log" repro test --daemon=off --tool-provisioning=tarball "--write-report=$report"
        $code = $LASTEXITCODE
        $results += @{mode='monitored-graph'; round=$round; exitCode=$code}
        Write-Host "Monitored graph round $round exit $code"
        if (Test-Path $report) {
            $doc = Get-Content $report -Raw | ConvertFrom-Json
            foreach ($action in @($doc.actions | Where-Object { $_.id -like 'runquota.test_execute.*' })) {
                Write-Host "$($action.id) status=$($action.status) exit=$($action.exitCode) launched=$($action.launched)"
            }
        }
    }
    function Tool([string]$Name, [string]$Executable) {
        $prefix = Join-Path $PWD ".repro/build/repro/tool-store/prefixes/$Name"
        $match = Get-ChildItem -LiteralPath $prefix -Recurse -File -Filter $Executable | Select-Object -First 1
        if (-not $match) { throw "Missing declared $Name executable" }
        return $match.FullName
    }
    $sqlite = Tool 'sqlite3' 'sqlite3.exe'
    $shell = Tool 'sh' 'sh.exe'
    $timeout = Tool 'timeout' 'timeout.exe'
    $env:PATH = "$(Split-Path $sqlite);$(Split-Path $timeout);$(Split-Path $shell);$env:PATH"
    @{sqlite=$sqlite; sh=$shell; timeout=$timeout} | ConvertTo-Json | Set-Content "$evidence/tools.json"
    # Independent real thread lifecycle probe: same native/monitored comparison.
    $probeSource = Join-Path $evidence 'thread_exit_probe.nim'
    @'
# No mocks: real joined threads and temporary filesystem operations.
import std/[os, strutils]
proc worker(id: int) {.thread.} =
  let path = getTempDir() / ("monitor-thread-exit-" & $getCurrentProcessId() & "-" & $id)
  for i in 0..<20:
    writeFile(path, "probe " & $i)
    removeFile(path)
var threads: array[8, Thread[int]]
for i in 0..<threads.len: createThread(threads[i], worker, i)
joinThreads(threads)
echo "all real workers joined"
'@ | Set-Content $probeSource
    & nim c --hints:off --cc:gcc --threads:on -d:release '--out:build/test-bin/thread-exit-probe.exe' $probeSource *> "$evidence/thread-probe-build.log"
    if ($LASTEXITCODE -ne 0) { throw 'Thread lifecycle probe compile failed' }
    foreach ($name in @('t_ambient_sample_atomicity', 't_host_load_reading_invariants', 'thread-exit-probe')) {
        $binary = Join-Path $PWD "build/test-bin/$name.exe"
        if (-not (Test-Path $binary)) { throw "Missing real fixture $binary" }
        $hash = (Get-FileHash -Algorithm SHA256 $binary).Hash
        $bashPath = $binary.Replace('\','/')
        foreach ($mode in @('native','monitor-native','monitor-shell-timeout')) {
            $log = "$evidence/$name-$mode.log"
            $argv = switch ($mode) {
                native { @($binary) }
                monitor-native { @((Get-Command repro).Source, 'internal','io','monitor','--depfile',"$evidence/$name-$mode.iomon",'--events','jsonl','--event-stream',"$evidence/$name-$mode.events.jsonl",'--',$binary) }
                monitor-shell-timeout { @((Get-Command repro).Source,'internal','io','monitor','--depfile',"$evidence/$name-$mode.iomon",'--events','jsonl','--event-stream',"$evidence/$name-$mode.events.jsonl",'--',$shell,'-c',"timeout --kill-after=10 600 '$bashPath' </dev/null") }
            }
            & python "$PSScriptRoot/capture-windows-exit.py" "$evidence/$name-$mode" @argv
            if ($LASTEXITCODE -ne 0) { throw 'Exit capture failed' }
            $capture = Get-Content "$evidence/$name-$mode.json" -Raw | ConvertFrom-Json
            $code = $capture.exitCode
            if ((Get-FileHash -Algorithm SHA256 $binary).Hash -ne $hash) { throw 'Fixture bytes changed during control' }
            $results += @{name=$name; mode=$mode; exitCode=$code; sha256=$hash}
            Write-Host "$name $mode exit=$code sha256=$hash"
            Get-Content $log -Tail 12
        }
    }
    $results | ConvertTo-Json -Depth 5 | Set-Content "$evidence/results.json"
    if (@($results | Where-Object { $_.exitCode -ne 0 }).Count) { throw 'Some exit-status controls failed; inspect retained evidence' }
} finally {
    Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$started; Id=1000,1001} -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 't_ambient_sample_atomicity|t_host_load_reading_invariants|thread-exit-probe|repro' } |
        Select-Object TimeCreated,Id,ProviderName,Message | ConvertTo-Json -Depth 4 | Set-Content "$evidence/windows-crash-events.json"
    $results | ConvertTo-Json -Depth 5 | Set-Content "$evidence/results.json"
    [IO.File]::WriteAllText($recipe, $original)
}

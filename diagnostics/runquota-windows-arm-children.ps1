# No mocks: compare the real failing Windows tests under the monitor and natively.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'build/windows-arm-children'
New-Item -ItemType Directory -Force $evidence | Out-Null
if (-not $env:IO_MON_SRC) { throw 'Bootstrap did not publish its io-mon source path' }
$monitorRoot = Split-Path $env:IO_MON_SRC
$monitorRevision = (& git -C $monitorRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $monitorRevision -ne 'a2a7733ced06611cbb15c4e393a7bf5f126286d7') { throw "Wrong monitor revision: $monitorRevision" }
@{monitor=$monitorRevision; source=$monitorRoot; shim=$env:REPRO_MONITOR_SHIM_LIB} | ConvertTo-Json | Set-Content "$evidence/bootstrap.json"
$recipe = Join-Path $PWD 'repro.nim'
$original = [IO.File]::ReadAllText($recipe)
$filter = @'
    testSources.sort()
    var focusedSources: seq[string] = @[]
    for source in testSources:
      if source.extractFilename in ["t_owner_identity.nim", "t_host_state_directory_rules.nim", "t_stats_table_publication.nim"]:
        focusedSources.add(source)
    testSources = focusedSources
'@
$changed = $original.Replace('    testSources.sort()', $filter.TrimEnd())
$changed = $changed.Replace('actionId = "runquota.test_execute." & name)', 'actionId = "runquota.test_execute." & name, cacheable = false)')
if ($changed -eq $original -or -not $changed.Contains('cacheable = false')) { throw 'Diagnostic recipe anchor changed' }
$results = @()
try {
    [IO.File]::WriteAllText($recipe,$changed)
    git diff -- repro.nim | Set-Content "$evidence/diagnostic-subset.patch"
    & bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/monitored.log" repro test --daemon=off --tool-provisioning=tarball "--write-report=$evidence/monitored.json"
    $results += @{mode='monitored-graph'; exitCode=$LASTEXITCODE}
    foreach ($name in @('t_owner_identity','t_host_state_directory_rules','t_stats_table_publication')) {
        $binary = Join-Path $PWD "build/test-bin/$name.exe"
        $hash = (Get-FileHash -Algorithm SHA256 $binary).Hash
        & $binary *> "$evidence/$name-native.log"
        $results += @{name=$name; mode='native'; exitCode=$LASTEXITCODE; sha256=$hash}
        Get-Content "$evidence/$name-native.log" -Tail 18
        if ((Get-FileHash -Algorithm SHA256 $binary).Hash -ne $hash) { throw 'Fixture bytes changed' }
    }
} finally {
    [IO.File]::WriteAllText($recipe,$original)
    $results | ConvertTo-Json | Set-Content "$evidence/results.json"
}
if (@($results | Where-Object {$_.exitCode -ne 0}).Count) { throw 'Real test comparison failed; inspect retained reports' }

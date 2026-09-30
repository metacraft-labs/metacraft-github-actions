# Preserve real tests, internal concurrency, monitoring and all deadlines.
# Only the number of independent test programs admitted at once changes.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'build/windows-arm-test-contention'
New-Item -ItemType Directory -Force $evidence | Out-Null
$recipe = Join-Path $PWD 'repro.nim'
$original = [IO.File]::ReadAllText($recipe)
$results = @()
try {
    $anchor = '    testSources.sort()'
    if ([regex]::Matches($original, [regex]::Escape($anchor)).Count -ne 1) { throw 'Test selection anchor changed' }
    $selection = @'
    testSources.sort()
    const selectedNames = [
      "t_e2e_runquota_concurrent_short_lived_clients",
      "t_m5_process_exec_bench_contract",
      "t_observation_socket_write_path",
      "t_stats_table_cache_control",
      "t_observation_retention_schedule",
      "t_observation_store_export",
      "t_observation_store_merge"]
    var selected: seq[string] = @[]
    for source in testSources:
      if source.extractFilename.changeFileExt("") in selectedNames:
        selected.add(source)
    doAssert selected.len == selectedNames.len
    testSources = selected
'@
    $patched = $original.Replace($anchor, $selection)
    if (-not $patched.Contains('cacheable = not isolatesEnvironment,')) { throw 'Execution policy anchor changed' }
    $patched = $patched.Replace('cacheable = not isolatesEnvironment,', 'cacheable = false,')
    [IO.File]::WriteAllText($recipe, $patched)
    git diff | Set-Content "$evidence/diagnostic.patch"
    git rev-parse HEAD | Set-Content "$evidence/source-sha.txt"
    $env:REPROBUILD_MAX_PARALLELISM = '8'
    & bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/build.log" repro build --daemon=off --tool-provisioning=tarball "--write-report=$evidence/build.json"
    if ($LASTEXITCODE) { throw 'Monitored compilation failed; no test scheduling comparison is valid' }
    $hashes = @{}
    foreach ($file in @(Get-ChildItem build/bin/*.exe) + @(Get-ChildItem build/test-bin/*.exe)) {
        $hashes[$file.FullName] = (Get-FileHash $file.FullName).Hash
    }
    $hashes | ConvertTo-Json | Set-Content "$evidence/binary-sha256.json"
    foreach ($mode in @('parallel-first', 'serial', 'parallel-second')) {
        $env:REPROBUILD_MAX_PARALLELISM = if ($mode -eq 'serial') { '1' } else { '8' }
        & bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/$mode.log" repro test --daemon=off --tool-provisioning=tarball "--write-report=$evidence/$mode.json"
        $code = $LASTEXITCODE
        $report = Get-Content "$evidence/$mode.json" -Raw | ConvertFrom-Json
        $actions = @($report.actions | Where-Object { $_.id -like 'runquota.test_execute.*' })
        $results += @{mode=$mode; parallelism=$env:REPROBUILD_MAX_PARALLELISM; exitCode=$code; actions=@($actions | Select-Object id,status,exitCode,launched,cacheDecision)}
        $results | ConvertTo-Json -Depth 6 | Set-Content "$evidence/results.json"
        if ($actions.Count -ne 7 -or @($actions | Where-Object { -not $_.launched -or $_.cacheDecision -ne 'cdNotCacheable' }).Count) {
            throw 'A comparison did not execute all seven real programs'
        }
        foreach ($path in $hashes.Keys) {
            if ((Get-FileHash $path).Hash -ne $hashes[$path]) { throw "Comparison binary changed: $path" }
        }
    }
} finally {
    [IO.File]::WriteAllText($recipe, $original)
}
if (@($results | Where-Object { $_.exitCode -ne 0 }).Count) {
    throw 'A real scheduling comparison failed; retain the complete results'
}

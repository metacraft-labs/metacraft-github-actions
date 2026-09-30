# Preserve real tests, internal concurrency, monitoring and all deadlines.
# Only the number of independent test programs admitted at once changes.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'build/windows-arm-test-contention'
New-Item -ItemType Directory -Force $evidence | Out-Null
$recipe = Join-Path $PWD 'repro.nim'
$original = [IO.File]::ReadAllText($recipe)
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
    # A second graph evaluation can rebuild a binary on a legitimate cache
    # miss. Enter the environment once and run the fixed images directly under
    # the production monitor; the comparison must never invoke a compiler.
    $env:REPRO_TOOL_PROVISIONING = 'tarball'
    & bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/comparison.log" repro exec -- python "$PSScriptRoot/runquota-windows-arm-test-contention.py"
    if ($LASTEXITCODE) { throw 'Real scheduling comparison failed; retain all outcomes' }
} finally {
    [IO.File]::WriteAllText($recipe, $original)
}

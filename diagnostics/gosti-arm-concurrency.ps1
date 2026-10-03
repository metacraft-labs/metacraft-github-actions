# Compare the unchanged real concurrency program under Repro and directly.
# The temporary recipe change removes only the all-suite ordering prerequisite
# for this supplemental diagnostic. Production ordering and gates stay intact.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'test-logs/arm-concurrency'
New-Item -ItemType Directory -Force $evidence | Out-Null
$recipe = Join-Path $PWD 'repro.nim'
$original = [IO.File]::ReadAllBytes($recipe)
$source = [Text.Encoding]::UTF8.GetString($original)
$anchor = 'const timingTests = ["t_tart_backend", "t_vmharness_serve_concurrency"]'
if (-not $source.Contains($anchor)) { throw 'Timing prerequisite anchor changed' }
$candidate = (& git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $candidate -ne '6129ea89f80731c1ec9087e78d9058270f0affb2') {
    throw "Unexpected Gosti candidate: $candidate"
}
foreach ($repo in @('.', 'reprobuild', 'io-mon', 'runquota', 'nim-stackable-hooks')) {
    "$repo $(& git -C $repo rev-parse HEAD)" | Add-Content "$evidence/sources.txt"
    if ($LASTEXITCODE -ne 0) { throw "Cannot identify $repo" }
}
Get-FileHash reprobuild/build/lib/librepro_monitor_shim.dll -Algorithm SHA256 |
    Format-List > "$evidence/monitor-sha256.txt"
$results = @()
$failed = $false
try {
    $selected = $source.Replace($anchor, 'const timingTests = ["diagnostic-unused-target"]')
    [IO.File]::WriteAllText($recipe, $selected, (New-Object Text.UTF8Encoding($false)))
    & git diff -- repro.nim > "$evidence/selection.patch"
    foreach ($round in 1..3) {
        $name = "round-$round"
        # Explicit forced validation requires actual execution; cacheability and
        # automatic monitoring remain unchanged in the action declaration.
        & bash scripts/capture-ci-command.sh "$evidence/$name-repro.log" dev-exec repro build '.#test-t_vmharness_serve_concurrency' --tool-provisioning=path --force-rebuild "--write-report=$evidence/$name-report.json"
        $code = $LASTEXITCODE
        $results += @{mode='repro'; round=$round; exitCode=$code}
        if ($code -ne 0) { $failed = $true }
        Get-Content "$evidence/$name-repro.log" -Tail 25
        $report = Get-Content "$evidence/$name-report.json" -Raw | ConvertFrom-Json
        $actions = @($report.actions | Where-Object {$_.id -like 'vm_harness.test_execute.*'})
        if ($actions.Count -ne 1 -or $actions[0].id -ne 'vm_harness.test_execute.t_vmharness_serve_concurrency' -or -not $actions[0].launched) {
            throw 'The selected real concurrency action did not execute'
        }
        if ($actions[0].status -ne 'asSucceeded' -or $actions[0].exitCode -ne 0 -or ([regex]::Matches($actions[0].stdout, '\[OK\]')).Count -ne 2) {
            $failed = $true
        }
        $binary = Join-Path $PWD 'build/test-bin/t_vmharness_serve_concurrency.exe'
        $hash = (Get-FileHash $binary -Algorithm SHA256).Hash
        & $binary *> "$evidence/$name-native.log"
        $code = $LASTEXITCODE
        $results += @{mode='native'; round=$round; exitCode=$code; sha256=$hash}
        if ($code -ne 0 -or ([regex]::Matches((Get-Content "$evidence/$name-native.log" -Raw), '\[OK\]')).Count -ne 2) { $failed = $true }
        Get-Content "$evidence/$name-native.log" -Tail 20
        if ((Get-FileHash $binary -Algorithm SHA256).Hash -ne $hash) { throw 'Fixture bytes changed during direct execution' }
        $results | ConvertTo-Json | Set-Content "$evidence/results.json"
    }
    $env:VMH_CONC_TEST_THREADS = '1'
    & $binary *> "$evidence/serial-control.log"
    $code = $LASTEXITCODE
    $log = Get-Content "$evidence/serial-control.log" -Raw
    Get-Content "$evidence/serial-control.log" -Tail 25
    $results += @{mode='serial-control'; exitCode=$code; sha256=(Get-FileHash $binary -Algorithm SHA256).Hash}
    $results | ConvertTo-Json | Set-Content "$evidence/results.json"
    if ($code -eq 0 -or -not $log.Contains('Check failed: elapsed < 2.5')) {
        throw 'One-worker control did not detect serialized dispatch'
    }
} finally {
    [IO.File]::WriteAllBytes($recipe, $original)
    Remove-Item Env:VMH_CONC_TEST_THREADS -ErrorAction SilentlyContinue
}
if ($failed) { throw 'At least one unchanged concurrency execution failed; inspect timings' }

# Diagnostic only: real full-suite contention, the original three-second M5
# bound, direct runs of the same executable, and separately profiled monitor
# phases. Both matrix variants use the same pinned sources and commands.
param([Parameter(Mandatory)][string]$HookRevision)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'test-logs/runquota-cwd'
New-Item -ItemType Directory -Force $evidence | Out-Null
$fixture = Join-Path $PWD 'tests/integration/t_m5_process_exec_bench_contract.nim'
$originalFixture = [IO.File]::ReadAllBytes($fixture)
$shim = Join-Path $PWD 'io-mon/src/io_mon/shim/windows_interpose.nim'
$originalShim = [IO.File]::ReadAllBytes($shim)
$hooks = Join-Path $PWD 'nim-stackable-hooks/src/stackable_hooks/inline_hook/windows/install_windows.c'
$originalHooks = [IO.File]::ReadAllBytes($hooks)
$originalShimPin = $env:REPRO_MONITOR_SHIM_LIB
$expected = @{
    '.' = '6fc59c967460b132ab7f5ddbf0ac4fd0c755b9c0'
    'reprobuild' = '1f85ace0037d0a70e966fe8eee645d766522b1ab'
    'io-mon' = '5e71adf033b860c0fdbe13dda4320cf4a580f632'
    'runquota' = '292e578d57eb85d6037f9e2d3a03f0bcb0489dbb'
    'nim-stackable-hooks' = $HookRevision
}
foreach ($repo in $expected.Keys) {
    $actual = (& git -C $repo rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actual -ne $expected[$repo]) { throw "Unexpected $repo revision: $actual" }
    "$repo $actual" | Add-Content "$evidence/sources.txt"
}
Get-FileHash reprobuild/build/lib/librepro_monitor_shim.dll -Algorithm SHA256 |
    Format-List > "$evidence/production-monitor-sha256.txt"
& nim --version > "$evidence/nim-version.txt"
$results = @()
$failed = $false
try {
    & python "$PSScriptRoot/runquota-cwd-profile.py" $fixture
    if ($LASTEXITCODE -ne 0) { throw 'M5 diagnostic anchors changed' }
    & git diff -- tests/integration/t_m5_process_exec_bench_contract.nim > "$evidence/fixture.patch"
    # Keep default production concurrency, all 213 actions, and every assertion.
    # The original production monitor is untouched for this full-suite run.
    & dev-exec repro test --tool-provisioning=tarball --force-rebuild "--write-report=$evidence/full-report.json" *> "$evidence/full.log"
    $code = $LASTEXITCODE
    $results += @{mode='full'; exitCode=$code; hooks=$HookRevision}
    $results | ConvertTo-Json | Set-Content "$evidence/results.json"
    $report = Get-Content "$evidence/full-report.json" -Raw | ConvertFrom-Json
    $m5 = @($report.actions | Where-Object {$_.id -eq 'runquota.test_execute.t_m5_process_exec_bench_contract'})
    if ($m5.Count -ne 1 -or -not $m5[0].launched) { throw 'The real M5 action did not execute' }
    $m5[0] | ConvertTo-Json -Depth 20 > "$evidence/full-m5.json"
    if (-not ($m5[0].stdout + $m5[0].stderr).Contains('cwd-profile phase=wait-end')) { throw 'Missing completion diagnostics' }
    $bad = @($report.actions | Where-Object {$_.status -ne 'asSucceeded' -or -not $_.launched -or $_.exitCode -ne 0})
    if ($code -ne 0 -or $report.actions.Count -ne 213 -or $bad.Count -ne 0) { $failed = $true }

    $binary = Join-Path $PWD 'build/test-bin/t_m5_process_exec_bench_contract.exe'
    $hash = (Get-FileHash $binary -Algorithm SHA256).Hash
    foreach ($iteration in 1..3) {
        & $binary *> "$evidence/direct-$iteration.log"
        $code = $LASTEXITCODE
        $text = Get-Content "$evidence/direct-$iteration.log" -Raw
        $results += @{mode='direct'; iteration=$iteration; exitCode=$code; sha256=$hash}
        if ($code -ne 0 -or ([regex]::Matches($text, '\[OK\]')).Count -ne 7 -or
            ([regex]::Matches($text, '\[SKIPPED\]')).Count -ne 4) { $failed = $true }
        if ((Get-FileHash $binary -Algorithm SHA256).Hash -ne $hash) { throw 'Direct-run binary changed' }
        $results | ConvertTo-Json | Set-Content "$evidence/results.json"
    }

    # Phase attribution is a separate experiment after production execution.
    # Both variants use identical debug compilation and the same instrumentation.
    & python "$PSScriptRoot/gosti-monitor-profile.py" $shim
    if ($LASTEXITCODE -ne 0) { throw 'Monitor phase anchors changed' }
    & python "$PSScriptRoot/gosti-hooks-profile.py" $hooks
    if ($LASTEXITCODE -ne 0) { throw 'Hook phase anchors changed' }
    & git -C io-mon diff -- src/io_mon/shim/windows_interpose.nim > "$evidence/monitor.patch"
    & git -C nim-stackable-hooks diff -- src/stackable_hooks/inline_hook/windows/install_windows.c > "$evidence/hooks.patch"
    $env:IO_MON_BUILD_MODE = 'debug'
    $env:IO_MON_SHIM_OUT_DIR = (Join-Path $PWD 'build/cwd-profile/lib').Replace('\', '/')
    $env:IO_MON_SHIM_NIMCACHE_DIR = (Join-Path $PWD 'build/cwd-profile/nimcache').Replace('\', '/')
    & bash io-mon/scripts/build_shim.sh --opt:none *> "$evidence/profile-monitor-build.log"
    if ($LASTEXITCODE -ne 0) { throw 'Profile monitor build failed' }
    $env:REPRO_MONITOR_SHIM_LIB = (Resolve-Path "$env:IO_MON_SHIM_OUT_DIR/librepro_monitor_shim.dll").Path
    Get-FileHash $env:REPRO_MONITOR_SHIM_LIB -Algorithm SHA256 | Format-List > "$evidence/profile-monitor-sha256.txt"
    & dev-exec repro build '.#test-t_m5_process_exec_bench_contract' --tool-provisioning=tarball --force-rebuild "--write-report=$evidence/profile-report.json" *> "$evidence/profile.log"
    $code = $LASTEXITCODE
    $results += @{mode='profile'; exitCode=$code; shim=$env:REPRO_MONITOR_SHIM_LIB}
    $results | ConvertTo-Json | Set-Content "$evidence/results.json"
    $report = Get-Content "$evidence/profile-report.json" -Raw | ConvertFrom-Json
    $m5 = @($report.actions | Where-Object {$_.id -eq 'runquota.test_execute.t_m5_process_exec_bench_contract'})
    if ($m5.Count -ne 1 -or -not $m5[0].launched) { throw 'The profiled M5 action did not execute' }
    $text = $m5[0].stdout + $m5[0].stderr
    if (-not $text.Contains('cwd-profile phase=wait-end') -or $text -notmatch 'image=[^\r\n]*cwd-profile' -or
        -not $text.Contains('phase=install-hooks-end') -or -not $text.Contains('clock-errors=0') -or
        $text -match 'clock-errors=[1-9]' -or $text -match 'frequency=0') { throw 'Invalid monitor phase evidence' }
    if ($code -ne 0) { $failed = $true }
} finally {
    [IO.File]::WriteAllBytes($fixture, $originalFixture)
    [IO.File]::WriteAllBytes($shim, $originalShim)
    [IO.File]::WriteAllBytes($hooks, $originalHooks)
    $env:REPRO_MONITOR_SHIM_LIB = $originalShimPin
    Remove-Item Env:IO_MON_BUILD_MODE, Env:IO_MON_SHIM_OUT_DIR, Env:IO_MON_SHIM_NIMCACHE_DIR -ErrorAction SilentlyContinue
    & git diff -- tests/integration/t_m5_process_exec_bench_contract.nim > "$evidence/restored-fixture.patch"
}
if ($failed) { throw 'The original bounds or full-suite gates failed; inspect retained comparison evidence' }

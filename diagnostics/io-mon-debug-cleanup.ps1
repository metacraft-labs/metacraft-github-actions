# Real production compiles and unchanged cleanup assertions; no mocks.
# Match the complete CI's debug GCC toolchain, then run on a quiet runner.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'test-logs/debug-cleanup'
New-Item -ItemType Directory -Force $evidence | Out-Null
$env:STACKABLE_HOOKS_SRC = Join-Path $PWD 'nim-stackable-hooks/src'
$env:SHM_QUEUE_SRC = Join-Path $PWD 'nim-shm-queue/src'
$env:SHM_GSET_SRC = Join-Path $PWD 'nim-shm-gset/src'
$env:IO_MON_BUILD_MODE = 'debug'
& git log -1 --format='%H %s' > "$evidence/source.txt"
& nim --version > "$evidence/compiler.txt"
& gcc --version >> "$evidence/compiler.txt"
foreach ($dependency in @('nim-stackable-hooks', 'nim-shm-queue', 'nim-shm-gset')) {
    & git -C $dependency log -1 --format='%H %s' >> "$evidence/source.txt"
}
& bash scripts/build_shim.sh *> "$evidence/build-shim.log"
if ($LASTEXITCODE -ne 0) { throw 'Debug shim build failed' }
$env:REPRO_MONITOR_SHIM_LIB = Join-Path $PWD 'build/lib/librepro_monitor_shim.dll'
$fixtures = @('test_io_mon_cli_exit_status', 'test_io_mon_windows_host_session_scope')
foreach ($fixture in $fixtures) {
    & nim c --threads:on --cc:gcc --hints:off "--out:$evidence/$fixture.exe" "tests/windows/$fixture.nim" *> "$evidence/build-$fixture.log"
    if ($LASTEXITCODE -ne 0) { throw "Debug fixture build failed: $fixture" }
}
$results = @()
foreach ($fixture in $fixtures) {
    for ($round = 1; $round -le 3; $round++) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        & "$evidence/$fixture.exe" *> "$evidence/$fixture-$round.log"
        $code = $LASTEXITCODE
        $watch.Stop()
        $results += @{fixture=$fixture; round=$round; exitCode=$code; seconds=$watch.Elapsed.TotalSeconds}
        $results | ConvertTo-Json | Set-Content "$evidence/results.json"
        Get-Content "$evidence/$fixture-$round.log" -Tail 60
    }
}
if (@($results | Where-Object {$_.exitCode -ne 0}).Count -gt 0) {
    throw 'An unchanged debug fixture failed; inspect its actual cleanup owners'
}

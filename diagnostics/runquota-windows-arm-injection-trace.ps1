# Diagnostic source only. Retain all 100 build actions and every injection deadline.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'build/windows-arm-injection'
New-Item -ItemType Directory -Force $evidence | Out-Null
python "$PSScriptRoot/trace-windows-borrowed-call.py"
if ($LASTEXITCODE) { throw 'Could not instrument the exact source' }
if ($env:RUNQUOTA_BALANCED_CONTEXT -eq 'true') {
    python "$PSScriptRoot/balance-windows-context-sampling.py"
    if ($LASTEXITCODE) { throw 'Could not apply the balanced-sampling control' }
}
git -C nim-stackable-hooks rev-parse HEAD | Set-Content "$evidence/hooks-sha.txt"
git -C nim-stackable-hooks diff | Set-Content "$evidence/hooks-diagnostic.patch"
if ($env:RUNQUOTA_BALANCED_CONTEXT -eq 'true') {
    $savedChild = $env:STACKABLE_HOOKS_CONTROL_CHILD
    try {
        $child = Join-Path $evidence 'borrowed-call-child.exe'
        & nim c --cpu:amd64 --threads:on "--out:$child" "$PSScriptRoot/windows-borrowed-call-child.nim" *> "$evidence/child-build.log"
        if ($LASTEXITCODE) { throw 'Could not build the real x64 borrowed-call child' }
        $env:STACKABLE_HOOKS_CONTROL_CHILD = $child
        foreach ($test in @('test_windows_entry_park_slow_call', 'test_windows_entry_park_thread_locals')) {
            & nim c --cpu:amd64 --threads:on "--out:$evidence/$test.exe" "nim-stackable-hooks/tests/$test.nim" *> "$evidence/$test-build.log"
            if ($LASTEXITCODE) { throw "Could not build $test" }
            & "$evidence/$test.exe" *> "$evidence/$test.log"
            if ($LASTEXITCODE) { throw "$test failed" }
        }
    } finally {
        $env:STACKABLE_HOOKS_CONTROL_CHILD = $savedChild
    }
}
$env:IO_MON_SHIM_OUT_DIR = Join-Path $PWD 'reprobuild/build/lib'
$env:IO_MON_SHIM_NIMCACHE_DIR = Join-Path $PWD 'build/trace-shim-cache'
& bash io-mon/scripts/build_shim.sh *> "$evidence/shim-build.log"
if ($LASTEXITCODE) { throw 'Diagnostic shim build failed' }
Get-FileHash "$env:IO_MON_SHIM_OUT_DIR/librepro_monitor_shim.dll" |
    Format-List | Out-String | Set-Content "$evidence/shim-sha256.txt"
$env:REPROBUILD_MAX_PARALLELISM = '8'
& bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/build.log" repro build --daemon=off --tool-provisioning=tarball "--write-report=$evidence/build.json"
if ($LASTEXITCODE) { throw 'Full monitored compilation failed; retain failure-only context evidence' }
& bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/test.log" repro test --daemon=off --tool-provisioning=tarball "--write-report=$evidence/test.json"
if ($LASTEXITCODE) { throw 'Full monitored execution failed' }

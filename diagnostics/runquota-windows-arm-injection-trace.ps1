# Diagnostic source only. Retain all 100 build actions and every injection deadline.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'build/windows-arm-injection'
New-Item -ItemType Directory -Force $evidence | Out-Null
$hooksSource = (& git -C nim-stackable-hooks rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $env:RUNQUOTA_TRACE_HOOKS_SOURCE -cnotmatch '^[0-9a-f]{40}$' -or $hooksSource -cne $env:RUNQUOTA_TRACE_HOOKS_SOURCE) {
    throw 'This controlled graph requires the exact requested hook source'
}
$runquotaSource = (& git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $env:RUNQUOTA_TRACE_SOURCE -cnotmatch '^[0-9a-f]{40}$' -or $runquotaSource -cne $env:RUNQUOTA_TRACE_SOURCE) {
    throw 'This controlled graph requires the exact requested RunQuota source'
}
@{ runquota = $runquotaSource; hooks = $hooksSource } | ConvertTo-Json | Set-Content "$evidence/source-pins.json"
$parkSource = Join-Path $PWD 'nim-stackable-hooks/src/stackable_hooks/windows_entry_park.nim'
$originalPark = [IO.File]::ReadAllText($parkSource)
$threadLocalFailure = $false
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
        & nim c --cpu:amd64 --threads:on "--out:$child" "$PSScriptRoot/windows_borrowed_call_child.nim" *> "$evidence/child-build.log"
        if ($LASTEXITCODE) { throw 'Could not build the real x64 borrowed-call child' }
        $env:STACKABLE_HOOKS_CONTROL_CHILD = $child
        foreach ($test in @('test_windows_entry_park_slow_call', 'test_windows_entry_park_thread_locals')) {
            & nim c --cpu:amd64 --threads:on "--out:$evidence/$test.exe" "nim-stackable-hooks/tests/$test.nim" *> "$evidence/$test-build.log"
            if ($LASTEXITCODE) { throw "Could not build $test" }
            & "$evidence/$test.exe" *> "$evidence/$test.log"
            if ($LASTEXITCODE) {
                if ($test -ne 'test_windows_entry_park_thread_locals') { throw "$test failed" }
                $threadLocalFailure = $true
                $balancedCode = $LASTEXITCODE
                $balancedPark = [IO.File]::ReadAllText($parkSource)
                $savedTemp = $env:TEMP
                $savedTmp = $env:TMP
                try {
                    # Compare the same assertion with the original source before
                    # attributing its failure to suspended context sampling.
                    [IO.File]::WriteAllText($parkSource, $originalPark)
                    $baselineTemp = Join-Path $evidence 'baseline-tls-temp'
                    New-Item -ItemType Directory -Force $baselineTemp | Out-Null
                    $env:TEMP = $baselineTemp
                    $env:TMP = $baselineTemp
                    & nim c --cpu:amd64 --threads:on "--nimcache:$evidence/baseline-tls-cache" "--out:$evidence/baseline_tls.exe" "nim-stackable-hooks/tests/$test.nim" *> "$evidence/baseline-tls-build.log"
                    if ($LASTEXITCODE) { throw 'Could not build the original TLS control' }
                    & "$evidence/baseline_tls.exe" *> "$evidence/baseline-tls.log"
                    @{original=$LASTEXITCODE; balanced=$balancedCode} | ConvertTo-Json |
                        Set-Content "$evidence/tls-comparison.json"
                } finally {
                    [IO.File]::WriteAllText($parkSource, $balancedPark)
                    $env:TEMP = $savedTemp
                    $env:TMP = $savedTmp
                }
            }
        }
    } finally {
        $env:STACKABLE_HOOKS_CONTROL_CHILD = $savedChild
    }
}
$env:IO_MON_SHIM_OUT_DIR = Join-Path $PWD 'reprobuild/build/lib'
$env:IO_MON_SHIM_NIMCACHE_DIR = Join-Path $PWD 'build/trace-shim-cache'
python "$PSScriptRoot/trace-windows-shim-init.py"
if ($LASTEXITCODE) { throw 'Could not instrument the exact shim initialization' }
python "$PSScriptRoot/trace-windows-hook-transaction.py"
if ($LASTEXITCODE) { throw 'Could not instrument the exact hook transaction' }
git -C nim-stackable-hooks diff | Set-Content "$evidence/hooks-diagnostic.patch"
git -C io-mon diff | Set-Content "$evidence/shim-diagnostic.patch"
& bash io-mon/scripts/build_shim.sh *> "$evidence/shim-build.log"
if ($LASTEXITCODE) { throw 'Diagnostic shim build failed' }
Get-FileHash "$env:IO_MON_SHIM_OUT_DIR/librepro_monitor_shim.dll" |
    Format-List | Out-String | Set-Content "$evidence/shim-sha256.txt"
Copy-Item "$env:IO_MON_SHIM_OUT_DIR/librepro_monitor_shim.dll" $evidence
$objectDump = Get-Command objdump -ErrorAction SilentlyContinue
if ($objectDump) {
    & $objectDump.Source -t "$env:IO_MON_SHIM_OUT_DIR/librepro_monitor_shim.dll" *> "$evidence/shim-symbols.txt"
}
$env:REPROBUILD_MAX_PARALLELISM = '8'
& bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/build.log" repro build --daemon=off --tool-provisioning=tarball "--write-report=$evidence/build.json"
if ($LASTEXITCODE) { throw 'Full monitored compilation failed; retain failure-only context evidence' }
& bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/test.log" repro test --daemon=off --tool-provisioning=tarball "--write-report=$evidence/test.json"
if ($LASTEXITCODE) { throw 'Full monitored execution failed' }
if ($threadLocalFailure) { throw 'TLS regression failed; original comparison and full graph evidence retained' }

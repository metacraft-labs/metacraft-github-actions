# Real original/balanced fixture comparison; no assertion or deadline changes.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PWD '.toolchain/windows/bootstrap-toolchain.ps1')
$null = Invoke-ReproToolchainBootstrap
$evidence = Join-Path $PWD 'build/windows-entry-park-tls'
New-Item -ItemType Directory -Force $evidence | Out-Null
& nim --version *> "$evidence/nim-version.txt"
& gcc -v *> "$evidence/gcc-version.txt"
Copy-Item '.toolchain/windows/toolchain-versions.env' $evidence

# Record how this exact compiler implements an ordinary C thread-local.
# The actual Nim fixture DLLs below retain the stronger, direct evidence.
'__thread unsigned long probe; unsigned long *probe_address(void) { return &probe; }' |
    Set-Content "$evidence/compiler_tls_probe.c"
& gcc -S -o "$evidence/compiler_tls_probe.s" "$evidence/compiler_tls_probe.c"
if ($LASTEXITCODE) { throw 'Could not compile the TLS implementation probe' }

$park = Join-Path $PWD 'nim-stackable-hooks/src/stackable_hooks/windows_entry_park.nim'
$original = [IO.File]::ReadAllText($park)
$savedTemp = $env:TEMP
$savedTmp = $env:TMP
$results = @()
try {
    foreach ($variant in @('original', 'balanced')) {
        if ($variant -eq 'balanced') {
            python "$PSScriptRoot/balance-windows-context-sampling.py"
            if ($LASTEXITCODE) { throw 'Could not apply the balanced control' }
        }
        $caseDir = Join-Path $evidence $variant
        New-Item -ItemType Directory -Force $caseDir | Out-Null
        $env:TEMP = $caseDir
        $env:TMP = $caseDir
        $testExe = Join-Path $caseDir 'tls_test.exe'
        & nim c --cpu:amd64 --threads:on "--nimcache:$caseDir/cache" "--out:$testExe" `
            nim-stackable-hooks/tests/test_windows_entry_park_thread_locals.nim *> "$caseDir/build.log"
        if ($LASTEXITCODE) { throw "Could not compile $variant TLS fixture" }
        & $testExe *> "$caseDir/test.log"
        $results += @{variant=$variant; exitCode=$LASTEXITCODE}
        $results | ConvertTo-Json -AsArray | Set-Content "$evidence/results.json"
        Get-Content "$caseDir/test.log"
        $dll = Join-Path $caseDir 'stackable-hooks-park-tls/park_tls_lib.dll'
        if (-not (Test-Path $dll)) { throw "$variant did not produce its real fixture DLL" }
        & objdump -t -p -d $dll *> "$caseDir/dll-symbols-and-code.txt"
        if ($LASTEXITCODE) { throw "Could not inspect $variant fixture DLL" }
    }
} finally {
    [IO.File]::WriteAllText($park, $original)
    $env:TEMP = $savedTemp
    $env:TMP = $savedTmp
}
if (@($results | Where-Object { $_.exitCode -ne 0 }).Count) {
    throw 'A real TLS fixture failed; both outcomes and DLL evidence are retained'
}

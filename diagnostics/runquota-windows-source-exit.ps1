# No mocks: reuse the exact real RunQuota binaries already compared with both
# shim build modes. Only the shim source changes for the original comparison.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$Target = 'windows-x86_64'
$env:RELEASE_TOOLS = Join-Path $PWD '.release-tools/release-tools'
. "$env:RELEASE_TOOLS/common.ps1"
. './.bootstrap-tools/windows/toolchain-utils.ps1'
. './.bootstrap-tools/windows/ensure-gcc.ps1'
$pins = Read-KeyValueFile -Path './.bootstrap-tools/windows/toolchain-versions.env'
$gccRoot = Ensure-Gcc -Root "$env:RUNNER_TEMP/source-gcc" -Arch x64 -Toolchain $pins
$env:PATH = "$(Join-Path $gccRoot 'bin');$env:PATH"
& gcc --version
& nim --version
# Hold source dependencies at the same pins used to build the retained fixed
# shim. The baseline flake predates its explicit shared-memory root inputs.
& git fetch --depth=1 origin 347c8dbda4671abf7ebbb155a86c4db464ba0ac7
if ($LASTEXITCODE -ne 0) { throw 'Cannot fetch the comparison dependency lock' }
New-Item -ItemType Directory -Force 'build/comparison-pins' | Out-Null
& git show '347c8dbda4671abf7ebbb155a86c4db464ba0ac7:flake.lock' | Set-Content 'build/comparison-pins/flake.lock'
if ($LASTEXITCODE -ne 0) { throw 'Cannot read the comparison dependency lock' }
Push-Location 'build/comparison-pins'
try {
    Get-ReleaseDependency 'stackable-hooks-src' 'STACKABLE_HOOKS_SRC'
    Get-ReleaseDependency 'shm-queue-src' 'SHM_QUEUE_SRC'
    Get-ReleaseDependency 'shm-gset-src' 'SHM_GSET_SRC'
} finally { Pop-Location }
$evidence = Join-Path $PWD 'build/source-exit'
$controls = Join-Path $evidence 'controls'
$env:IO_MON_BUILD_MODE = 'debug'
$env:IO_MON_SHIM_OUT_DIR = 'build/source-exit/original-shim'
$env:IO_MON_SHIM_NIMCACHE_DIR = 'build/nimcache/source-original'
& bash scripts/build_shim.sh *> "$evidence/build-original-shim.log"
if ($LASTEXITCODE -ne 0) { throw 'Original shim compilation failed' }
$originalShim = Join-Path $PWD 'build/source-exit/original-shim/librepro_monitor_shim.dll'
$fixedShim = Join-Path $controls 'debug-shim.dll'
$cli = Join-Path $controls 'cli-fixed.exe'
$reference = Get-Content "$controls/runquota-results.json" -Raw | ConvertFrom-Json
# Same SQLite version/digest as the original production graph.
$sqliteRoot = Join-Path $env:RUNNER_TEMP 'source-exit-sqlite'
New-Item -ItemType Directory -Force $sqliteRoot | Out-Null
Invoke-WebRequest 'https://sqlite.org/2026/sqlite-tools-win-x64-3530400.zip' -OutFile "$sqliteRoot/sqlite.zip"
if ((Get-FileHash "$sqliteRoot/sqlite.zip").Hash -ne 'f46ee2475de4cbe287e6e5f7d43c838796b14e7379cd216bdbb28d391429f9fc') { throw 'SQLite digest mismatch' }
Expand-Archive "$sqliteRoot/sqlite.zip" $sqliteRoot -Force
$env:PATH = "$sqliteRoot;$env:PATH"
$dumpRoot = Join-Path $evidence 'dumps'
New-Item -ItemType Directory -Force $dumpRoot | Out-Null
$results = @()
try {
    foreach ($stem in @('t_ambient_sample_atomicity', 't_host_load_reading_invariants')) {
        $name = "$stem-nim-2.2.10"
        $binary = Join-Path $controls "$name.exe"
        $expected = @($reference | Where-Object { $_.name -eq $name -and $_.mode -eq 'native' })
        if ($expected.Count -ne 1 -or (Get-FileHash $binary).Hash -ne $expected[0].sha256) { throw 'Fixture digest does not match the prior control' }
        $key = "HKLM:\Software\Microsoft\Windows\Windows Error Reporting\LocalDumps\$name.exe"
        New-Item -Force $key | Out-Null
        New-ItemProperty $key -Name DumpFolder -Value $dumpRoot -PropertyType ExpandString -Force | Out-Null
        New-ItemProperty $key -Name DumpType -Value 1 -PropertyType DWord -Force | Out-Null
        foreach ($mode in @('native', 'original', 'fixed-1', 'fixed-2', 'fixed-3')) {
            $prefix = "$evidence/$name-$mode"
            $env:REPRO_MONITOR_SHIM_LIB = if ($mode -eq 'original') { $originalShim } else { $fixedShim }
            [string[]]$argv = if ($mode -eq 'native') { @($binary) } else {
                @($cli, 'run', '--depfile', "$prefix.iomon", '--', $binary)
            }
            & python "$PSScriptRoot/capture-windows-exit.py" $prefix @argv
            if ($LASTEXITCODE -ne 0) { throw 'Process capture failed' }
            Get-Content "$prefix.log"
            $capture = Get-Content "$prefix.json" -Raw | ConvertFrom-Json
            $results += @{name=$name; mode=$mode; exitCode=$capture.exitCode; exitHex=$capture.exitHex; timedOut=$capture.timedOut; sha256=$expected[0].sha256}
            if ((Get-FileHash $binary).Hash -ne $expected[0].sha256) { throw 'Fixture changed during comparison' }
        }
    }
} finally {
    $results | ConvertTo-Json -Depth 5 | Set-Content "$evidence/results.json"
}
if (@($results | Where-Object { $_.mode -ne 'original' -and ($_.timedOut -or $_.exitCode -ne 0) }).Count) { throw 'Native or current-shim comparison failed' }
if (@($results | Where-Object { $_.mode -eq 'original' -and ($_.timedOut -or $_.exitCode -ne 0) }).Count -eq 0) { throw 'Original source did not reproduce the failure; do not attribute it to these source changes' }

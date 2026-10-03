# Same native fixtures with and without real io-mon injection. All original
# assertions remain. A real serialization mutation must fail the timing gate.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$Target = 'windows-x86_64'
$env:RELEASE_TOOLS = Join-Path $PWD '.release-tools/release-tools'
. "$env:RELEASE_TOOLS/common.ps1"
# Match the debug fixture mode used by the Reprobuild test adapter.
$ReleaseFlags = @($ReleaseFlags | Where-Object { $_ -ne '-d:release' })
$root = $PWD.Path
$evidence = Join-Path $root 'build/windows-process-timing'
New-Item -ItemType Directory -Force "$evidence/bin" | Out-Null
& ./scripts/release/pcre-windows.ps1 -Stage $evidence *> "$evidence/build-pcre.log"
$env:PATH = "$evidence/bin;$env:PATH"
$fixtures = @('tests/e2e/t_vmharness_serve_concurrency.nim', 'tests/unit/t_tart_backend.nim')
foreach ($source in $fixtures) {
    $name = [IO.Path]::GetFileNameWithoutExtension($source)
    Invoke-ReleaseNim $source "$evidence/bin/$name.exe" *> "$evidence/build-$name.log"
}
$serverSource = Join-Path $root 'src/vm_harness/serve/server.nim'
$serverOriginal = [IO.File]::ReadAllText($serverSource)
$serverMutant = $serverOriginal.Replace("`r`n", "`n")
$serialAnchor = '        handleConnection(ctx, client, slot)'
if (-not $serverMutant.Contains($serialAnchor)) { throw 'Serial mutation anchor changed' }
$serverMutant = $serverMutant.Replace('proc workerLoop(', "var diagnosticSerialLock: Lock`ninitLock(diagnosticSerialLock)`n`nproc workerLoop(")
$serverMutant = $serverMutant.Replace($serialAnchor, "        withLock diagnosticSerialLock:`n          handleConnection(ctx, client, slot)")
try {
    [IO.File]::WriteAllText($serverSource, $serverMutant)
    & git diff -- src/vm_harness/serve/server.nim > "$evidence/serial-mutation.patch"
    Invoke-ReleaseNim $fixtures[0] "$evidence/bin/serial-concurrency.exe" *> "$evidence/build-serial.log"
} finally { [IO.File]::WriteAllText($serverSource, $serverOriginal) }
$shims = @{}
Push-Location .io-mon
try {
    Get-ReleaseDependency 'stackable-hooks-src' 'STACKABLE_HOOKS_SRC'
    Get-ReleaseDependency 'shm-queue-src' 'SHM_QUEUE_SRC'
    Get-ReleaseDependency 'shm-gset-src' 'SHM_GSET_SRC'
    foreach ($mode in @('debug', 'release')) {
        $env:IO_MON_BUILD_MODE = $mode
        $env:IO_MON_SHIM_OUT_DIR = Join-Path $PWD "build/lib/$mode"
        $env:IO_MON_SHIM_NIMCACHE_DIR = Join-Path $PWD "build/nimcache/shim-$mode"
        & bash scripts/build_shim.sh @ReleaseFlags *> "$evidence/build-shim-$mode.log"
        if ($LASTEXITCODE -ne 0) { throw "Cannot build $mode monitor shim" }
        $shims[$mode] = Join-Path $env:IO_MON_SHIM_OUT_DIR 'librepro_monitor_shim.dll'
        Get-FileHash $shims[$mode] -Algorithm SHA256 | Format-List | Out-File "$evidence/shim-$mode.txt"
    }
    Invoke-ReleaseNim 'cmd/io_mon_snoop.nim' "$evidence/bin/io-mon.exe" *> "$evidence/build-monitor.log"
    & git rev-parse HEAD > "$evidence/monitor-revision.txt"
} finally { Pop-Location }
& git rev-parse HEAD > "$evidence/gosti-revision.txt"
$results = @()
$failed = $false
foreach ($source in $fixtures) {
    $name = [IO.Path]::GetFileNameWithoutExtension($source)
    $binary = "$evidence/bin/$name.exe"
    $hash = (Get-FileHash $binary -Algorithm SHA256).Hash
    foreach ($mode in @('native', 'monitored-debug', 'monitored-release', 'serial-control')) {
        if ($mode -eq 'serial-control' -and $name -ne 't_vmharness_serve_concurrency') { continue }
        $env:VMH_CONC_TEST_THREADS = '4'
        $command = if ($mode -eq 'serial-control') {"$evidence/bin/serial-concurrency.exe"} else {$binary}
        $watch = [Diagnostics.Stopwatch]::StartNew()
        if ($mode.StartsWith('monitored-')) {
            $env:REPRO_MONITOR_SHIM_LIB = $shims[$mode.Substring('monitored-'.Length)]
            & "$evidence/bin/io-mon.exe" run --depfile "$evidence/$name-$mode.iomon" -- $command *> "$evidence/$name-$mode.log"
        } else {
            & $command *> "$evidence/$name-$mode.log"
        }
        $code = $LASTEXITCODE
        $watch.Stop()
        $results += @{fixture=$name; mode=$mode; exitCode=$code; seconds=$watch.Elapsed.TotalSeconds; sha256=(Get-FileHash $command -Algorithm SHA256).Hash}
        Get-Content "$evidence/$name-$mode.log" -Tail 45
        if ($mode -eq 'serial-control') {
            $log = Get-Content "$evidence/$name-$mode.log" -Raw
            if ($code -eq 0 -or -not $log.Contains('Check failed: elapsed < 2.5')) {
                $failed = $true
                Write-Host 'Serial control did not reproduce the dispatch timing regression'
            }
        } elseif ($code -ne 0) { $failed = $true }
        if ((Get-FileHash $binary -Algorithm SHA256).Hash -ne $hash) { throw 'Fixture bytes changed' }
        $results | ConvertTo-Json | Set-Content "$evidence/results.json"
    }
}
if ($failed) { throw 'A required fixture or negative control failed; inspect the retained timings' }

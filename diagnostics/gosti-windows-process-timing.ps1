# Same native fixtures with and without real io-mon injection. All original
# assertions remain. The one-worker arm must reject serialized dispatch.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$Target = 'windows-x86_64'
$env:RELEASE_TOOLS = Join-Path $PWD '.release-tools/release-tools'
. "$env:RELEASE_TOOLS/common.ps1"
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
Push-Location .io-mon
try {
    Get-ReleaseDependency 'stackable-hooks-src' 'STACKABLE_HOOKS_SRC'
    Get-ReleaseDependency 'shm-queue-src' 'SHM_QUEUE_SRC'
    Get-ReleaseDependency 'shm-gset-src' 'SHM_GSET_SRC'
    $env:IO_MON_BUILD_MODE = 'release'
    & bash scripts/build_shim.sh @ReleaseFlags *> "$evidence/build-shim.log"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot build monitor shim' }
    Invoke-ReleaseNim 'cmd/io_mon_snoop.nim' "$evidence/bin/io-mon.exe" *> "$evidence/build-monitor.log"
    $env:REPRO_MONITOR_SHIM_LIB = Join-Path $PWD 'build/lib/librepro_monitor_shim.dll'
    & git rev-parse HEAD > "$evidence/monitor-revision.txt"
} finally { Pop-Location }
& git rev-parse HEAD > "$evidence/gosti-revision.txt"
$results = @()
$failed = $false
foreach ($source in $fixtures) {
    $name = [IO.Path]::GetFileNameWithoutExtension($source)
    $binary = "$evidence/bin/$name.exe"
    $hash = (Get-FileHash $binary -Algorithm SHA256).Hash
    foreach ($mode in @('native', 'monitored', 'serial-control')) {
        if ($mode -eq 'serial-control' -and $name -ne 't_vmharness_serve_concurrency') { continue }
        $env:VMH_CONC_TEST_THREADS = if ($mode -eq 'serial-control') {'1'} else {'4'}
        $watch = [Diagnostics.Stopwatch]::StartNew()
        if ($mode -eq 'monitored') {
            & "$evidence/bin/io-mon.exe" run --depfile "$evidence/$name.iomon" -- $binary *> "$evidence/$name-$mode.log"
        } else {
            & $binary *> "$evidence/$name-$mode.log"
        }
        $code = $LASTEXITCODE
        $watch.Stop()
        $results += @{fixture=$name; mode=$mode; exitCode=$code; seconds=$watch.Elapsed.TotalSeconds; sha256=$hash}
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

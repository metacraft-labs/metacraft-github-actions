# Real process termination, one fixture binary, original and repaired shims.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$Target = 'windows-x86_64'
$env:RELEASE_TOOLS = Join-Path $PWD '.release-tools/release-tools'
. "$env:RELEASE_TOOLS/common.ps1"
Get-ReleaseDependency 'stackable-hooks-src' 'STACKABLE_HOOKS_SRC'
Get-ReleaseDependency 'shm-queue-src' 'SHM_QUEUE_SRC'
Get-ReleaseDependency 'shm-gset-src' 'SHM_GSET_SRC'
$evidence = Join-Path $PWD 'build/windows-termination-status'
New-Item -ItemType Directory -Force $evidence | Out-Null
$binary = Join-Path $evidence 'exit-status.exe'
Invoke-ReleaseNim 'tests/windows/test_io_mon_windows_exit_status.nim' $binary
$hash = (Get-FileHash $binary -Algorithm SHA256).Hash
$source = Join-Path $PWD 'src/io_mon/shim/windows_interpose.nim'
$fixed = [IO.File]::ReadAllText($source)
$old = $fixed.Replace('cast[int32](uint32(ctx.args[1] and 0xFFFFFFFF''u64))', 'int32(uint32(ctx.args[1] and 0xFFFFFFFF''u64))')
if ($old -eq $fixed) { throw 'Termination control anchor changed' }
$results = @()
try {
    foreach ($variant in @('old','fixed')) {
        [IO.File]::WriteAllText($source, $(if ($variant -eq 'old') {$old} else {$fixed}))
        $env:IO_MON_BUILD_MODE = 'release'
        $env:IO_MON_SHIM_OUT_DIR = Join-Path $evidence $variant
        $env:IO_MON_SHIM_NIMCACHE_DIR = Join-Path $PWD "build/nimcache/termination-$variant"
        & bash scripts/build_shim.sh @ReleaseFlags *> "$evidence/build-$variant.log"
        if ($LASTEXITCODE -ne 0) { throw "Cannot compile $variant shim" }
        $env:REPRO_MONITOR_SHIM_LIB = Join-Path $env:IO_MON_SHIM_OUT_DIR 'librepro_monitor_shim.dll'
        $rounds = if ($variant -eq 'old') {1} else {3}
        for ($round = 1; $round -le $rounds; $round++) {
            & python "$PSScriptRoot/capture-windows-exit.py" "$evidence/$variant-$round" $binary
            if ($LASTEXITCODE -ne 0) { throw 'Process capture failed' }
            $result = Get-Content "$evidence/$variant-$round.json" -Raw | ConvertFrom-Json
            $results += @{variant=$variant; round=$round; exitCode=$result.exitCode; timedOut=$result.timedOut; sha256=$hash}
            Get-Content "$evidence/$variant-$round.log" -Tail 45
            if ($result.timedOut) { throw 'Fixture timed out' }
            if ($variant -eq 'old' -and $result.exitCode -eq 0) { throw 'Original shim unexpectedly passed' }
            if ($variant -eq 'fixed' -and $result.exitCode -ne 0) { throw 'Repaired shim failed' }
            if ((Get-FileHash $binary -Algorithm SHA256).Hash -ne $hash) { throw 'Fixture bytes changed' }
        }
    }
} finally {
    [IO.File]::WriteAllText($source,$fixed)
    $results | ConvertTo-Json | Set-Content "$evidence/results.json"
}

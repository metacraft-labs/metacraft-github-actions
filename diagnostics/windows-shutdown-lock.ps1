$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PWD '.toolchain/windows/bootstrap-toolchain.ps1')
$null = Invoke-ReproToolchainBootstrap
$evidence = Join-Path $PWD 'build/windows-shutdown-lock'
New-Item -ItemType Directory -Force $evidence, 'build/windows-runtime-phases', 'build/windows-arm-injection' | Out-Null
$pins = @{
    '.toolchain' = 'c14b1e618d7c4b64476d89792e80b8e8f10b8a52'
    'nim-stackable-hooks' = 'def2464b2d282c7c1a982689a25953e1d4501f93'
    'io-mon' = '5e71adf033b860c0fdbe13dda4320cf4a580f632'
    'nim-shm-queue' = '02f442ac12ce2587d9c053c527041097af38609f'
    'nim-shm-gset' = '1caac0e0ec48f025c69c6370b63017c47c18c96e'
}
foreach ($repo in $pins.Keys) {
    $actual = (& git -C $repo rev-parse HEAD).Trim()
    if ($LASTEXITCODE -or $actual -ne $pins[$repo]) { throw "Unexpected source for $repo" }
}
$pins | ConvertTo-Json | Set-Content "$evidence/source-pins.json"
# The observer locates its real control module by this executable name.
foreach ($pair in @(@('windows-process-phase.c', 'windows-process-phase'), @('windows-shutdown-lock-child.c', 'child'))) {
    & gcc -Wall -Wextra -Werror "$PSScriptRoot/$($pair[0])" -o "$evidence/$($pair[1]).exe" *> "$evidence/$($pair[1])-build.log"
    if ($LASTEXITCODE) { throw "Could not build $($pair[1])" }
}
& "$evidence/windows-process-phase.exe" --control *> "$evidence/observer-control.log"
if ($LASTEXITCODE) { throw 'Real observer control failed' }
& "$evidence/windows-process-phase.exe" --control-negative *> "$evidence/observer-negative.log"
if ($LASTEXITCODE -ne 13 -or (Get-Content -Raw "$evidence/observer-negative.log") -notmatch 'phase=322') {
    throw 'Wrong-phase control did not observe and reject phase 322'
}
& nim c --cpu:amd64 --threads:on --path:io-mon/src --path:nim-stackable-hooks/src --path:nim-shm-queue/src --path:nim-shm-gset/src "--out:$evidence/capture.exe" "$PSScriptRoot/windows_shutdown_capture.nim" *> "$evidence/capture-build.log"
if ($LASTEXITCODE) { throw 'Capture verifier did not compile' }
$originals = @{}
foreach ($path in @('io-mon/src/io_mon/shim/windows_interpose.nim', 'io-mon/src/io_mon/writer.nim')) {
    $originals[$path] = [IO.File]::ReadAllBytes((Join-Path $PWD $path))
}
$outcomes = @()
foreach ($variant in @('original', 'guarded')) {
    foreach ($path in $originals.Keys) { [IO.File]::WriteAllBytes((Join-Path $PWD $path), $originals[$path]) }
    $folder = Join-Path $evidence $variant
    New-Item -ItemType Directory -Force $folder | Out-Null
    python "$PSScriptRoot/trace-windows-shim-init.py"
    if ($LASTEXITCODE) { throw 'Initialization observation failed to apply' }
    python "$PSScriptRoot/trace-windows-shim-exit.py"
    if ($LASTEXITCODE) { throw 'Shutdown observation failed to apply' }
    $patchArgs = @()
    if ($variant -eq 'guarded') { $patchArgs += '--guard-late-flush' }
    python "$PSScriptRoot/schedule-windows-shutdown-lock.py" @patchArgs
    if ($LASTEXITCODE) { throw 'Real lock schedule failed to apply' }
    git -C io-mon diff | Set-Content "$folder/io-mon.patch"
    $env:IO_MON_SHIM_OUT_DIR = $folder -replace '\\', '/'
    $env:IO_MON_SHIM_NIMCACHE_DIR = (Join-Path $PWD "build/shutdown-cache/$variant") -replace '\\', '/'
    & bash io-mon/scripts/build_shim.sh --cpu:amd64 *> "$folder/shim-build.log"
    if ($LASTEXITCODE) { throw "Could not build $variant" }
    Get-FileHash "$folder/librepro_monitor_shim.dll" | Format-List | Out-String | Set-Content "$folder/shim-sha256.txt"
    & python "$PSScriptRoot/windows-shutdown-lock.py" $folder $variant
    $outcomes += @{ variant = $variant; exitCode = $LASTEXITCODE }
    $outcomes | ConvertTo-Json -AsArray | Set-Content "$evidence/comparison.json"
}
if ($outcomes | Where-Object { $_.exitCode -ne 0 }) { throw 'Controlled exit comparison did not match its assertions' }

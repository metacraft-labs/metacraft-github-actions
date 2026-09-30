$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PWD '.toolchain/windows/bootstrap-toolchain.ps1')
$null = Invoke-ReproToolchainBootstrap
$evidence = Join-Path $PWD 'build/windows-shim-build-mode'
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
$assembler = (Get-Command as.exe).Source
$driver = Join-Path $evidence 'parent.exe'
& nim c --cpu:amd64 --threads:on --mm:orc --path:nim-stackable-hooks/src --path:io-mon/src "--out:$driver" "$PSScriptRoot/windows_borrowed_assembler.nim" *> "$evidence/parent-build.log"
if ($LASTEXITCODE) { throw 'Could not build the real injector parent' }
Get-FileHash $driver, $assembler | Format-List | Out-String | Set-Content "$evidence/inputs-sha256.txt"
foreach ($mode in @('debug', 'release')) {
    $folder = Join-Path $evidence $mode
    New-Item -ItemType Directory -Force $folder | Out-Null
    $env:IO_MON_BUILD_MODE = $mode
    $env:IO_MON_SHIM_OUT_DIR = $folder -replace '\\', '/'
    $env:IO_MON_SHIM_NIMCACHE_DIR = (Join-Path $PWD "build/build-mode-cache/$mode") -replace '\\', '/'
    & bash io-mon/scripts/build_shim.sh --cpu:amd64 *> "$folder/shim-build.log"
    if ($LASTEXITCODE) { throw "Could not build $mode" }
    Get-FileHash "$folder/librepro_monitor_shim.dll" | Format-List | Out-String | Set-Content "$folder/shim-sha256.txt"
}
& python "$PSScriptRoot/windows-shim-build-mode.py" $driver $assembler $evidence
if ($LASTEXITCODE) { throw 'A real assembler or capture assertion failed' }

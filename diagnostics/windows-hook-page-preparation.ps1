$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PWD '.toolchain/windows/bootstrap-toolchain.ps1')
$null = Invoke-ReproToolchainBootstrap
$evidence = Join-Path $PWD 'build/windows-hook-page-preparation'
New-Item -ItemType Directory -Force $evidence, 'build/windows-arm-injection' | Out-Null
$pins = @{
    '.toolchain' = 'c14b1e618d7c4b64476d89792e80b8e8f10b8a52'
    'nim-stackable-hooks' = '8f4d806ce1ae58e6b4292fed92944171eff4f7a2'
    'io-mon' = '5e71adf033b860c0fdbe13dda4320cf4a580f632'
    'nim-shm-queue' = '02f442ac12ce2587d9c053c527041097af38609f'
    'nim-shm-gset' = '1caac0e0ec48f025c69c6370b63017c47c18c96e'
}
foreach ($repo in $pins.Keys) {
    $actual = git -C $repo rev-parse HEAD
    if ($LASTEXITCODE -or $actual -ne $pins[$repo]) { throw "Unexpected source for $repo`: $actual" }
}
$pins | ConvertTo-Json | Set-Content "$evidence/source-pins.json"
Get-CimInstance Win32_ComputerSystem | Select-Object NumberOfLogicalProcessors, TotalPhysicalMemory |
    ConvertTo-Json | Set-Content "$evidence/host-capacity.json"
$assembler = (Get-Command as.exe).Source
Get-FileHash $assembler | Format-List | Out-String | Set-Content "$evidence/assembler-sha256.txt"
& nim --version | Set-Content "$evidence/nim-version.txt"
& gcc --version | Set-Content "$evidence/gcc-version.txt"

# Both variants use exactly the same failure observer and parent executable.
python "$PSScriptRoot/trace-windows-borrowed-call.py"
if ($LASTEXITCODE) { throw 'Could not instrument the pinned injector' }
$driver = Join-Path $evidence 'parent.exe'
& nim c --cpu:amd64 --threads:on --mm:orc --path:nim-stackable-hooks/src --path:io-mon/src "--out:$driver" "$PSScriptRoot/windows_borrowed_assembler.nim" *> "$evidence/parent-build.log"
if ($LASTEXITCODE) { throw 'Could not build the real injector parent' }
Get-FileHash $driver | Format-List | Out-String | Set-Content "$evidence/parent-sha256.txt"

$originals = @{}
foreach ($path in @(
    'io-mon/src/io_mon/shim/windows_interpose.nim',
    'nim-stackable-hooks/src/stackable_hooks/inline_hook/windows/install_windows.c',
    'nim-stackable-hooks/src/stackable_hooks/inline_hook/windows/rel32_fixup.c'
)) {
    $originals[$path] = [System.IO.File]::ReadAllBytes((Join-Path $PWD $path))
}
$outcomes = @()
foreach ($variant in @('original', 'prepared')) {
    foreach ($path in $originals.Keys) {
        [System.IO.File]::WriteAllBytes((Join-Path $PWD $path), $originals[$path])
    }
    $folder = Join-Path $evidence $variant
    New-Item -ItemType Directory -Force $folder | Out-Null
    $env:RUNQUOTA_PREPARE_HOOK_PROTECTION = if ($variant -eq 'prepared') { 'true' } else { 'false' }
    python "$PSScriptRoot/trace-windows-shim-init.py"
    if ($LASTEXITCODE) { throw 'Could not instrument shim initialization' }
    python "$PSScriptRoot/trace-windows-hook-transaction.py"
    if ($LASTEXITCODE) { throw 'Could not instrument the hook transaction' }
    Copy-Item build/windows-arm-injection/init-phases.json "$folder/init-phases.json"
    git -C nim-stackable-hooks diff | Set-Content "$folder/hooks.patch"
    git -C io-mon diff | Set-Content "$folder/io-mon.patch"
    $env:IO_MON_SHIM_OUT_DIR = ($folder -replace '\\', '/')
    $env:IO_MON_SHIM_NIMCACHE_DIR = ((Join-Path $PWD "build/page-preparation-cache/$variant") -replace '\\', '/')
    & bash io-mon/scripts/build_shim.sh --cpu:amd64 *> "$folder/shim-build.log"
    if ($LASTEXITCODE) { throw "Could not build the $variant shim" }
    $shim = Join-Path $folder 'librepro_monitor_shim.dll'
    Get-FileHash $shim | Format-List | Out-String | Set-Content "$folder/shim-sha256.txt"
    & python "$PSScriptRoot/windows-borrowed-assembler.py" $driver $assembler $shim $folder --samples 512 --workers 32
    $probeExit = $LASTEXITCODE
    $outcomes += @{ variant = $variant; exitCode = $probeExit }
    $outcomes | ConvertTo-Json -AsArray | Set-Content "$evidence/comparison.json"
    # An original failure is evidence for the control, so still run the repair.
}
if (($outcomes | Where-Object variant -eq 'prepared').exitCode -ne 0) {
    throw 'The prepared variant failed a real assembler or capture assertion'
}
if (($outcomes | Where-Object variant -eq 'original').exitCode -eq 0) {
    Write-Warning 'The original did not reproduce: this comparison alone cannot establish a repair.'
}

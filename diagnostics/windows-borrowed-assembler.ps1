$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PWD '.toolchain/windows/bootstrap-toolchain.ps1')
$null = Invoke-ReproToolchainBootstrap
$evidence = Join-Path $PWD 'build/windows-borrowed-assembler'
New-Item -ItemType Directory -Force $evidence | Out-Null
$assembler = (Get-Command as.exe).Source
$shim = $env:REPRO_PROBE_SHIM
Get-FileHash $assembler, $shim | Format-List | Out-String | Set-Content "$evidence/inputs-sha256.txt"
python "$PSScriptRoot/trace-windows-borrowed-call.py"
if ($LASTEXITCODE) { throw 'Could not instrument the pinned injector' }
git -C nim-stackable-hooks diff | Set-Content "$evidence/parent-diagnostic.patch"
$driver = Join-Path $evidence 'parent.exe'
& nim c --cpu:amd64 --threads:on --mm:orc --path:nim-stackable-hooks/src --path:io-mon/src "--out:$driver" "$PSScriptRoot/windows_borrowed_assembler.nim" *> "$evidence/parent-build.log"
if ($LASTEXITCODE) { throw 'Could not build the real injector parent' }
& python "$PSScriptRoot/windows-borrowed-assembler.py" $driver $assembler $shim $evidence
if ($LASTEXITCODE) { throw 'A real assembler launch or capture assertion failed' }

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = $PWD.Path
$evidence = Join-Path $root 'test-logs/thread-snapshots'
New-Item -ItemType Directory -Force $evidence | Out-Null
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$installation = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'No x64 Visual C++ toolchain found' }
$vcvars = Join-Path $installation 'VC/Auxiliary/Build/vcvars64.bat'
$source = Join-Path $PSScriptRoot 'windows-thread-snapshots.c'
$binary = Join-Path $evidence 'thread-snapshots.exe'
$batch = Join-Path $evidence 'compile.cmd'
# Build an actual x64 PE on both hosts; the program checks its loaded PE header.
@"
@echo off
call "$vcvars"
if errorlevel 1 exit /b 1
cl /nologo /std:c11 /W4 /WX /O2 "$source" /Fe:"$binary" /Fo:"$evidence/thread-snapshots.obj"
exit /b %errorlevel%
"@ | Set-Content $batch -Encoding ascii
& cmd /d /c $batch *> "$evidence/build.log"
if ($LASTEXITCODE -ne 0) { Get-Content "$evidence/build.log"; throw 'Snapshot diagnostic did not compile' }
Get-FileHash $binary -Algorithm SHA256 | Format-List > "$evidence/binary-sha256.txt"
"Runner $env:RUNNER_OS $env:RUNNER_ARCH; source $(& git rev-parse HEAD)" > "$evidence/source.txt"
& $binary $env:RUNNER_ARCH *> "$evidence/results.log"
$code = $LASTEXITCODE
Get-Content "$evidence/results.log"
if ($code -ne 0) { throw "Real peer enumeration failed: $code" }

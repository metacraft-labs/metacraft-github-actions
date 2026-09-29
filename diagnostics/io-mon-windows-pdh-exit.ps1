$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$Target = 'windows-x86_64'
$env:RELEASE_TOOLS = Join-Path $PWD '.release-tools/release-tools'
. "$env:RELEASE_TOOLS/common.ps1"
Get-ReleaseDependency 'stackable-hooks-src' 'STACKABLE_HOOKS_SRC'
Get-ReleaseDependency 'shm-queue-src' 'SHM_QUEUE_SRC'
Get-ReleaseDependency 'shm-gset-src' 'SHM_GSET_SRC'
$evidence = Join-Path $PWD 'build/pdh-exit'
New-Item -ItemType Directory -Force $evidence | Out-Null
# Compile from a path under io-mon so its actual config.nims supplies paths.
Copy-Item "$PSScriptRoot/io-mon-windows-pdh-exit.nim" 'tests/windows/pdh_exit_probe.nim'
Invoke-ReleaseNim 'tests/windows/pdh_exit_probe.nim' "$evidence/pdh-exit.exe"
$env:IO_MON_BUILD_MODE = 'release'
$env:IO_MON_SHIM_NIMCACHE_DIR = Join-Path $PWD 'build/nimcache/pdh-shim'
& bash scripts/build_shim.sh @ReleaseFlags *> "$evidence/build-shim.log"
if ($LASTEXITCODE -ne 0) { throw 'Shim build failed' }
$env:REPRO_MONITOR_SHIM_LIB = Join-Path $PWD 'build/lib/librepro_monitor_shim.dll'
& python "$PSScriptRoot/capture-windows-exit.py" "$evidence/probe" "$evidence/pdh-exit.exe"
if ($LASTEXITCODE -ne 0) { throw 'Process capture failed' }
Get-Content "$evidence/probe.log"
$result = Get-Content "$evidence/probe.json" -Raw | ConvertFrom-Json
if ($result.timedOut -or $result.exitCode -ne 0) { throw 'PDH exit control failed' }

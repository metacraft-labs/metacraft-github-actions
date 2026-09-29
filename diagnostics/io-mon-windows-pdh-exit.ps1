$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$Target = 'windows-x86_64'
$env:RELEASE_TOOLS = Join-Path $PWD '.release-tools/release-tools'
. "$env:RELEASE_TOOLS/common.ps1"
if ($env:DIAGNOSTIC_CC -eq 'gcc') {
    . './.bootstrap-tools/windows/toolchain-utils.ps1'
    . './.bootstrap-tools/windows/ensure-gcc.ps1'
    $pins = Read-KeyValueFile -Path './.bootstrap-tools/windows/toolchain-versions.env'
    $gccRoot = Ensure-Gcc -Root "$env:RUNNER_TEMP/pdh-gcc" -Arch x64 -Toolchain $pins
    $gccBin = Join-Path $gccRoot 'bin'
    $env:PATH = "$gccBin;$env:PATH"
    $gcc = Join-Path $gccBin 'gcc.exe'
    & $gcc --version
    $ReleaseFlags = @('-d:release','--threads:on','--cpu:amd64','--cc:gcc',"--gcc.exe:$gcc","--gcc.linkerexe:$gcc")
}
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
# Exercise the actual CLI with one unchanged child-process fixture. Restoring
# the former entry point must expose the defect before the repaired one passes.
$cliSource = 'cmd/io_mon_snoop.nim'
$fixedSource = Get-Content $cliSource -Raw
$anchor = '  let code = runFsSnoopCli(ProgramName, args)'
$offset = $fixedSource.IndexOf($anchor, [StringComparison]::Ordinal)
if ($offset -lt 0) { throw 'Missing guarded CLI fix anchor' }
Invoke-ReleaseNim 'tests/windows/test_io_mon_cli_exit_status.nim' "$evidence/cli-exit-fixture.exe"
$fixtureHash = (Get-FileHash "$evidence/cli-exit-fixture.exe").Hash
try {
    $originalSource = $fixedSource.Substring(0, $offset) + "  quit(runFsSnoopCli(ProgramName, args))`n"
    Set-Content $cliSource $originalSource -NoNewline
    Invoke-ReleaseNim $cliSource "$evidence/cli-original.exe"
} finally {
    Set-Content $cliSource $fixedSource -NoNewline
}
Invoke-ReleaseNim $cliSource "$evidence/cli-fixed.exe"
$env:IO_MON_EXIT_STATUS_CLI = "$evidence/cli-original.exe"
& python "$PSScriptRoot/capture-windows-exit.py" "$evidence/cli-original-control" "$evidence/cli-exit-fixture.exe"
if ($LASTEXITCODE -ne 0) { throw 'Original CLI capture failed' }
Get-Content "$evidence/cli-original-control.log"
$original = Get-Content "$evidence/cli-original-control.json" -Raw | ConvertFrom-Json
if ($original.timedOut -or $original.exitCode -eq 0) { throw 'Original CLI did not reproduce the defect' }
$env:IO_MON_EXIT_STATUS_CLI = "$evidence/cli-fixed.exe"
foreach ($attempt in 1..3) {
    $prefix = "$evidence/cli-fixed-control-$attempt"
    & python "$PSScriptRoot/capture-windows-exit.py" $prefix "$evidence/cli-exit-fixture.exe"
    if ($LASTEXITCODE -ne 0) { throw 'Fixed CLI capture failed' }
    Get-Content "$prefix.log"
    $fixed = Get-Content "$prefix.json" -Raw | ConvertFrom-Json
    if ($fixed.timedOut -or $fixed.exitCode -ne 0) { throw 'Fixed CLI status control failed' }
}
if ((Get-FileHash "$evidence/cli-exit-fixture.exe").Hash -ne $fixtureHash) { throw 'CLI fixture changed between controls' }
Remove-Item Env:IO_MON_EXIT_STATUS_CLI
& python "$PSScriptRoot/capture-windows-exit.py" "$evidence/probe" "$evidence/pdh-exit.exe"
if ($LASTEXITCODE -ne 0) { throw 'Process capture failed' }
Get-Content "$evidence/probe.log"
$result = Get-Content "$evidence/probe.json" -Raw | ConvertFrom-Json
if ($result.timedOut -or $result.exitCode -ne 0) { throw 'PDH exit control failed' }

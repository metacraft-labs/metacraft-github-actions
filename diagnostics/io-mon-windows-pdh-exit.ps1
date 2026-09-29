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
if ($env:DIAGNOSTIC_RUNQUOTA -eq '1') {
    # Same SQLite release and digest as the production package catalog.
    $sqliteRoot = Join-Path $env:RUNNER_TEMP 'exit-control-sqlite'
    New-Item -ItemType Directory -Force $sqliteRoot | Out-Null
    $archive = "$sqliteRoot/sqlite.zip"
    Invoke-WebRequest 'https://sqlite.org/2026/sqlite-tools-win-x64-3530400.zip' -OutFile $archive
    if ((Get-FileHash $archive -Algorithm SHA256).Hash -ne 'f46ee2475de4cbe287e6e5f7d43c838796b14e7379cd216bdbb28d391429f9fc') { throw 'SQLite archive digest mismatch' }
    Expand-Archive $archive $sqliteRoot -Force
    $env:PATH = "$sqliteRoot;$env:PATH"
    & "$sqliteRoot/sqlite3.exe" --version
    if ($LASTEXITCODE -ne 0) { throw 'SQLite runtime unavailable' }
    # Reprobuild c14b1e61 uses Nim 2.2.10 for graph test compilation, while
    # source bootstrap and releases use 2.2.8. Hold the shim fixed and test both.
    $nimRoot = Join-Path $env:RUNNER_TEMP 'exit-control-nim-2.2.10'
    New-Item -ItemType Directory -Force $nimRoot | Out-Null
    $nimArchive = "$nimRoot/nim.zip"
    Invoke-WebRequest 'https://nim-lang.org/download/nim-2.2.10_x64.zip' -OutFile $nimArchive
    if ((Get-FileHash $nimArchive -Algorithm SHA256).Hash -ne 'fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f') { throw 'Nim archive digest mismatch' }
    Expand-Archive $nimArchive $nimRoot -Force
    $nimVersions = @(
        @{version='2.2.8'; executable=$env:RELEASE_NIM},
        @{version='2.2.10'; executable="$nimRoot/nim-2.2.10/bin/nim.exe"}
    )
    $sources = @('libs/runquota_observation_store/tests/t_ambient_sample_atomicity.nim', 'tests/integration/t_host_load_reading_invariants.nim')
    $results = @()
    Push-Location '.runquota'
    try {
        Get-ReleaseDependency 'nim-shm-lease' 'SHM_LEASE_SRC'
        # Ordinary buildNimUnittest uses debug mode, threads on and all checks.
        $ReleaseFlags = @($ReleaseFlags | Where-Object { $_ -ne '-d:release' })
        $ReleaseFlags | ConvertTo-Json | Set-Content "$evidence/runquota-compiler.json"
        foreach ($nimVersion in $nimVersions) {
          $env:RELEASE_NIM = $nimVersion.executable
          & $env:RELEASE_NIM --version
          if ($LASTEXITCODE -ne 0) { throw 'Nim compiler unavailable' }
          foreach ($source in $sources) {
            $name = [IO.Path]::GetFileNameWithoutExtension($source) + '-nim-' + $nimVersion.version
            $binary = "$evidence/$name.exe"
            Invoke-ReleaseNim $source $binary
            $hash = (Get-FileHash $binary).Hash
            foreach ($mode in @('native', 'monitored')) {
                $prefix = "$evidence/$name-$mode"
                [string[]]$argv = if ($mode -eq 'native') { @($binary) } else {
                    @("$evidence/cli-fixed.exe", 'run', '--depfile', "$prefix.iomon", '--', $binary)
                }
                & python "$PSScriptRoot/capture-windows-exit.py" $prefix @argv
                if ($LASTEXITCODE -ne 0) { throw 'RunQuota process capture failed' }
                Get-Content "$prefix.log"
                $capture = Get-Content "$prefix.json" -Raw | ConvertFrom-Json
                $results += @{name=$name; mode=$mode; exitCode=$capture.exitCode; exitHex=$capture.exitHex; timedOut=$capture.timedOut; sha256=$hash}
                if ((Get-FileHash $binary).Hash -ne $hash) { throw 'RunQuota fixture changed during comparison' }
            }
          }
        }
    } finally {
        Pop-Location
        $results | ConvertTo-Json -Depth 5 | Set-Content "$evidence/runquota-results.json"
    }
    if (@($results | Where-Object { $_.timedOut -or $_.exitCode -ne 0 }).Count) { throw 'RunQuota exit control failed' }
}

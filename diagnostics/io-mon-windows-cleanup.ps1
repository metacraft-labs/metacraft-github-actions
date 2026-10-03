# Real fixtures and Restart Manager queries; no mocks or process termination.
# Preserve all assertions, the 30-second cleanup bound, and every failing exit.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$Target = 'windows-x86_64'
$env:RELEASE_TOOLS = Join-Path $PWD '.release-tools/release-tools'
. "$env:RELEASE_TOOLS/common.ps1"
Get-ReleaseDependency 'stackable-hooks-src' 'STACKABLE_HOOKS_SRC'
Get-ReleaseDependency 'shm-queue-src' 'SHM_QUEUE_SRC'
Get-ReleaseDependency 'shm-gset-src' 'SHM_GSET_SRC'
$evidence = Join-Path $PWD 'build/windows-cleanup-evidence'
New-Item -ItemType Directory -Force $evidence | Out-Null
$helper = Join-Path $PWD 'tests/helpers/fixture_cleanup.nim'
$config = Join-Path $PWD 'config.nims'
$originalHelper = [IO.File]::ReadAllText($helper)
$originalConfig = [IO.File]::ReadAllText($config)
$diagnosticHelper = $originalHelper.Replace("`r`n", "`n")
$needle = "        if getMonoTime() >= deadline:`n          raise"
if (-not $diagnosticHelper.Contains($needle)) { throw 'Cleanup diagnostic anchor changed' }
$replacement = @'
        if getMonoTime() >= deadline:
          echo "DIAGNOSTIC original cleanup error: ", getCurrentExceptionMsg()
          try:
            diagnosticCleanupOwners(path)
          except CatchableError as diagnosticError:
            echo "DIAGNOSTIC query failed: ", diagnosticError.msg
          raise
'@
$owners = [IO.File]::ReadAllText("$PSScriptRoot/windows_file_owners.nim")
$results = @()
$failed = $false
try {
    [IO.File]::WriteAllText($helper, $owners + "`n" + $diagnosticHelper.Replace($needle, $replacement))
    # The fixtures build private children themselves. Give those real compiles
    # the same pinned compiler as their parent; retain their private paths.
    $compiler = $env:RELEASE_CC.Replace('\', '/')
    $compilerConfig = @"

switch("cc", "clang")
switch("clang.exe", "$compiler")
switch("clang.linkerexe", "$compiler")
switch("cpu", "amd64")
"@
    [IO.File]::WriteAllText($config, $originalConfig + $compilerConfig)
    & git diff -- tests/helpers/fixture_cleanup.nim config.nims > "$evidence/source.patch"
    & git rev-parse HEAD > "$evidence/source-revision.txt"
    & $env:RELEASE_NIM --version > "$evidence/compiler.txt"
    & $env:RELEASE_CC --version >> "$evidence/compiler.txt"
    $env:IO_MON_BUILD_MODE = 'release'
    & bash scripts/build_shim.sh @ReleaseFlags *> "$evidence/build-shim.log"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot compile shipping shim' }
    $env:REPRO_MONITOR_SHIM_LIB = Join-Path $PWD 'build/lib/librepro_monitor_shim.dll'
    foreach ($fixture in @('test_io_mon_cli_exit_status', 'test_io_mon_windows_host_session_scope')) {
        $binary = Join-Path $evidence "$fixture.exe"
        Invoke-ReleaseNim "tests/windows/$fixture.nim" $binary *> "$evidence/build-$fixture.log"
        $hash = (Get-FileHash $binary -Algorithm SHA256).Hash
        for ($round = 1; $round -le 3; $round++) {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            & $binary *> "$evidence/$fixture-$round.log"
            $code = $LASTEXITCODE
            $watch.Stop()
            $results += @{fixture=$fixture; round=$round; exitCode=$code; seconds=$watch.Elapsed.TotalSeconds; sha256=$hash}
            Get-Content "$evidence/$fixture-$round.log" -Tail 60
            if ($code -ne 0) { $failed = $true }
        }
    }
} finally {
    [IO.File]::WriteAllText($helper, $originalHelper)
    [IO.File]::WriteAllText($config, $originalConfig)
    $results | ConvertTo-Json | Set-Content "$evidence/results.json"
}
if ($failed) { throw 'A real fixture failed; see the retained original error and owner evidence' }

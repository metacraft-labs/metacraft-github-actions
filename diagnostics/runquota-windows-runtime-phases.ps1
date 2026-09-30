$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'build/windows-runtime-phases'
New-Item -ItemType Directory -Force $evidence, 'build/windows-arm-injection' | Out-Null
$expected = @{
    '.' = '33add18739814c3886da1f69f8a4e18ab1e36faa'
    'nim-stackable-hooks' = 'def2464b2d282c7c1a982689a25953e1d4501f93'
    'io-mon' = '5e71adf033b860c0fdbe13dda4320cf4a580f632'
}
foreach ($repo in $expected.Keys) {
    $actual = (& git -C $repo rev-parse HEAD).Trim()
    if ($LASTEXITCODE -or $actual -ne $expected[$repo]) { throw "Wrong source for $repo" }
}
$expected | ConvertTo-Json | Set-Content "$evidence/source-pins.json"
$compiler = $env:REPRO_BOOTSTRAP_CC
if (-not $compiler -or -not (Test-Path $compiler)) { throw 'Missing pinned compiler' }
& $compiler -Wall -Wextra -Werror "$PSScriptRoot/windows-process-phase.c" -o "$evidence/windows-process-phase.exe" *> "$evidence/observer-build.log"
if ($LASTEXITCODE) { throw 'Observer did not compile' }
& "$evidence/windows-process-phase.exe" --control *> "$evidence/observer-control.log"
if ($LASTEXITCODE) { throw 'Observer did not read the real child phase and preserve its life' }
& "$evidence/windows-process-phase.exe" --control-negative *> "$evidence/observer-negative-control.log"
if ($LASTEXITCODE -ne 13) { throw 'Observer did not reject the real child with a different phase' }

# Add the existing diagnostic phase exports; hook protection remains original.
$env:RUNQUOTA_PREPARE_HOOK_PROTECTION = 'false'
python "$PSScriptRoot/trace-windows-borrowed-call.py"
if ($LASTEXITCODE) { throw 'Borrowed-call observer failed to apply' }
python "$PSScriptRoot/trace-windows-shim-init.py"
if ($LASTEXITCODE) { throw 'Initialization phase exports failed to apply' }
python "$PSScriptRoot/trace-windows-shim-exit.py"
if ($LASTEXITCODE) { throw 'Shutdown phase exports failed to apply' }
python "$PSScriptRoot/trace-windows-hook-transaction.py"
if ($LASTEXITCODE) { throw 'Hook phase exports failed to apply' }
$env:IO_MON_SHIM_OUT_DIR = Join-Path $PWD 'reprobuild/build/lib'
$env:IO_MON_SHIM_NIMCACHE_DIR = Join-Path $PWD 'build/runtime-phase-shim-cache'
$env:IO_MON_BUILD_MODE = 'debug'
& bash io-mon/scripts/build_shim.sh *> "$evidence/shim-build.log"
if ($LASTEXITCODE) { throw 'Diagnostic shim did not compile' }
Get-FileHash "$env:IO_MON_SHIM_OUT_DIR/librepro_monitor_shim.dll" | Format-List | Out-String | Set-Content "$evidence/shim-sha256.txt"
New-Item -ItemType Directory -Force "$evidence/shims/debug", "$evidence/shims/release" | Out-Null
Copy-Item "$env:IO_MON_SHIM_OUT_DIR/librepro_monitor_shim.dll" "$evidence/shims/debug/"
$env:IO_MON_SHIM_OUT_DIR = "$evidence/shims/release"
$env:IO_MON_SHIM_NIMCACHE_DIR = Join-Path $PWD 'build/runtime-phase-release-shim-cache'
$env:IO_MON_BUILD_MODE = 'release'
& bash io-mon/scripts/build_shim.sh *> "$evidence/release-shim-build.log"
if ($LASTEXITCODE) { throw 'Release-mode diagnostic shim did not compile' }
Remove-Item Env:IO_MON_BUILD_MODE
git -C nim-stackable-hooks diff | Set-Content "$evidence/hooks.patch"
git -C io-mon diff | Set-Content "$evidence/io-mon.patch"
Copy-Item build/windows-arm-injection/init-phases.json "$evidence/init-phases.json"

$recipe = Join-Path $PWD 'repro.nim'
$original = [IO.File]::ReadAllText($recipe)
try {
    $anchor = '    testSources.sort()'
    if ([regex]::Matches($original, [regex]::Escape($anchor)).Count -ne 1) { throw 'Selection anchor changed' }
    $selection = @'
    testSources.sort()
    const selectedNames = ["t_observation_store_export", "t_observation_store_merge", "t_observation_retention_schedule"]
    var selected: seq[string] = @[]
    for source in testSources:
      if source.extractFilename.changeFileExt("") in selectedNames:
        selected.add(source)
    doAssert selected.len == selectedNames.len
    testSources = selected
'@
    [IO.File]::WriteAllText($recipe, $original.Replace($anchor, $selection))
    git diff | Set-Content "$evidence/selection.patch"
    $env:REPRO_DIAGNOSTIC_TAIL_LINES = '12'
    $env:REPROBUILD_MAX_PARALLELISM = '3'
    & bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/build.log" repro build --daemon=off --tool-provisioning=tarball "--write-report=$evidence/build.json"
    if ($LASTEXITCODE) { throw 'Selected monitored compilation failed' }
    $env:REPRO_TOOL_PROVISIONING = 'tarball'
    & bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/comparison.log" repro exec -- python "$PSScriptRoot/runquota-windows-runtime-phases.py"
    if ($LASTEXITCODE) { throw 'A real test failed; retain phase observations' }
} finally {
    [IO.File]::WriteAllText($recipe, $original)
}

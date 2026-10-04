# Compare the unchanged concurrency assertions with server phase timestamps.
# The temporary recipe change removes only the all-suite ordering prerequisite
# for this supplemental diagnostic. Production ordering and gates stay intact.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'test-logs/arm-concurrency'
New-Item -ItemType Directory -Force $evidence | Out-Null
$recipe = Join-Path $PWD 'repro.nim'
$original = [IO.File]::ReadAllBytes($recipe)
$server = Join-Path $PWD 'src/vm_harness/serve/server.nim'
$originalServer = [IO.File]::ReadAllBytes($server)
$shimSource = Join-Path $PWD 'io-mon/src/io_mon/shim/windows_interpose.nim'
$originalShimSource = [IO.File]::ReadAllBytes($shimSource)
$hooksSource = Join-Path $PWD 'nim-stackable-hooks/src/stackable_hooks/inline_hook/windows/install_windows.c'
$originalHooksSource = [IO.File]::ReadAllBytes($hooksSource)
$hookCandidate = '10ed82a4bc5bd8c5fccbbe3f3aaaed53ef7d6485'
$hookCandidateDir = Join-Path $PWD '.hook-candidate'
if ((& git -C $hookCandidateDir rev-parse HEAD).Trim() -ne $hookCandidate) { throw 'Unexpected page-preparation candidate' }
$candidateHooksSource = [IO.File]::ReadAllBytes((Join-Path $hookCandidateDir 'src/stackable_hooks/inline_hook/windows/install_windows.c'))
$fixture = Join-Path $PWD 'tests/e2e/t_vmharness_serve_concurrency.nim'
$originalFixture = [IO.File]::ReadAllBytes($fixture)
$originalShimPin = $env:REPRO_MONITOR_SHIM_LIB
$source = [Text.Encoding]::UTF8.GetString($original)
$anchor = 'const timingTests = ["t_tart_backend", "t_vmharness_serve_concurrency"]'
if (-not $source.Contains($anchor)) { throw 'Timing prerequisite anchor changed' }
$candidate = (& git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $candidate -ne '6129ea89f80731c1ec9087e78d9058270f0affb2') {
    throw "Unexpected Gosti candidate: $candidate"
}
foreach ($repo in @('.', 'reprobuild', 'io-mon', 'runquota', 'nim-stackable-hooks', 'nim-shm-queue', 'nim-shm-gset')) {
    "$repo $(& git -C $repo rev-parse HEAD)" | Add-Content "$evidence/sources.txt"
    if ($LASTEXITCODE -ne 0) { throw "Cannot identify $repo" }
}
& nim --version > "$evidence/nim-version.txt"
if ((& git -C io-mon rev-parse HEAD).Trim() -ne 'd3826a368e0ca8c2760bf5e3270cc3577811af47' -or
    (& git -C nim-stackable-hooks rev-parse HEAD).Trim() -ne '3b99d26fd969a48698cf75fc90a8657010c81eec') {
    throw 'Bootstrap monitor sources changed; compare against a newly recorded baseline'
}
Get-FileHash reprobuild/build/lib/librepro_monitor_shim.dll -Algorithm SHA256 |
    Format-List > "$evidence/monitor-sha256.txt"
$results = @()
$failed = $false
try {
    $selected = $source.Replace($anchor, 'const timingTests = ["diagnostic-unused-target"]')
    [IO.File]::WriteAllText($recipe, $selected, (New-Object Text.UTF8Encoding($false)))
    & "$PSScriptRoot/gosti-serve-profile.ps1" -Server $server
    $fixtureText = [Text.Encoding]::UTF8.GetString($originalFixture)
    $logAnchor = '          got.add(ev.line)'
    if ([regex]::Matches($fixtureText, [regex]::Escape($logAnchor)).Count -ne 1) { throw 'Fixture log anchor changed' }
    $fixtureText = $fixtureText.Replace($logAnchor, "          if ev.line.contains(`"monitor-profile`") or ev.line.contains(`"hook-profile`"): echo ev.line`n$logAnchor")
    [IO.File]::WriteAllText($fixture, $fixtureText, (New-Object Text.UTF8Encoding($false)))
    & git diff -- repro.nim src/vm_harness/serve/server.nim tests/e2e/t_vmharness_serve_concurrency.nim > "$evidence/diagnostic.patch"
    & python "$PSScriptRoot/gosti-monitor-profile.py" $shimSource
    if ($LASTEXITCODE -ne 0) { throw 'Monitor phase anchors changed' }
    & git -C io-mon diff -- src/io_mon/shim/windows_interpose.nim > "$evidence/monitor-profile.patch"
    # Compare identical debug monitor builds. The only production difference is
    # the candidate installer; both carry the same diagnostic instrumentation.
    # All fixture assertions and the original 2.5-second bound remain intact.
    "Page preparation candidate $hookCandidate" | Add-Content "$evidence/sources.txt"
    $env:IO_MON_BUILD_MODE = 'debug'
    $shims = @{}
    foreach ($name in @('baseline', 'prepared-pages')) {
        $env:IO_MON_SHIM_OUT_DIR = (Join-Path $PWD "build/profile-$name/lib").Replace('\', '/')
        $env:IO_MON_SHIM_NIMCACHE_DIR = (Join-Path $PWD "build/profile-$name/nimcache").Replace('\', '/')
        $installerBytes = if ($name -eq 'baseline') { $originalHooksSource } else { $candidateHooksSource }
        [IO.File]::WriteAllBytes($hooksSource, $installerBytes)
        & python "$PSScriptRoot/gosti-hooks-profile.py" $hooksSource
        if ($LASTEXITCODE -ne 0) { throw 'Hook backend anchors changed' }
        & git -C nim-stackable-hooks diff -- src/stackable_hooks/inline_hook/windows/install_windows.c > "$evidence/$name-hooks.patch"
        & bash io-mon/scripts/build_shim.sh --opt:none *> "$evidence/$name-monitor-build.log"
        if ($LASTEXITCODE -ne 0) { throw "The $name monitor did not build" }
        $shims[$name] = (Resolve-Path "$env:IO_MON_SHIM_OUT_DIR/librepro_monitor_shim.dll").Path
    }
    foreach ($name in @('baseline', 'prepared-pages')) {
        $env:REPRO_MONITOR_SHIM_LIB = $shims[$name]
        Get-FileHash $env:REPRO_MONITOR_SHIM_LIB -Algorithm SHA256 |
            Format-List > "$evidence/$name-monitor-sha256.txt"
        # Explicit forced validation requires actual execution; cacheability and
        # automatic monitoring remain unchanged in the action declaration.
        & bash scripts/capture-ci-command.sh "$evidence/$name-repro.log" dev-exec repro build '.#test-t_vmharness_serve_concurrency' --tool-provisioning=path --force-rebuild "--write-report=$evidence/$name-report.json"
        $code = $LASTEXITCODE
        $results += @{mode='repro'; variant=$name; exitCode=$code; shim=$env:REPRO_MONITOR_SHIM_LIB}
        if ($name -ne 'baseline' -and $code -ne 0) { $failed = $true }
        Get-Content "$evidence/$name-repro.log" -Tail 25
        $report = Get-Content "$evidence/$name-report.json" -Raw | ConvertFrom-Json
        $actions = @($report.actions | Where-Object {$_.id -like 'vm_harness.test_execute.*'})
        if ($actions.Count -ne 1 -or $actions[0].id -ne 'vm_harness.test_execute.t_vmharness_serve_concurrency' -or -not $actions[0].launched) {
            throw 'The selected real concurrency action did not execute'
        }
        $actionOutput = $actions[0].stdout + $actions[0].stderr
        if (-not $actionOutput.Contains('monitor-profile') -or
            -not $actionOutput.Contains("profile-$name") -or
            -not $actionOutput.Contains('phase=inject-end') -or
            -not $actionOutput.Contains('phase=uninstall-hooks-end') -or
            -not $actionOutput.Contains('hook-profile')) {
            throw 'The test did not prove the selected monitor image and phase coverage'
        }
        if (-not $actionOutput.Contains('clock-errors=0') -or
            $actionOutput -match 'clock-errors=[1-9]' -or $actionOutput -match 'frequency=0') {
            throw 'The unhooked diagnostic clock failed; API timings are invalid'
        }
        $passed = $actions[0].status -eq 'asSucceeded' -and $actions[0].exitCode -eq 0 -and ([regex]::Matches($actions[0].stdout, '\[OK\]')).Count -eq 2
        if (-not $passed) {
            # The baseline may reproduce only the already recorded latency
            # failure. Other failures invalidate this comparative experiment.
            $knownBaseline = $name -eq 'baseline' -and $code -ne 0 -and
                $actionOutput.Contains('Check failed: elapsed < 2.5') -and
                $actionOutput.Contains('[FAILED] a slow exec does not serialize concurrent fast execs') -and
                ([regex]::Matches($actionOutput, 'Check failed:')).Count -eq 1 -and
                ([regex]::Matches($actions[0].stdout, '\[FAILED\]')).Count -eq 1 -and
                ([regex]::Matches($actions[0].stdout, '\[OK\]')).Count -eq 1
            if (-not $knownBaseline) { $failed = $true }
        }
        $binary = Join-Path $PWD 'build/test-bin/t_vmharness_serve_concurrency.exe'
        $hash = (Get-FileHash $binary -Algorithm SHA256).Hash
        & $binary *> "$evidence/$name-native.log"
        $code = $LASTEXITCODE
        $results += @{mode='native'; variant=$name; exitCode=$code; sha256=$hash}
        if ($code -ne 0 -or ([regex]::Matches((Get-Content "$evidence/$name-native.log" -Raw), '\[OK\]')).Count -ne 2) { $failed = $true }
        Get-Content "$evidence/$name-native.log" -Tail 20
        if ((Get-FileHash $binary -Algorithm SHA256).Hash -ne $hash) { throw 'Fixture bytes changed during direct execution' }
        $results | ConvertTo-Json | Set-Content "$evidence/results.json"
    }
    $env:VMH_CONC_TEST_THREADS = '1'
    & $binary *> "$evidence/serial-control.log"
    $code = $LASTEXITCODE
    $log = Get-Content "$evidence/serial-control.log" -Raw
    Get-Content "$evidence/serial-control.log" -Tail 25
    $results += @{mode='serial-control'; exitCode=$code; sha256=(Get-FileHash $binary -Algorithm SHA256).Hash}
    $results | ConvertTo-Json | Set-Content "$evidence/results.json"
    $expectedFailure = $log.Contains('Check failed: elapsed < 2.5') -or
        ($log.Contains('503') -and $log.Contains('handlers_saturated'))
    if ($code -eq 0 -or -not $expectedFailure -or
        -not $log.Contains('[FAILED] a slow exec does not serialize concurrent fast execs')) {
        throw 'One-worker control did not detect blocked dispatch or worker saturation'
    }
} finally {
    [IO.File]::WriteAllBytes($recipe, $original)
    [IO.File]::WriteAllBytes($server, $originalServer)
    [IO.File]::WriteAllBytes($shimSource, $originalShimSource)
    [IO.File]::WriteAllBytes($hooksSource, $originalHooksSource)
    [IO.File]::WriteAllBytes($fixture, $originalFixture)
    $env:REPRO_MONITOR_SHIM_LIB = $originalShimPin
    Remove-Item Env:IO_MON_BUILD_MODE, Env:IO_MON_SHIM_OUT_DIR, Env:IO_MON_SHIM_NIMCACHE_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:VMH_CONC_TEST_THREADS -ErrorAction SilentlyContinue
}
if ($failed) { throw 'At least one unchanged concurrency execution failed; inspect timings' }

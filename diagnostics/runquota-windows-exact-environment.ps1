# Real fixture and launcher; the negative control restores the actual leak.
# Clear the fixture parent's environment so a deliberate inheritance failure
# can print only synthetic/public values, never CI credentials.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PWD '.toolchain/windows/bootstrap-toolchain.ps1')
$null = Invoke-ReproToolchainBootstrap
$evidence = Join-Path $PWD 'build/environment-control'
$repo = Join-Path $PWD '.runquota'
New-Item -ItemType Directory -Force $evidence | Out-Null
$results = @()
Push-Location $repo
$fixture = 'libs/runquota_process/tests/t_isolated_environment.nim'
$launcher = 'libs/runquota_process/src/runquota_process.nim'
$originalFixture = [IO.File]::ReadAllText((Join-Path $PWD $fixture))
$originalLauncher = [IO.File]::ReadAllText((Join-Path $PWD $launcher))
try {
    $baseline = & git show "70364629d5214bf4be9ac760d63e572fc257b111:$fixture"
    if ($LASTEXITCODE) { throw 'Exact baseline source is absent' }
    # Mainline renamed the isolation option. Translate that call only, keeping
    # the original baseline's declaration and every assertion unchanged.
    $baselineText = ($baseline -join "`n") + "`n"
    $oldCall = 'isolateEnvironment = isolate))'
    if ([regex]::Matches($baselineText, [regex]::Escape($oldCall)).Count -ne 1) { throw 'Baseline API anchor changed' }
    $baselineText = $baselineText.Replace($oldCall, 'inheritEnv = not isolate))')
    foreach ($variant in @('baseline', 'repaired', 'inherited-control')) {
        $text = if ($variant -eq 'baseline') { $baselineText } else { $originalFixture }
        [IO.File]::WriteAllText((Join-Path $PWD $fixture), $text)
        $text = $originalLauncher
        if ($variant -eq 'inherited-control') {
            $anchor = 'if spec.inheritEnv:'
            if ([regex]::Matches($text, [regex]::Escape($anchor)).Count -ne 1) { throw 'Leak control anchor changed' }
            $text = $text.Replace($anchor, 'if true: # Deliberate real inheritance regression')
        }
        [IO.File]::WriteAllText((Join-Path $PWD $launcher), $text)
        $binary = Join-Path $evidence "$variant.exe"
        $cache = Join-Path $env:RUNNER_TEMP "runquota-environment-$variant"
        & nim c --cpu:amd64 --threads:on --hints:off --warnings:off "--nimcache:$cache" "--out:$binary" $fixture *> "$evidence/$variant-build.log"
        if ($LASTEXITCODE) { throw "Could not compile $variant fixture" }
        $start = [Diagnostics.ProcessStartInfo]::new($binary)
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.WorkingDirectory = $repo
        $start.Environment.Clear()
        $start.Environment['RQ_CONTROL_PARENT'] = 'safe-sentinel'
        $process = [Diagnostics.Process]::Start($start)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $finished = $process.WaitForExit(30000)
        if (-not $finished) { $process.Kill($true); $process.WaitForExit() }
        $code = $process.ExitCode
        $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        $output | Set-Content "$evidence/$variant.log"
        $process.Dispose()
        $results += @{variant=$variant; finished=$finished; exitCode=$code; sha256=(Get-FileHash $binary).Hash}
        $results | ConvertTo-Json -Depth 3 | Set-Content "$evidence/fixture-results.json"
        Write-Host "$variant finished=$finished exit=$code"
        Write-Host $output
        if (-not $finished) { throw "$variant failed to finish" }
        if ($variant -eq 'repaired' -and $code -ne 0) { throw 'Repaired fixture failed' }
        if ($variant -eq 'baseline') {
            if ($env:EXPECT_BASELINE_FAILURE -eq 'true') {
                if ($code -eq 0 -or -not $output.Contains('PROCESSOR_ARCHITECTURE')) { throw 'Original ARM-host failure was not reproduced' }
            } elseif ($code -ne 0) { throw 'Native x64 baseline failed' }
        }
        if ($variant -eq 'inherited-control' -and ($code -eq 0 -or -not $output.Contains('RQ_TEST_LAUNCHER_ONLY'))) {
            throw 'The repaired fixture did not reject real environment inheritance'
        }
    }
} finally {
    [IO.File]::WriteAllText((Join-Path $PWD $fixture), $originalFixture)
    [IO.File]::WriteAllText((Join-Path $PWD $launcher), $originalLauncher)
    Pop-Location
}

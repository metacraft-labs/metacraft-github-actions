# Real Repro actions and unchanged private-image cleanup; no mocks.
# Add names for the existing actions only. Preserve their dependency policies,
# tool provisioning, assertions and deadlines, and execute one fixture at a time.
param([switch]$PrepareOnly)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'test-logs/repro-cleanup'
New-Item -ItemType Directory -Force $evidence | Out-Null
$recipe = Join-Path $PWD 'repro.nim'
$original = [IO.File]::ReadAllText($recipe)
$normalized = $original.Replace("`r`n", "`n")
$anchor = '    discard collect("test", testExecuteActions)'
if (($normalized.Split($anchor)).Count -ne 2) { throw 'Expected one full-suite collection' }
$aliases = @'
    discard collect("test", testExecuteActions)
    when defined(windows):
      for name in ["test_io_mon_cli_exit_status",
                   "test_io_mon_windows_host_session_scope"]:
        var selected: seq[BuildActionDef] = @[]
        for action in testExecuteActions:
          if action.id == "io-mon.test_execute." & name & ".exe":
            selected.add(action)
        doAssert selected.len == 1, "Missing diagnostic action: " & name
        discard collect("diagnostic-" & name, selected)
'@
try {
    [IO.File]::WriteAllText($recipe, $normalized.Replace($anchor, $aliases))
    & git diff -- repro.nim > "$evidence/recipe-aliases.patch"
    if ($PrepareOnly) { return }
    & git log -1 --format='%H %s' > "$evidence/source.txt"
    & dev-exec nim --version > "$evidence/compiler.txt"
    if ($LASTEXITCODE -ne 0) { throw 'Could not identify compiler' }
    & dev-exec repro --version > "$evidence/repro-version.txt"
    if ($LASTEXITCODE -ne 0) { throw 'Could not identify Reprobuild' }
    $results = @()
    foreach ($fixture in @('test_io_mon_cli_exit_status', 'test_io_mon_windows_host_session_scope')) {
        foreach ($round in 1..3) {
            $report = "$evidence/$fixture-$round.json"
            # dev-exec is the same command wrapper used by the full CI lane.
            & dev-exec repro build ".#diagnostic-$fixture" --tool-provisioning=tarball "--write-report=$report" *> "$evidence/$fixture-$round.log"
            $code = $LASTEXITCODE
            $results += @{fixture=$fixture; round=$round; exitCode=$code}
            $results | ConvertTo-Json | Set-Content "$evidence/results.json"
            Get-Content "$evidence/$fixture-$round.log" -Tail 50
            if (-not (Test-Path $report)) { throw "No execution report for $fixture" }
            $observed = Get-Content $report -Raw | ConvertFrom-Json
            $runs = @($observed.actions | Where-Object {$_.id -like 'io-mon.test_execute.*'})
            if ($runs.Count -ne 1 -or $runs[0].id -ne "io-mon.test_execute.$fixture.exe") {
                throw "Diagnostic did not select exactly $fixture"
            }
            if (-not $runs[0].launched) { throw "Fixture was not executed: $fixture" }
            if ($code -eq 0 -and ($runs[0].status -ne 'asSucceeded' -or $runs[0].exitCode -ne 0)) {
                throw "Inconsistent successful report for $fixture"
            }
        }
    }
    if (@($results | Where-Object {$_.exitCode -ne 0}).Count -gt 0) {
        throw 'An unchanged fixture failed under focused Repro execution'
    }
} finally {
    [IO.File]::WriteAllText($recipe, $original)
}

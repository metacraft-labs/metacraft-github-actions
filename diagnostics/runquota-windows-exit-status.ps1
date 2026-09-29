# No mocks: compile and run the actual atomicity and host-load programs through
# the production recipe, then compare the same bytes through native/MSYS paths.
# The local recipe edit narrows this diagnostic only; ordinary CI stays complete.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'build/windows-exit-status'
New-Item -ItemType Directory -Force $evidence | Out-Null
$recipe = Join-Path $PWD 'repro.nim'
$original = [IO.File]::ReadAllText($recipe)
$filter = @'
    testSources.sort()
    var focusedSources: seq[string] = @[]
    for source in testSources:
      if source.extractFilename in ["t_ambient_sample_atomicity.nim", "t_host_load_reading_invariants.nim"]:
        focusedSources.add(source)
    testSources = focusedSources
'@
$changed = $original.Replace('    testSources.sort()', $filter.TrimEnd())
$changed = $changed.Replace('actionId = "runquota.test_execute." & name)', 'actionId = "runquota.test_execute." & name, cacheable = false)')
if ($changed -eq $original -or -not $changed.Contains('cacheable = false')) { throw 'Diagnostic recipe anchor changed' }
$results = @()
try {
    [IO.File]::WriteAllText($recipe, $changed)
    git diff -- repro.nim | Set-Content "$evidence/diagnostic-subset.patch"
    for ($round = 1; $round -le 3; $round++) {
        $report = "$evidence/graph-$round.json"
        & bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/graph-$round.log" repro test --daemon=off --tool-provisioning=tarball "--write-report=$report"
        $code = $LASTEXITCODE
        $results += @{mode='monitored-graph'; round=$round; exitCode=$code}
        Write-Host "Monitored graph round $round exit $code"
        if (Test-Path $report) {
            $doc = Get-Content $report -Raw | ConvertFrom-Json
            foreach ($action in @($doc.actions | Where-Object { $_.id -like 'runquota.test_execute.*' })) {
                Write-Host "$($action.id) status=$($action.status) exit=$($action.exitCode) launched=$($action.launched)"
            }
        }
    }
    function Tool([string]$Name, [string]$Executable) {
        $prefix = Join-Path $PWD ".repro/build/repro/tool-store/prefixes/$Name"
        $match = Get-ChildItem -LiteralPath $prefix -Recurse -File -Filter $Executable | Select-Object -First 1
        if (-not $match) { throw "Missing declared $Name executable" }
        return $match.FullName
    }
    $sqlite = Tool 'sqlite3' 'sqlite3.exe'
    $shell = Tool 'sh' 'sh.exe'
    $timeout = Tool 'timeout' 'timeout.exe'
    $env:PATH = "$(Split-Path $sqlite);$(Split-Path $timeout);$(Split-Path $shell);$env:PATH"
    @{sqlite=$sqlite; sh=$shell; timeout=$timeout} | ConvertTo-Json | Set-Content "$evidence/tools.json"
    foreach ($name in @('t_ambient_sample_atomicity', 't_host_load_reading_invariants')) {
        $binary = Join-Path $PWD "build/test-bin/$name.exe"
        if (-not (Test-Path $binary)) { throw "Missing real fixture $binary" }
        $hash = (Get-FileHash -Algorithm SHA256 $binary).Hash
        $bashPath = $binary.Replace('\','/')
        foreach ($mode in @('native','timeout','shell','shell-timeout')) {
            $log = "$evidence/$name-$mode.log"
            switch ($mode) {
                native { & $binary *> $log }
                timeout { & $timeout --kill-after=10 600 $binary *> $log }
                shell { & $shell -c "'$bashPath' </dev/null" *> $log }
                shell-timeout { & $shell -c "timeout --kill-after=10 600 '$bashPath' </dev/null" *> $log }
            }
            $code = $LASTEXITCODE
            if ((Get-FileHash -Algorithm SHA256 $binary).Hash -ne $hash) { throw 'Fixture bytes changed during control' }
            $results += @{name=$name; mode=$mode; exitCode=$code; sha256=$hash}
            Write-Host "$name $mode exit=$code sha256=$hash"
            Get-Content $log -Tail 12
        }
    }
    $results | ConvertTo-Json -Depth 5 | Set-Content "$evidence/results.json"
    if (@($results | Where-Object { $_.exitCode -ne 0 }).Count) { throw 'Some exit-status controls failed; inspect retained evidence' }
} finally {
    $results | ConvertTo-Json -Depth 5 | Set-Content "$evidence/results.json"
    [IO.File]::WriteAllText($recipe, $original)
}

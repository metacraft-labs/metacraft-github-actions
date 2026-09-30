# Entered once through `repro exec`; every pair inherits the same real dev env.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'build/windows-readiness'
$results = @(Get-Content "$evidence/results.json" -Raw | ConvertFrom-Json)
$reproExe = (Get-Command repro).Source
$binary = Join-Path $PWD 'build/test-bin/t_e2e_runquota_client_exit_releases_lease.exe'
if (-not (Test-Path $binary)) { throw "Missing real fixture $binary" }
$fixtureHash = (Get-FileHash $binary).Hash
$daemon = Join-Path $PWD 'build/bin/runquotad.exe'
$daemonHash = (Get-FileHash $daemon).Hash
foreach ($round in 1..8) {
    foreach ($mode in @('native', 'monitored')) {
        $prefix = "$evidence/$mode-$round"
        if ($mode -eq 'native') {
            & bash "$PSScriptRoot/capture-ci-command.sh" "$prefix.log" timeout --kill-after=10 600 $binary
        } else {
            & bash "$PSScriptRoot/capture-ci-command.sh" "$prefix.log" timeout --kill-after=10 600 $reproExe internal io monitor --depfile "$prefix.iomon" -- $binary
        }
        $code = $LASTEXITCODE
        $results += @{mode=$mode; round=$round; exitCode=$code; fixtureSha256=$fixtureHash; daemonSha256=$daemonHash}
        $results | ConvertTo-Json -Depth 4 | Set-Content "$evidence/results.json"
        if ((Get-FileHash $binary).Hash -ne $fixtureHash -or (Get-FileHash $daemon).Hash -ne $daemonHash) {
            throw 'A comparison binary changed'
        }
    }
}
if (@($results | Where-Object { $_.exitCode -ne 0 }).Count) {
    throw 'A real comparison failed; inspect daemon startup evidence'
}

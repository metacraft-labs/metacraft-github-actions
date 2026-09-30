$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'build/merge-batching'
New-Item -ItemType Directory -Force $evidence | Out-Null
$pins = @{
    '.' = 'c6ddde686cb8952ecf4070e3163054dff928e04b'
    'nim-stackable-hooks' = 'def2464b2d282c7c1a982689a25953e1d4501f93'
    'io-mon' = '5e71adf033b860c0fdbe13dda4320cf4a580f632'
}
foreach ($repo in $pins.Keys) {
    $actual = (& git -C $repo rev-parse HEAD).Trim()
    if ($LASTEXITCODE -or $actual -ne $pins[$repo]) { throw "Unexpected source for $repo" }
}
$pins | ConvertTo-Json | Set-Content "$evidence/source-pins.json"
$versions = [ordered]@{
    original = 'a173bafd35ce3eef607f6062bde5175f1aadeede'
    batched = $pins['.']
}
$names = @('t_observation_store_merge', 't_observation_store_export', 't_observation_store_users')
$source = 'libs/runquota_observation_store/src/runquota_observation_store/merge.nim'
$changed = @(& git diff --name-only $versions.original $versions.batched)
if ($LASTEXITCODE -or $changed.Count -ne 1 -or $changed[0] -ne $source) {
    throw 'The comparison must differ only in the merge implementation'
}
git diff $versions.original $versions.batched | Set-Content "$evidence/source-change.patch"
& nim --version *> "$evidence/nim-version.txt"
if ($LASTEXITCODE) { throw 'Nim is unavailable' }
& sqlite3 --version *> "$evidence/sqlite-version.txt"
if ($LASTEXITCODE) { throw 'SQLite is unavailable' }
try {
    foreach ($variant in $versions.Keys) {
        & git restore "--source=$($versions[$variant])" -- $source
        if ($LASTEXITCODE) { throw "Cannot select $variant source" }
        $folder = Join-Path $evidence $variant
        New-Item -ItemType Directory -Force $folder | Out-Null
        foreach ($name in $names) {
            # Native compilation isolates runtime overhead. Full ordinary CI
            # separately retains monitored compilation and all other tests.
            & nim c --threads:on --cpu:amd64 "--nimcache:build/merge-batching-cache/$variant/$name" "--out:$folder/$name.exe" "tests/unit/$name.nim" *> "$folder/$name.build.log"
            if ($LASTEXITCODE) { throw "Could not compile $variant/$name" }
        }
    }
} finally {
    & git restore --source=HEAD -- $source
    if ($LASTEXITCODE) { throw 'Could not restore the selected source' }
}
$versions | ConvertTo-Json | Set-Content "$evidence/versions.json"
$env:REPRO_TOOL_PROVISIONING = 'tarball'
$env:REPRO_DIAGNOSTIC_TAIL_LINES = '12'
& bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/comparison.log" repro exec -- python "$PSScriptRoot/runquota-merge-batching.py"
if ($LASTEXITCODE) { throw 'A real comparison test failed; retain every result' }

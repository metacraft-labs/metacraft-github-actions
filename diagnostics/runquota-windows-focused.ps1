# No mocks: native binaries, real SQLite, and two independently installed Bash
# distributions. This is supplemental diagnosis, not the ordinary graph gate.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'build/windows-focused'
New-Item -ItemType Directory -Force $evidence | Out-Null
function Get-Archive([string]$Url, [string]$Hash, [string]$Path) {
    Invoke-WebRequest -Uri $Url -OutFile $Path
    if ((Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Hash) {
        throw "Archive checksum mismatch: $Path"
    }
}
$sqlite = Join-Path $env:RUNNER_TEMP 'focused-sqlite'
Get-Archive 'https://sqlite.org/2026/sqlite-tools-win-x64-3530400.zip' `
    'f46ee2475de4cbe287e6e5f7d43c838796b14e7379cd216bdbb28d391429f9fc' "$sqlite.zip"
Expand-Archive "$sqlite.zip" $sqlite -Force
$env:PATH = "$sqlite;$env:PATH"
& sqlite3 --version
$originalConfig = [IO.File]::ReadAllText((Join-Path $PWD 'config.nims'))
try {
    # The copied benchmark tree also inherits this explicit compiler choice.
    Add-Content config.nims @'
switch("cc", "clang")
switch("clang.exe", getEnv("RELEASE_CC"))
switch("clang.linkerexe", getEnv("RELEASE_CC"))
'@
    git diff -- config.nims | Set-Content "$evidence/compiler-selection.patch"
    & bash scripts/build_apps.sh 2>&1 | Tee-Object "$evidence/build.log"
    if ($LASTEXITCODE -ne 0) { throw 'Native app build failed' }
    $tests = @(
        'tests/integration/t_m5_process_exec_bench_contract.nim',
        'tests/integration/t_completion_report_does_not_wait_on_the_store.nim',
        'tests/integration/t_connection_failure_does_not_stop_the_daemon.nim'
    )
    $results = @()
    foreach ($test in $tests) {
        $name = [IO.Path]::GetFileNameWithoutExtension($test)
        $binary = Join-Path $evidence "$name.exe"
        & nim c --threads:on --hints:off "--out:$binary" $test 2>&1 |
            Tee-Object "$evidence/$name-compile.log"
        if ($LASTEXITCODE -ne 0) { throw "Compilation failed: $name" }
        & $binary 2>&1 | Tee-Object "$evidence/$name-native.log"
        $results += @{name=$name; mode='native'; exitCode=$LASTEXITCODE}
    }
    $portable = Join-Path $env:RUNNER_TEMP 'focused-portable-git'
    New-Item -ItemType Directory -Force $portable | Out-Null
    Get-Archive 'https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe' `
        'bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311' "$portable.7z.exe"
    & 7z x "$portable.7z.exe" "-o$portable" -y *> "$evidence/portable-git-extract.log"
    if ($LASTEXITCODE -ne 0) { throw 'PortableGit extraction failed' }
    $env:PATH = "$portable/bin;$env:PATH"
    Get-Command bash | Format-List Source | Out-String | Set-Content "$evidence/bash-path.txt"
    & "$evidence/t_m5_process_exec_bench_contract.exe" 2>&1 |
        Tee-Object "$evidence/t_m5_process_exec_bench_contract-portable-git.log"
    $results += @{name='t_m5_process_exec_bench_contract'; mode='portable-git'; exitCode=$LASTEXITCODE}
    $results | ConvertTo-Json | Set-Content "$evidence/results.json"
    Get-Content "$evidence/results.json"
} finally {
    [IO.File]::WriteAllText((Join-Path $PWD 'config.nims'), $originalConfig)
}

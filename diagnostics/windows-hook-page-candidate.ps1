# Execute the unchanged registered corpus with real Windows processes and DLLs.
# No mocks, assertion changes, fixture substitutions or longer borrowed-call limits.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PWD '.toolchain/windows/bootstrap-toolchain.ps1')
$null = Invoke-ReproToolchainBootstrap
$evidence = Join-Path $PWD 'build/windows-hook-page-candidate'
New-Item -ItemType Directory -Force $evidence | Out-Null
& nim --version *> "$evidence/nim-version.txt"
& gcc --version *> "$evidence/gcc-version.txt"
& git -C nim-stackable-hooks rev-parse HEAD > "$evidence/source-sha.txt"
$inventory = Join-Path $evidence 'inventory.nim'
@'
import tests/corpus
for source in hostTestSources():
  echo source
'@ | Set-Content $inventory
Push-Location nim-stackable-hooks
try {
    & nim c --hints:off "--path:$PWD" "--out:$evidence/inventory.exe" $inventory *> "$evidence/inventory-build.log"
    if ($LASTEXITCODE) { throw 'Could not compile the registered corpus inventory' }
    $sources = @(& "$evidence/inventory.exe")
    if ($LASTEXITCODE -or $sources.Count -eq 0) { throw 'Could not enumerate the host corpus' }
    $sources | Set-Content "$evidence/inventory.txt"
    $results = @()
    foreach ($source in $sources) {
        $name = [IO.Path]::GetFileNameWithoutExtension($source)
        $binary = Join-Path $evidence "$name.exe"
        & nim c --hints:off --cc:gcc --path:src "--out:$binary" $source *> "$evidence/$name.build.log"
        $buildCode = $LASTEXITCODE
        $runCode = $null
        if ($buildCode -eq 0) {
            & $binary *> "$evidence/$name.test.log"
            $runCode = $LASTEXITCODE
        }
        $results += @{source=$source; buildExitCode=$buildCode; testExitCode=$runCode}
        $results | ConvertTo-Json -AsArray | Set-Content "$evidence/results.json"
        Write-Host "$source build=$buildCode test=$runCode"
    }
    if (@($results | Where-Object { $_.buildExitCode -ne 0 -or $_.testExitCode -ne 0 }).Count) {
        throw 'The Windows candidate failed its unchanged host corpus'
    }
} finally {
    Pop-Location
}

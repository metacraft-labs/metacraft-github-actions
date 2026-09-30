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
    $changed = @(& git diff --name-only HEAD^ HEAD)
    $expected = @('src/stackable_hooks/inline_hook/windows/install_windows.c',
                  'src/stackable_hooks/inline_hook/windows/install_windows.h')
    if ($LASTEXITCODE -or (Compare-Object $expected $changed)) {
        throw 'The paired sources must differ only in page preparation and its API comment'
    }
    $savedTemp = $env:TEMP
    $savedTmp = $env:TMP
    foreach ($variant in @('original', 'prepared')) {
      $sourceRef = if ($variant -eq 'original') { 'HEAD^' } else { 'HEAD' }
      & git restore "--source=$sourceRef" -- $expected
      if ($LASTEXITCODE) { throw "Cannot select $variant" }
      $caseDir = Join-Path $evidence $variant
      New-Item -ItemType Directory -Force $caseDir | Out-Null
      & git rev-parse $sourceRef > "$caseDir/source-sha.txt"
      $env:TEMP = $caseDir
      $env:TMP = $caseDir
      foreach ($source in $sources) {
        $name = [IO.Path]::GetFileNameWithoutExtension($source)
        $binary = Join-Path $caseDir "$name.exe"
        & nim c --hints:off --cc:gcc --path:src "--nimcache:build/page-candidate-cache/$variant/$name" "--out:$binary" $source *> "$caseDir/$name.build.log"
        $buildCode = $LASTEXITCODE
        $runCode = $null
        if ($buildCode -eq 0) {
            & $binary *> "$caseDir/$name.test.log"
            $runCode = $LASTEXITCODE
        }
        $results += @{variant=$variant; source=$source; buildExitCode=$buildCode; testExitCode=$runCode}
        $results | ConvertTo-Json -AsArray | Set-Content "$evidence/results.json"
        Write-Host "$variant/$source build=$buildCode test=$runCode"
    }
    }
    if (@($results | Where-Object { $_.buildExitCode -ne 0 -or $_.testExitCode -ne 0 }).Count) {
        throw 'An original/prepared Windows corpus failed; both outcomes are retained'
    }
} finally {
    & git restore --source=HEAD -- src/stackable_hooks/inline_hook/windows/install_windows.c src/stackable_hooks/inline_hook/windows/install_windows.h
    if (Test-Path variable:savedTemp) { $env:TEMP = $savedTemp; $env:TMP = $savedTmp }
    Pop-Location
}

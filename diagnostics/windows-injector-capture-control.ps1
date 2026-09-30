$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PWD '.toolchain/windows/bootstrap-toolchain.ps1')
$null = Invoke-ReproToolchainBootstrap
$evidence = Join-Path $PWD 'build/windows-injector-capture'
New-Item -ItemType Directory -Force $evidence | Out-Null
$fixture = Join-Path $evidence 'test_windows_injector_capture.nim'
Copy-Item hooks-fixed/tests/test_windows_injector_capture.nim $fixture
$outcomes = @()
foreach ($variant in @('original', 'fixed')) {
    $repository = if ($variant -eq 'original') { 'hooks-original' } else { 'hooks-fixed' }
    $expected = if ($variant -eq 'original') {
        '8f4d806ce1ae58e6b4292fed92944171eff4f7a2'
    } else { 'b7a1cdd319022639abaf401a7fc0b53645bad674' }
    $actual = git -C $repository rev-parse HEAD
    if ($LASTEXITCODE -or $actual -ne $expected) { throw "Unexpected $variant source: $actual" }
    $binary = Join-Path $evidence "$variant.exe"
    & nim c --cpu:amd64 --threads:on --mm:orc "--path:$repository/src" "--out:$binary" $fixture *> "$evidence/$variant-build.log"
    if ($LASTEXITCODE) { throw "Could not compile the $variant real-process regression" }
    Get-FileHash $binary | Format-List | Out-String | Set-Content "$evidence/$variant-sha256.txt"
    foreach ($index in 1..2) {
        $log = "$evidence/$variant-$index.log"
        & $binary *> $log
        $code = $LASTEXITCODE
        $contents = Get-Content -Raw $log
        $outcomes += @{ variant = $variant; source = $actual; sample = $index; exitCode = $code }
        $outcomes | ConvertTo-Json -AsArray | Set-Content "$evidence/results.json"
        if ($variant -eq 'original') {
            if ($code -eq 0 -or $contents -notmatch 'captured output waited for descendant pipe EOF after root exit') {
                throw "Original did not fail the specific descendant-EOF assertion: $contents"
            }
        } elseif ($code -ne 0 -or $contents -notmatch 'root-exit capture and surviving-writer assertions passed') {
            throw "Corrected capture failed: $contents"
        }
        Write-Host "$variant sample $index at $actual`: expected outcome confirmed (exit $code)"
    }
}

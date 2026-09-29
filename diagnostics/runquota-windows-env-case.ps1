# No mocks: build and launch the same child-environment regression against
# the old and fixed production launchers, using the native Windows compiler.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$source = 'libs/runquota_process/src/runquota_process.nim'
$test = 'tests/integration/t_windows_child_environment_case.nim'
$original = [IO.File]::ReadAllText((Join-Path $PWD $source))
$evidence = Join-Path $PWD 'build/windows-env-case'
New-Item -ItemType Directory -Force $evidence | Out-Null
$old = & git show "11548ab8cb4820d9277f453814cebfbbbf9a823d:$source"
if ($LASTEXITCODE -ne 0) { throw 'Cannot load the exact old launcher' }
try {
    foreach ($mode in @('old', 'fixed')) {
        $content = if ($mode -eq 'old') { $old -join "`n" } else { $original }
        [IO.File]::WriteAllText((Join-Path $PWD $source), $content)
        $binary = Join-Path $evidence "$mode.exe"
        & nim c --cc:clang "--clang.exe:$env:RELEASE_CC" "--clang.linkerexe:$env:RELEASE_CC" `
            --threads:on --hints:off "--nimcache:$env:RUNNER_TEMP/env-case-$mode" `
            "--out:$binary" $test 2>&1 | Tee-Object "$evidence/$mode-compile.log"
        if ($LASTEXITCODE -ne 0) { throw "$mode compilation failed" }
        Get-FileHash -Algorithm SHA256 $binary | Format-List |
            Out-String | Set-Content "$evidence/$mode-sha256.txt"
        & $binary 2>&1 | Tee-Object "$evidence/$mode-run.log"
        $code = $LASTEXITCODE
        Write-Host "$mode exit=$code"
        if ($mode -eq 'old' -and $code -eq 0) { throw 'Old launcher unexpectedly passed' }
        if ($mode -eq 'old' -and
            -not (Select-String -Path "$evidence/$mode-run.log" -SimpleMatch 'matches=3')) {
            throw 'Old launcher failed without demonstrating all three case variants'
        }
        if ($mode -eq 'fixed' -and $code -ne 0) { throw 'Fixed launcher failed' }
    }
} finally {
    [IO.File]::WriteAllText((Join-Path $PWD $source), $original)
}
exit 0

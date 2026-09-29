# No mocks: real System32 identity child, unchanged test bytes, old/new shims.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'build/windows-system-child'
New-Item -ItemType Directory -Force $evidence | Out-Null
$source = Join-Path $PWD 'src/io_mon/shim/windows_interpose.nim'
$fixed = [IO.File]::ReadAllText($source)
$binary = Join-Path $evidence 'native-system-child.exe'
$hostArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
& nim c --hints:off --cc:gcc --path:tests/helpers "--out:$binary" tests/windows/test_io_mon_windows_native_system_child.nim *> "$evidence/compile.log"
if ($LASTEXITCODE -ne 0) { throw 'Fixture compile failed' }
$binaryHash = (Get-FileHash -Algorithm SHA256 $binary).Hash
$results = @()
try {
    foreach ($arm in @('old','fixed')) {
        if ($arm -eq 'old') {
            & git show '8384b2d:src/io_mon/shim/windows_interpose.nim' | Set-Content $source
            if ($LASTEXITCODE -ne 0) { throw 'Missing baseline runtime source' }
        } else { [IO.File]::WriteAllText($source,$fixed) }
        $env:IO_MON_SHIM_OUT_DIR = Join-Path $evidence "shim-$arm"
        $env:IO_MON_SHIM_NIMCACHE_DIR = Join-Path $evidence "cache-$arm"
        & bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/build-$arm.log" bash scripts/build_shim.sh
        if ($LASTEXITCODE -ne 0) { throw "Shim build failed: $arm" }
        $env:REPRO_MONITOR_SHIM_LIB = Join-Path $env:IO_MON_SHIM_OUT_DIR 'librepro_monitor_shim.dll'
        $rounds = if ($arm -eq 'old') { 1 } else { 3 }
        for ($round=1; $round -le $rounds; $round++) {
            & $binary *> "$evidence/$arm-$round.log"
            $code = $LASTEXITCODE
            Get-Content "$evidence/$arm-$round.log" -Tail 18
            if ((Get-FileHash -Algorithm SHA256 $binary).Hash -ne $binaryHash) { throw 'Fixture bytes changed' }
            $results += @{arm=$arm; round=$round; exitCode=$code; host=$hostArch; sha256=$binaryHash}
            $results | ConvertTo-Json | Set-Content "$evidence/results.json"
        }
    }
} finally { [IO.File]::WriteAllText($source,$fixed) }
foreach ($result in $results) {
    $mustFail = $result.arm -eq 'old' -and $hostArch -eq 'Arm64'
    if (($mustFail -and $result.exitCode -eq 0) -or (-not $mustFail -and $result.exitCode -ne 0)) {
        throw 'Unexpected old/new runtime result; retain the real failure evidence'
    }
}

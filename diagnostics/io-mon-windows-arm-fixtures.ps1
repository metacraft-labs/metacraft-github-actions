# No mocks: compare host-shell fixtures with same-architecture real children.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'build/windows-arm-fixtures'
New-Item -ItemType Directory -Force $evidence | Out-Null
$results = @()
function Machine([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        $stream.Position = 0x3c
        $offset = $reader.ReadInt32()
        $stream.Position = $offset + 4
        return ('0x{0:x4}' -f $reader.ReadUInt16())
    } finally { $reader.Dispose() }
}
@{host=$env:PROCESSOR_ARCHITECTURE; comSpec=$env:ComSpec; comSpecMachine=(Machine $env:ComSpec); nim=(Get-Command nim).Source} | ConvertTo-Json | Set-Content "$evidence/environment.json"
Get-Content "$evidence/environment.json"
& bash scripts/build_shim.sh *> "$evidence/build-shim.log"
if ($LASTEXITCODE -ne 0) { throw 'Production shim build failed' }
$env:REPRO_MONITOR_SHIM_LIB = Join-Path $PWD 'build/lib/librepro_monitor_shim.dll'
Write-Host "Shim PE machine: $(Machine $env:REPRO_MONITOR_SHIM_LIB)"
$names = @('backend_profile','process_start_survives','root_guard','spawn_abandoned_injection')
foreach ($name in $names) {
    $path = "tests/windows/test_io_mon_windows_$name.nim"
    $fixed = [IO.File]::ReadAllText((Join-Path $PWD $path))
    try {
        foreach ($arm in @('old','fixed')) {
            if ($arm -eq 'old') {
                & git show "f6005c5:$path" | Set-Content $path
                if ($LASTEXITCODE -ne 0) { throw 'Could not load old fixture' }
            } else { [IO.File]::WriteAllText((Join-Path $PWD $path), $fixed) }
            $binary = Join-Path $evidence "$name-$arm.exe"
            & nim c --hints:off --cc:gcc --path:tests/helpers "--out:$binary" $path *> "$evidence/$name-$arm-compile.log"
            if ($LASTEXITCODE -ne 0) { throw "Fixture compile failed: $name $arm" }
            $machine = Machine $binary
            if ($machine -ne '0x8664') { throw "Expected the x64 emulation toolchain, got $machine" }
            $rounds = if ($arm -eq 'old') { 1 } else { 3 }
            for ($round=1; $round -le $rounds; $round++) {
                & $binary *> "$evidence/$name-$arm-$round.log"
                $code=$LASTEXITCODE
                $results += @{name=$name; arm=$arm; round=$round; exitCode=$code; machine=$machine}
                Write-Host "$name $arm round=$round exit=$code machine=$machine"
                Get-Content "$evidence/$name-$arm-$round.log" -Tail 8
                $results | ConvertTo-Json | Set-Content "$evidence/results.json"
            }
        }
    } finally { [IO.File]::WriteAllText((Join-Path $PWD $path), $fixed) }
}
# Preserve the private-DLL cleanup failure independently of child selection.
$helper = Join-Path $PWD 'tests/helpers/host_session_scope.nim'
$original = [IO.File]::ReadAllText($helper)
$replacement = @'
  defer:
    when defined(windows):
      proc getLoadedModule(path: cstring): pointer {.stdcall, dynlib: "kernel32", importc: "GetModuleHandleA".}
      try:
        removeDir(shimWork)
      except OSError as error:
        echo "cleanup first failure: ", error.msg
        echo "parent DLL handle: ", cast[uint](getLoadedModule((shimWork / "lib/librepro_monitor_shim.dll").cstring))
        for attempt in 1 .. 50:
          sleep(100)
          try:
            removeDir(shimWork)
            echo "cleanup completed after ", attempt * 100, " ms"
            break
          except OSError:
            if attempt == 50: raise
    else:
      removeDir(shimWork)
'@
try {
    $changed = $original.Replace('  defer: removeDir(shimWork)', $replacement.TrimEnd())
    if ($changed -eq $original) { throw 'Cleanup instrumentation anchor changed' }
    [IO.File]::WriteAllText($helper,$changed)
    git diff -- tests/helpers/host_session_scope.nim | Set-Content "$evidence/cleanup-diagnostic.patch"
    $binary = Join-Path $evidence 'host-session.exe'
    & nim c --hints:off --cc:gcc --path:tests/helpers "--out:$binary" tests/windows/test_io_mon_windows_host_session_scope.nim *> "$evidence/host-session-compile.log"
    if ($LASTEXITCODE -ne 0) { throw 'Host-session fixture compile failed' }
    for ($round=1; $round -le 3; $round++) {
        & $binary *> "$evidence/host-session-$round.log"
        $code=$LASTEXITCODE
        $results += @{name='host-session'; arm='diagnostic'; round=$round; exitCode=$code}
        Get-Content "$evidence/host-session-$round.log" -Tail 12
    }
} finally {
    [IO.File]::WriteAllText($helper,$original)
    $results | ConvertTo-Json | Set-Content "$evidence/results.json"
}
if (@($results | Where-Object { ($_.arm -eq 'old' -and $_.exitCode -eq 0) -or ($_.arm -ne 'old' -and $_.exitCode -ne 0) }).Count) {
    throw 'A fixture comparison failed; inspect retained actual process evidence'
}

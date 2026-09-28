$ErrorActionPreference = 'Stop'
$roots = @(
  "$env:LOCALAPPDATA\repo-workspaces\toolchains\gcc",
  'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\repo-workspaces\toolchains\gcc',
  'C:\Windows\System32\config\systemprofile\AppData\Local\repo-workspaces\toolchains\gcc'
)
$gccBin = $null
foreach ($root in $roots) {
  if (Test-Path $root) {
    $gccBin = Get-ChildItem $root -Directory | Sort-Object Name -Descending |
      ForEach-Object { Join-Path $_.FullName 'bin' } |
      Where-Object { Test-Path (Join-Path $_ 'gcc.exe') } | Select-Object -First 1
    if ($gccBin) { break }
  }
}
if (-not $gccBin) { throw 'No provisioned WinLibs compiler found' }
$env:PATH = "$gccBin;$env:PATH"
nim -v
gcc --version
New-Item -ItemType Directory -Force build/bin, build/test-bin, test-logs/loader | Out-Null

# This changes only the error path, after LoadLibraryW returned NULL. Read
# GetLastError on the same borrowed child thread; the parent's error is not
# the loader's error. Do not change the load, timeout or cleanup behavior.
$injector = Join-Path (Resolve-Path ../nim-stackable-hooks) 'src/stackable_hooks/windows_injector.nim'
$source = [IO.File]::ReadAllText($injector).Replace("`r`n", "`n")
$anchor = "    if llExit == 0:`n"
if (($source.Split($anchor).Count - 1) -ne 1) { throw 'Loader diagnostic anchor is not unique' }
$diagnostic = @'
    if llExit == 0:
      var childError = 0'u64
      var childErrorRead = false
      if borrowedLoad:
        var diagKernelName = toWideCStringSeq("kernel32.dll")
        let diagKernel = GetModuleHandleW(cast[LPCWSTR](addr diagKernelName[0]))
        let diagGetError = GetProcAddress(diagKernel, "GetLastError")
        childErrorRead = callOnParkedThread(park, pi.hThread, childIsWow64,
          diagGetError, nil, parkTimeoutMs, childError)
      try:
        stderr.writeLine("loader diagnostic: park=" & $park.status &
          " borrowed=" & $borrowedLoad & " module=" & $llModule &
          " childErrorRead=" & $childErrorRead & " childError=" & $childError)
      except IOError:
        discard
'@
$source = $source.Replace($anchor, $diagnostic.Replace("`r`n", "`n") + "`n")
[IO.File]::WriteAllText($injector, $source)
git -C ../nim-stackable-hooks diff -- src/stackable_hooks/windows_injector.nim |
  Set-Content test-logs/loader/diagnostic.patch
& bash scripts/build_shim.sh
if ($LASTEXITCODE -ne 0) { throw 'Shim build failed' }
& nim c --hints:off --cc:gcc --out:build/bin/io-mon.exe cmd/io_mon_snoop.nim
if ($LASTEXITCODE -ne 0) { throw 'CLI build failed' }
& objdump -p build/lib/librepro_monitor_shim.dll | Select-String 'DLL Name:' |
  Set-Content test-logs/loader/dependencies.txt
Get-FileHash build/lib/librepro_monitor_shim.dll | Format-List |
  Out-String | Set-Content test-logs/loader/shim-hash.txt
$names = @('host_session_scope', 'read_capture', 'root_guard', 'spawn_abandoned_injection', 'spawn_resume_invariant')
foreach ($name in $names) {
  & nim c --hints:off --cc:gcc --path:tests/helpers "--out:build/test-bin/$name.exe" "tests/windows/test_io_mon_windows_$name.nim"
  if ($LASTEXITCODE -ne 0) { throw "Compile failed: $name" }
}
for ($round = 1; $round -le 20; $round++) {
  $processes = @()
  foreach ($name in $names) {
    $out = "test-logs/loader/$round-$name.stdout.log"
    $err = "test-logs/loader/$round-$name.stderr.log"
    $child = Start-Process -FilePath (Resolve-Path "build/test-bin/$name.exe") -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err
    $processes += @{ Name = $name; Process = $child; Out = $out; Err = $err }
  }
  $failed = @()
  foreach ($probe in $processes) {
    if (-not $probe.Process.WaitForExit(180000)) {
      # Own diagnostic process only; each fixture already bounds its children.
      $probe.Process.Kill()
      throw "Diagnostic fixture timed out: $($probe.Name)"
    }
    $probe.Process.WaitForExit()
    $probe.Process.Refresh()
    Write-Host "round=$round test=$($probe.Name) exit=$($probe.Process.ExitCode)"
    if ($probe.Process.ExitCode -ne 0) {
      $failed += $probe.Name
      Get-Content $probe.Out
      Get-Content $probe.Err
    }
  }
  if ($failed.Count -gt 0) { throw "Reproduced failures: $($failed -join ', ')" }
}

# Real original/fixed child comparison. Same production hooks and deadlines.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PWD '.toolchain/windows/bootstrap-toolchain.ps1')
$null = Invoke-ReproToolchainBootstrap
$evidence = Join-Path $PWD 'build/windows-slow-call-child'
New-Item -ItemType Directory -Force $evidence | Out-Null
@'
#include <windows.h>
#include <stdio.h>
int main(void) {
  typedef BOOL (WINAPI *MachineFn)(HANDLE, USHORT *, USHORT *);
  MachineFn machine = (MachineFn)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "IsWow64Process2");
  if (!machine) return 1;
  USHORT process, native;
  if (!machine(GetCurrentProcess(), &process, &native)) return 2;
  printf("observer_process_machine=%04x native_machine=%04x\n", process, native);
  WCHAR app[32768], command[] = L"cmd /c exit 42";
  DWORD len = GetEnvironmentVariableW(L"ComSpec", app, 32768);
  if (!len || len >= 32768) return 3;
  STARTUPINFOW si = {0}; si.cb = sizeof(si);
  PROCESS_INFORMATION pi = {0};
  if (!CreateProcessW(app, command, NULL, NULL, FALSE, CREATE_SUSPENDED | CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) return 4;
  BOOL ok = machine(pi.hProcess, &process, &native);
  if (ok) printf("comspec_process_machine=%04x native_machine=%04x\n", process, native);
  TerminateProcess(pi.hProcess, 99);
  WaitForSingleObject(pi.hProcess, 10000);
  CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
  return ok ? 0 : 5;
}
'@ | Set-Content "$evidence/child-machine.c"
& gcc "$evidence/child-machine.c" -o "$evidence/child-machine.exe" *> "$evidence/child-machine-build.log"
if ($LASTEXITCODE) { throw 'Cannot build the real child-machine observer' }
& "$evidence/child-machine.exe" *> "$evidence/child-machine.log"
if ($LASTEXITCODE) { throw 'Cannot observe the original child architecture' }
Get-Content "$evidence/child-machine.log"
$savedTemp = $env:TEMP
$savedTmp = $env:TMP
$results = @()
Push-Location nim-stackable-hooks
try {
    $source = 'tests/test_windows_entry_park_slow_call.nim'
    $changed = @(& git diff --name-only HEAD^ HEAD)
    if ($LASTEXITCODE -or $changed.Count -ne 1 -or $changed[0] -ne $source) {
        throw 'The paired sources must differ only in the slow-call child fixture'
    }
    foreach ($variant in @('original', 'matched')) {
        $ref = if ($variant -eq 'original') { 'HEAD^' } else { 'HEAD' }
        & git restore "--source=$ref" -- $source
        if ($LASTEXITCODE) { throw "Cannot select $variant source" }
        $folder = Join-Path $evidence $variant
        New-Item -ItemType Directory -Force $folder | Out-Null
        $env:TEMP = $folder
        $env:TMP = $folder
        & git rev-parse $ref > "$folder/source-sha.txt"
        & nim c --cpu:amd64 --hints:off --cc:gcc "--nimcache:$folder/cache" "--out:$folder/test.exe" $source *> "$folder/build.log"
        $buildCode = $LASTEXITCODE
        $runCode = $null
        if ($buildCode -eq 0) {
            & "$folder/test.exe" *> "$folder/test.log"
            $runCode = $LASTEXITCODE
            Get-Content "$folder/test.log"
        }
        $results += @{variant=$variant; buildExitCode=$buildCode; testExitCode=$runCode}
        $results | ConvertTo-Json -AsArray | Set-Content "$evidence/results.json"
    }
    $fixed = $results | Where-Object { $_.variant -eq 'matched' }
    if ($fixed.buildExitCode -ne 0 -or $fixed.testExitCode -ne 0) { throw 'The matched child failed' }
} finally {
    & git restore --source=HEAD -- tests/test_windows_entry_park_slow_call.nim
    Pop-Location
    $env:TEMP = $savedTemp
    $env:TMP = $savedTmp
}

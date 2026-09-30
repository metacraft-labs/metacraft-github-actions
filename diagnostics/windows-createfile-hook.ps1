$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PWD '.toolchain/windows/bootstrap-toolchain.ps1')
$null = Invoke-ReproToolchainBootstrap
$evidence = Join-Path $PWD 'build/windows-createfile-hook'
New-Item -ItemType Directory -Force $evidence | Out-Null
$source = Join-Path $PWD 'nim-stackable-hooks/src/stackable_hooks/inline_hook/windows'
git -C nim-stackable-hooks rev-parse HEAD | Set-Content "$evidence/hooks-sha.txt"
$installer = [IO.File]::ReadAllText("$source/install_windows.c").Replace("`r`n", "`n")
$anchor = "static int write_patch(void *from, size_t len, const uint8_t *bytes)`n{"
if (-not $installer.Contains($anchor)) { throw 'Exact installer anchor changed' }
$installer = $installer.Replace($anchor, "extern volatile long *repro_hook_probe_state;`n" + $anchor + "`n    repro_hook_probe_state[1] = 130;")
$anchor = '    memcpy(from, bytes, len);'
if (-not $installer.Contains($anchor)) { throw 'Exact write anchor changed' }
$installer = $installer.Replace($anchor, "    repro_hook_probe_state[1] = 131;`n" + $anchor)
[IO.File]::WriteAllText("$evidence/install_windows.c", $installer)
& gcc -O1 -Wall -Wextra "-I$source" -o "$evidence/probe.exe" "$PSScriptRoot/windows-createfile-hook.c" "$evidence/install_windows.c" "$source/length_decoder.c" "$source/rel32_fixup.c" *> "$evidence/build.log"
if ($LASTEXITCODE) { throw 'Could not build the real hook installer control' }
$results = @()
if ($env:REPRO_PROBE_SHIM) {
    # Read only this probe child's one exported diagnostic integer. Native
    # ARM PowerShell can read the x64 child's address without context decoding.
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ProbeMemory {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool ReadProcessMemory(IntPtr process, IntPtr address,
        byte[] buffer, UIntPtr size, out UIntPtr read);
}
'@
}
foreach ($round in 1..32) {
    foreach ($mode in @('original', 'prepared')) {
        $log = "$evidence/$mode-$round.log"
        $arguments = @($mode)
        if ($env:REPRO_PROBE_SHIM) {
            $arguments += '"' + $env:REPRO_PROBE_SHIM + '"'
            $env:REPRO_MONITOR_FRAGMENT_DIR = "$evidence/fragments-$mode-$round"
            New-Item -ItemType Directory -Force $env:REPRO_MONITOR_FRAGMENT_DIR | Out-Null
        }
        $process = Start-Process -FilePath "$evidence/probe.exe" -ArgumentList $arguments -PassThru -NoNewWindow -RedirectStandardOutput $log -RedirectStandardError "$evidence/$mode-$round.stderr"
        $finished = $process.WaitForExit(30000)
        $state = $null
        if (-not $finished) {
            $map = $null; $view = $null
            try {
                $map = [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting("Local\ReproHookProbe-$($process.Id)", [IO.MemoryMappedFiles.MemoryMappedFileRights]::Read)
                $view = $map.CreateViewAccessor(0, 16, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
                $state = @{stage=$view.ReadInt32(0); patchPhase=$view.ReadInt32(4)}
                $address = $view.ReadInt64(8)
                if ($env:REPRO_PROBE_SHIM -and $address) {
                    $bytes = New-Object byte[] 4
                    $read = [UIntPtr]::Zero
                    if ([ProbeMemory]::ReadProcessMemory($process.Handle, [IntPtr]$address, $bytes, [UIntPtr]4, [ref]$read) -and $read.ToUInt64() -eq 4) {
                        $state.shimPhase = [BitConverter]::ToUInt32($bytes, 0)
                    } else { $state.readError = [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
                }
            } catch { $state = @{error=$_.Exception.Message} }
            finally { if ($view) { $view.Dispose() }; if ($map) { $map.Dispose() } }
            $process.Kill($true); $process.WaitForExit()
        }
        $results += @{mode=$mode; round=$round; finished=$finished; exitCode=$process.ExitCode; observation=$state}
        $results | ConvertTo-Json -Depth 4 | Set-Content "$evidence/results.json"
        Write-Host "$mode round=$round finished=$finished exit=$($process.ExitCode)"
        $process.Dispose()
    }
}
if (@($results | Where-Object { -not $_.finished -or $_.exitCode -ne 0 }).Count) {
    throw 'A real installer control failed; retain both comparison modes'
}

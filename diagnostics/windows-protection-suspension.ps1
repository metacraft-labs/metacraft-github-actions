$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PWD '.toolchain/windows/bootstrap-toolchain.ps1')
$null = Invoke-ReproToolchainBootstrap
$evidence = Join-Path $PWD 'build/windows-protection-suspension'
New-Item -ItemType Directory -Force $evidence | Out-Null
& gcc -v *> "$evidence/compiler.txt"
& gcc -O1 -Wall -Wextra -o "$evidence/probe.exe" "$PSScriptRoot/windows-protection-suspension.c" *> "$evidence/build.log"
if ($LASTEXITCODE) { throw 'Could not compile the real Windows API probe' }
& gcc -shared -fcf-protection=none -Wall -Wextra -o "$evidence/protection-target.dll" "$PSScriptRoot/windows-protection-target.c" *> "$evidence/target-build.log"
if ($LASTEXITCODE) { throw 'Could not compile the real image-page target' }
$results = @()
foreach ($round in 1..2) {
  foreach ($scope in @('known', 'all')) {
   foreach ($backing in @('private', 'image', 'system')) {
    foreach ($mode in @('active', 'protect', 'flush', 'write')) {
        $log = "$evidence/$scope-$backing-$mode-$round.log"
        $err = "$evidence/$scope-$backing-$mode-$round.stderr"
        $process = Start-Process -FilePath "$evidence/probe.exe" -ArgumentList @($mode, $scope, $backing) -PassThru -NoNewWindow -RedirectStandardOutput $log -RedirectStandardError $err
        $finished = $process.WaitForExit(30000)
        $state = $null
        if (-not $finished) {
            $map = $null; $view = $null
            try {
                $map = [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting("Local\ReproProtectionProbe-$($process.Id)", [IO.MemoryMappedFiles.MemoryMappedFileRights]::Read)
                $view = $map.CreateViewAccessor(0, 16, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
                $state = @{round=$view.ReadInt32(0); phase=$view.ReadInt32(4); frozen=$view.ReadInt32(8); thread=$view.ReadInt32(12)}
            } catch { $state = @{error=$_.Exception.Message} }
            finally { if ($view) { $view.Dispose() }; if ($map) { $map.Dispose() } }
        }
        if (-not $finished) { $process.Kill($true); $process.WaitForExit() }
        $results += @{mode=$mode; scope=$scope; backing=$backing; round=$round; finished=$finished; exitCode=$process.ExitCode; observation=$state}
        $results | ConvertTo-Json -Depth 3 | Set-Content "$evidence/results.json"
        Write-Host "$scope $backing $mode round=$round finished=$finished exit=$($process.ExitCode) observation=$($state | ConvertTo-Json -Compress)"
        Get-Content $log -Tail 4
        $process.Dispose()
    }
   }
  }
}
if (@($results | Where-Object { $_.mode -eq 'active' -and (-not $_.finished -or $_.exitCode -ne 0) }).Count) {
    throw 'Active-worker controls failed; this run does not isolate suspension'
}

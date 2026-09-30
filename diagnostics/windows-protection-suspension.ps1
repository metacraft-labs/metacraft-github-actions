$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PWD '.toolchain/windows/bootstrap-toolchain.ps1')
$null = Invoke-ReproToolchainBootstrap
$evidence = Join-Path $PWD 'build/windows-protection-suspension'
New-Item -ItemType Directory -Force $evidence | Out-Null
& gcc -v *> "$evidence/compiler.txt"
& gcc -O1 -Wall -Wextra -o "$evidence/probe.exe" "$PSScriptRoot/windows-protection-suspension.c" *> "$evidence/build.log"
if ($LASTEXITCODE) { throw 'Could not compile the real Windows API probe' }
$results = @()
foreach ($round in 1..4) {
    foreach ($mode in @('active', 'protect', 'flush', 'write')) {
        $log = "$evidence/$mode-$round.log"
        $err = "$evidence/$mode-$round.stderr"
        $process = Start-Process -FilePath "$evidence/probe.exe" -ArgumentList $mode -PassThru -NoNewWindow -RedirectStandardOutput $log -RedirectStandardError $err
        $finished = $process.WaitForExit(30000)
        if (-not $finished) { $process.Kill($true); $process.WaitForExit() }
        $results += @{mode=$mode; round=$round; finished=$finished; exitCode=$process.ExitCode}
        $results | ConvertTo-Json -Depth 3 | Set-Content "$evidence/results.json"
        Write-Host "$mode round=$round finished=$finished exit=$($process.ExitCode)"
        Get-Content $log -Tail 4
        $process.Dispose()
    }
}
if (@($results | Where-Object { $_.mode -eq 'active' -and (-not $_.finished -or $_.exitCode -ne 0) }).Count) {
    throw 'Active-worker controls failed; this run does not isolate suspension'
}

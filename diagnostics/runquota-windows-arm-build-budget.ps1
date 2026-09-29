# Full real compilation and tests, with a bounded outer graph. No mocks or
# deadline changes. The ordinary eight-action candidate runs independently.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$evidence = Join-Path $PWD 'build/windows-arm-budget'
New-Item -ItemType Directory -Force $evidence | Out-Null
Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors |
    ConvertTo-Json | Set-Content "$evidence/processors.json"
Get-ChildItem Env: | Where-Object Name -Like '*ARCHITECTURE*' |
    Format-Table -AutoSize | Out-String | Set-Content "$evidence/architecture.txt"
$env:REPROBUILD_MAX_PARALLELISM = '2'
$sample = Start-Job -ArgumentList $evidence -ScriptBlock {
    param($evidence)
    while (-not (Test-Path "$evidence/stop-sampling")) {
        $processes = @(Get-Process -ErrorAction SilentlyContinue)
        [PSCustomObject]@{
            timestamp = (Get-Date).ToUniversalTime().ToString('o')
            nim = @($processes | Where-Object ProcessName -EQ 'nim').Count
            gcc = @($processes | Where-Object ProcessName -EQ 'gcc').Count
            cc1 = @($processes | Where-Object ProcessName -EQ 'cc1').Count
        } | ConvertTo-Json -Compress | Add-Content "$evidence/process-counts.jsonl"
        Start-Sleep -Seconds 5
    }
}
try {
    & bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/build.log" repro build --daemon=off --tool-provisioning=tarball "--write-report=$evidence/build.json"
    if ($LASTEXITCODE) { throw 'Full monitored compilation failed' }
    & bash "$PSScriptRoot/capture-ci-command.sh" "$evidence/test.log" repro test --daemon=off --tool-provisioning=tarball "--write-report=$evidence/test.json"
    if ($LASTEXITCODE) { throw 'Full monitored tests failed' }
} finally {
    New-Item -ItemType File -Force "$evidence/stop-sampling" | Out-Null
    Wait-Job $sample -Timeout 10 | Out-Null
    Receive-Job $sample | Set-Content "$evidence/sampler.log"
    Stop-Job $sample
    Remove-Job $sample
}

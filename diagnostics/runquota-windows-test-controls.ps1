# No mocks: rerun the exact binaries from the completed product graph using
# its declared tool environment. Keep the original graph failure as a failure.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$report = Get-Content build/diagnostic-test.json -Raw | ConvertFrom-Json
$failed = @($report.actions | Where-Object {
    $_.id.StartsWith('runquota.test_execute.') -and $_.status -eq 'asFailed'
})
$evidence = Join-Path $PWD 'build/windows-controls'
New-Item -ItemType Directory -Force $evidence | Out-Null
$env:REPRO_TOOL_PROVISIONING = 'tarball'
$results = @()
'[]' | Set-Content "$evidence/results.json"
foreach ($action in $failed) {
    $name = $action.id.Substring('runquota.test_execute.'.Length)
    $binary = Join-Path $PWD "build/test-bin/$name.exe"
    $before = (Get-FileHash -Algorithm SHA256 $binary).Hash
    foreach ($mode in @('direct', 'timeout')) {
        $log = Join-Path $evidence "$name-$mode.log"
        Write-Host "Control $name $mode sha256=$before"
        if ($mode -eq 'direct') {
            & repro exec -- $binary 2>&1 | Tee-Object -FilePath $log
        } else {
            & repro exec -- timeout --kill-after=10 600 $binary 2>&1 |
                Tee-Object -FilePath $log
        }
        $code = $LASTEXITCODE
        $after = (Get-FileHash -Algorithm SHA256 $binary).Hash
        if ($after -ne $before) { throw "Control changed test binary: $name" }
        $results += [ordered]@{name=$name; mode=$mode; exitCode=$code; sha256=$before}
        $results | ConvertTo-Json -Depth 4 | Set-Content "$evidence/results.json"
        Write-Host "Control result $name $mode exit=$code"
    }
}
Get-CimInstance Win32_LogicalDisk |
    Select-Object DeviceID, DriveType, FileSystem |
    ConvertTo-Json | Set-Content "$evidence/logical-disks.json"
Get-PhysicalDisk | Select-Object FriendlyName, MediaType, BusType |
    ConvertTo-Json | Set-Content "$evidence/physical-disks.json"
Get-Disk | Select-Object Number, FriendlyName, BusType, PartitionStyle |
    ConvertTo-Json | Set-Content "$evidence/disks.json"
Get-Content "$evidence/results.json"
exit 0

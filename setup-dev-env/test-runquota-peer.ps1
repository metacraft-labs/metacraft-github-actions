# Native kernel boundary test. The private pipe is an actual Windows pipe,
# served by this retained PowerShell process; no RunQuota executable/protocol
# is mocked and no host daemon is opened. This tests observation, not leases.
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This test requires native Windows PowerShell Core' }
. "$PSScriptRoot/record-runquota-peer.ps1"

function Assert-Receipt($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

Assert-Receipt ([RunQuotaPeerReceipt]::Endpoint('') -ceq '\\.\pipe\runquota\runquotad') 'Default endpoint changed'
Assert-Receipt ([RunQuotaPeerReceipt]::Endpoint($null) -ceq '\\.\pipe\runquota\runquotad') 'Unset endpoint changed'
Assert-Receipt ([RunQuotaPeerReceipt]::Endpoint('C:\Receipt\SÖCKET.sock') -ceq '\\.\pipe\runquota-7F57AB923C5C648F') 'UTF-8/ASCII folding or FNV mapping changed'
Assert-Receipt ([RunQuotaPeerReceipt]::Endpoint('\\?\pipe\ExactCase') -ceq '\\?\pipe\ExactCase') 'Literal pipe path changed'

$name = 'setup-peer-' + [Guid]::NewGuid().ToString('N')
$endpoint = '\\.\pipe\' + $name
$server = [IO.Pipes.NamedPipeServerStream]::new($name, [IO.Pipes.PipeDirection]::InOut,
    1, [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous)
$savedCandidate = $env:RUNQUOTAD_BIN
try {
    $accepted = $server.WaitForConnectionAsync()
    # A different candidate is deliberately present: endpoint identity must
    # come from the kernel, never this environment value or a process-name scan.
    $env:RUNQUOTAD_BIN = $env:ComSpec
    $receipt = Get-RunQuotaEndpointReceipt $endpoint
    Assert-Receipt ($receipt.state -ceq 'observed') ($receipt | ConvertTo-Json -Compress)
    Assert-Receipt ($receipt.serverPID -eq $PID) 'Receipt names another process'
    $own = Get-Process -Id $PID
    Assert-Receipt ($receipt.creationFILETIME -eq $own.StartTime.ToUniversalTime().ToFileTimeUtc()) 'Creation identity differs'
    Assert-Receipt ($receipt.imagePath -ieq $own.Path) 'Kernel image path differs'
    Assert-Receipt ($receipt.imageFileSHA256 -ceq (Get-FileHash -LiteralPath $own.Path -Algorithm SHA256).Hash.ToLowerInvariant()) 'Image file hash differs'
    Assert-Receipt ($receipt.imagePath -ine $env:RUNQUOTAD_BIN) 'Installed candidate substituted for endpoint peer'
    Assert-Receipt ($accepted.Wait(5000)) 'Private pipe connection was not accepted'
    Assert-Receipt ($server.ReadByte() -eq -1) 'Observer sent protocol traffic'
    Assert-Receipt (-not $own.HasExited) 'Observation stopped the server'
} finally {
    $env:RUNQUOTAD_BIN = $savedCandidate
    $server.Dispose()
}

$missing = Get-RunQuotaEndpointReceipt ($endpoint + '-absent')
Assert-Receipt ($missing.state -ceq 'unknown') 'Missing endpoint acquired a false identity'
Assert-Receipt ($missing.nativeError -eq 2) 'Missing endpoint error was lost'
Assert-Receipt (-not $missing.PSObject.Properties['serverPID']) 'Unknown observation claims a process'
Assert-Receipt (-not $missing.PSObject.Properties['imageFileSHA256']) 'Unknown observation claims image bytes'
'Native endpoint selection, kernel identity, image hash, no-traffic and unknown controls passed'

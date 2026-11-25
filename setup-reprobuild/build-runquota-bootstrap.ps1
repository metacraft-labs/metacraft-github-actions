# Build the real, selected RunQuota source with the source bootstrap toolchain.
# No service configuration is changed; Reprobuild owns daemon discovery/startup.
$ErrorActionPreference = 'Stop'
$workspaceRoot = if ($env:MCL_WORKSPACE_ROOT) { $env:MCL_WORKSPACE_ROOT } else { $env:GITHUB_WORKSPACE }
$source = Join-Path $workspaceRoot 'runquota'
$leaseSource = Join-Path $workspaceRoot 'nim-shm-lease/src'
if (-not (Test-Path (Join-Path $source 'apps/runquotad/runquotad.nim'))) {
    throw "RunQuota source is missing from $source"
}
if (-not (Test-Path (Join-Path $leaseSource 'shm_lease/anchor.nim'))) {
    throw "RunQuota's selected nim-shm-lease source is missing from $leaseSource"
}
$outputRoot = Join-Path $env:RUNNER_TEMP 'reprobuild-bootstrap-runquota'
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$daemon = Join-Path $outputRoot 'runquotad.exe'
# The client too: a source-built SDK has no release bundle to carry it, and
# callers that query the daemon (the wrapper contract test) need the matching
# one. RUNQUOTA_BIN names it, as RUNQUOTAD_BIN names the daemon. Both are set
# in the calling step's process; that step decides where they are exported.
$client = Join-Path $outputRoot 'runquota.exe'
$cache = Join-Path $outputRoot 'nimcache'
$previousLeaseSource = $env:SHM_LEASE_SRC
try {
    $env:SHM_LEASE_SRC = $leaseSource
    Push-Location $source
    try {
        nim c --threads:on -d:release "--nimcache:$cache" "--out:$daemon" apps/runquotad/runquotad.nim
        if ($LASTEXITCODE -ne 0) { throw "RunQuota bootstrap compilation failed: $LASTEXITCODE" }
        nim c --threads:on -d:release "--nimcache:$cache-client" "--out:$client" apps/runquota/runquota.nim
        if ($LASTEXITCODE -ne 0) { throw "RunQuota client bootstrap compilation failed: $LASTEXITCODE" }
    } finally { Pop-Location }
} finally { $env:SHM_LEASE_SRC = $previousLeaseSource }
& $daemon --version
if ($LASTEXITCODE -ne 0) { throw "RunQuota bootstrap executable failed: $LASTEXITCODE" }
$env:RUNQUOTAD_BIN = (Resolve-Path -LiteralPath $daemon).Path
& $client --version
if ($LASTEXITCODE -ne 0) { throw "RunQuota client bootstrap executable failed: $LASTEXITCODE" }
$env:RUNQUOTA_BIN = (Resolve-Path -LiteralPath $client).Path

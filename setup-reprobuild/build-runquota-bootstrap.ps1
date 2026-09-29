# Build the real, selected RunQuota source with the source bootstrap toolchain.
# No service configuration is changed; Reprobuild owns daemon discovery/startup.
$ErrorActionPreference = 'Stop'
$source = Join-Path $env:GITHUB_WORKSPACE 'runquota'
$leaseSource = Join-Path $env:GITHUB_WORKSPACE 'nim-shm-lease/src'
if (-not (Test-Path (Join-Path $source 'apps/runquotad/runquotad.nim'))) {
    throw "RunQuota source is missing from $source"
}
if (-not (Test-Path (Join-Path $leaseSource 'shm_lease/anchor.nim'))) {
    throw "RunQuota's selected nim-shm-lease source is missing from $leaseSource"
}
$outputRoot = Join-Path $env:RUNNER_TEMP 'reprobuild-bootstrap-runquota'
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$daemon = Join-Path $outputRoot 'runquotad.exe'
$cache = Join-Path $outputRoot 'nimcache'
$previousLeaseSource = $env:SHM_LEASE_SRC
try {
    $env:SHM_LEASE_SRC = $leaseSource
    Push-Location $source
    try {
        nim c --threads:on -d:release "--nimcache:$cache" "--out:$daemon" apps/runquotad/runquotad.nim
        if ($LASTEXITCODE -ne 0) { throw "RunQuota bootstrap compilation failed: $LASTEXITCODE" }
    } finally { Pop-Location }
} finally { $env:SHM_LEASE_SRC = $previousLeaseSource }
& $daemon --version
if ($LASTEXITCODE -ne 0) { throw "RunQuota bootstrap executable failed: $LASTEXITCODE" }
$env:RUNQUOTAD_BIN = (Resolve-Path -LiteralPath $daemon).Path
Add-Content -Path $env:GITHUB_ENV -Value "RUNQUOTAD_BIN=$env:RUNQUOTAD_BIN"

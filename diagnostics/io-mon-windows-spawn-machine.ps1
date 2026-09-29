# Real suspended children, the real slow DLL and unchanged timeout assertions.
# Validate the production repair and native ARM refusal with both compilers.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$Target = 'windows-x86_64'
$env:RELEASE_TOOLS = Join-Path $PWD '.release-tools/release-tools'
. "$env:RELEASE_TOOLS/common.ps1"
. './.bootstrap-tools/windows/toolchain-utils.ps1'
. './.bootstrap-tools/windows/ensure-gcc.ps1'
$pins = Read-KeyValueFile -Path './.bootstrap-tools/windows/toolchain-versions.env'
$gccRoot = Ensure-Gcc -Root "$env:RUNNER_TEMP/spawn-gcc" -Arch x64 -Toolchain $pins
$gcc = Join-Path $gccRoot 'bin/gcc.exe'
$env:PATH = "$(Split-Path $gcc);$env:PATH"
$ReleaseFlags = @('--threads:on','--cpu:amd64','--cc:gcc',"--gcc.exe:$gcc","--gcc.linkerexe:$gcc")
Get-ReleaseDependency 'stackable-hooks-src' 'STACKABLE_HOOKS_SRC'
Get-ReleaseDependency 'shm-queue-src' 'SHM_QUEUE_SRC'
Get-ReleaseDependency 'shm-gset-src' 'SHM_GSET_SRC'
$evidence = Join-Path $PWD 'build/windows-spawn-machine'
New-Item -ItemType Directory -Force $evidence | Out-Null
$nimRoot = Join-Path $env:RUNNER_TEMP 'spawn-nim-2.2.10'
New-Item -ItemType Directory -Force $nimRoot | Out-Null
Invoke-WebRequest 'https://nim-lang.org/download/nim-2.2.10_x64.zip' -OutFile "$nimRoot/nim.zip"
if ((Get-FileHash "$nimRoot/nim.zip").Hash -ne 'fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f') { throw 'Nim digest mismatch' }
Expand-Archive "$nimRoot/nim.zip" $nimRoot -Force
$versions = @(
    @{version='2.2.8'; executable=$env:RELEASE_NIM},
    @{version='2.2.10'; executable="$nimRoot/nim-2.2.10/bin/nim.exe"}
)
function Machine([string]$Path) {
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path))
    try {
        $reader.BaseStream.Position = 0x3c
        $offset = $reader.ReadInt32()
        $reader.BaseStream.Position = $offset + 4
        return ('0x{0:x4}' -f $reader.ReadUInt16())
    } finally { $reader.Dispose() }
}
$results = @()
$basePath = $env:PATH
try {
    foreach ($version in $versions) {
        $env:RELEASE_NIM = $version.executable
        $env:PATH = "$(Split-Path $version.executable);$basePath"
        & nim --version
        $shimDir = Join-Path $evidence "shim-$($version.version)"
        New-Item -ItemType Directory -Force $shimDir | Out-Null
        $shim = Join-Path $shimDir 'librepro_monitor_shim.dll'
        Invoke-ReleaseNim 'src/io_mon/shim/windows_interpose.nim' $shim @('--app:lib','-d:useMalloc','--passL:-static-libgcc') *> "$evidence/shim-$($version.version)-compile.log"
        if ((Machine $shim) -ne '0x8664') { throw 'Shim is not x64' }
        $env:REPRO_MONITOR_SHIM_LIB = $shim
        foreach ($fixture in @('spawn_abandoned_injection', 'native_system_child')) {
            $name = "$fixture-$($version.version)"
            $binary = Join-Path $evidence "$name.exe"
            Invoke-ReleaseNim "tests/windows/test_io_mon_windows_$fixture.nim" $binary *> "$evidence/$name-compile.log"
            if ((Machine $binary) -ne '0x8664') { throw 'Test executable is not x64' }
            foreach ($round in 1..3) {
                $prefix = "$evidence/$name-$round"
                & python "$PSScriptRoot/capture-windows-exit.py" $prefix $binary
                if ($LASTEXITCODE -ne 0) { throw 'Fixture capture failed' }
                Get-Content "$prefix.log"
                $capture = Get-Content "$prefix.json" -Raw | ConvertFrom-Json
                $results += @{nim=$version.version; fixture=$fixture; round=$round; exitCode=$capture.exitCode; timedOut=$capture.timedOut; testMachine=(Machine $binary); shimMachine=(Machine $shim)}
                $results | ConvertTo-Json | Set-Content "$evidence/results.json"
            }
        }
    }
} finally {
    $env:PATH = $basePath
    $results | ConvertTo-Json | Set-Content "$evidence/results.json"
}
if (@($results | Where-Object { $_.timedOut -or $_.exitCode -ne 0 }).Count) { throw 'Production process-machine regression failed' }

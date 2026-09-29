# Real suspended children, the real slow DLL and unchanged timeout assertions.
# Compare the current guard with the OS's explicit process-machine query.
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
$source = Join-Path $PWD 'src/io_mon/shim/windows_interpose.nim'
$original = [IO.File]::ReadAllText($source)
$declarations = @'
type DiagnosticMachineInfo {.bycopy.} = object
  processMachine: uint16
  reserved: uint16
  attributes: uint32
proc DiagnosticGetProcessInformation(process: HANDLE; infoClass: int32;
    info: pointer; size: uint32): BOOL
  {.stdcall, dynlib: "kernel32", importc: "GetProcessInformation", raises: [].}

proc injectSpawnedChild(record: var MonitorRecord;
'@
$instrumented = $original.Replace('proc injectSpawnedChild(record: var MonitorRecord;', $declarations.TrimEnd())
$anchor = '  let machine = if processMachine == 0: nativeMachine else: processMachine'
if (-not $instrumented.Contains($anchor)) { throw 'Missing architecture guard anchor' }
$query = @'
  var machineInfo: DiagnosticMachineInfo
  let machineOk = DiagnosticGetProcessInformation(pi[].hProcess, 9,
    addr machineInfo, uint32(sizeof(machineInfo)))
  let machineError = GetLastError()
  try:
    echo "DIAGNOSTIC processMachine=", toHex(processMachine),
      " nativeMachine=", toHex(nativeMachine), " queryOk=", machineOk,
      " explicitMachine=", toHex(machineInfo.processMachine),
      " attributes=", toHex(machineInfo.attributes), " error=", machineError
    flushFile(stdout)
  except CatchableError:
    discard
'@
$instrumented = $instrumented.Replace($anchor, $query.TrimEnd() + "`n" + $anchor)
$outcome = @'
  try:
    echo "DIAGNOSTIC injection outcome=", report.outcome, " waited_ms=", report.waitedMs
    flushFile(stdout)
  except CatchableError:
    discard
  if report.outcome != shProp.ioInjected and
'@
$instrumented = $instrumented.Replace('  if report.outcome != shProp.ioInjected and', $outcome.TrimEnd())
$queryGuard = @'
  let machine = if machineOk != 0: machineInfo.processMachine
    elif processMachine != 0: processMachine
    else: nativeMachine
'@
$results = @()
$basePath = $env:PATH
try {
    foreach ($version in $versions) {
        $env:RELEASE_NIM = $version.executable
        $env:PATH = "$(Split-Path $version.executable);$basePath"
        & nim --version
        foreach ($mode in @('current', 'explicit-process-machine')) {
            $text = if ($mode -eq 'current') { $instrumented } else { $instrumented.Replace($anchor, $queryGuard.TrimEnd()) }
            [IO.File]::WriteAllText($source, $text)
            $name = "spawn-$($version.version)-$mode"
            $binary = Join-Path $evidence "$name.exe"
            Invoke-ReleaseNim 'tests/windows/test_io_mon_windows_spawn_abandoned_injection.nim' $binary *> "$evidence/$name-compile.log"
            if ($LASTEXITCODE -ne 0) { throw 'Actual fixture compilation failed' }
            if ((Machine $binary) -ne '0x8664') { throw 'Test executable is not x64' }
            foreach ($round in 1..3) {
                $prefix = "$evidence/$name-$round"
                & python "$PSScriptRoot/capture-windows-exit.py" $prefix $binary
                if ($LASTEXITCODE -ne 0) { throw 'Fixture capture failed' }
                Get-Content "$prefix.log"
                $capture = Get-Content "$prefix.json" -Raw | ConvertFrom-Json
                $dll = Join-Path ([IO.Path]::GetTempPath()) 'io-mon-slow-load/slow_load_lib.dll'
                $results += @{nim=$version.version; mode=$mode; round=$round; exitCode=$capture.exitCode; timedOut=$capture.timedOut; testMachine=(Machine $binary); dllMachine=(Machine $dll)}
                $results | ConvertTo-Json | Set-Content "$evidence/results.json"
            }
        }
    }
} finally {
    [IO.File]::WriteAllText($source, $original)
    $env:PATH = $basePath
    $results | ConvertTo-Json | Set-Content "$evidence/results.json"
}
if (@($results | Where-Object { $_.mode -eq 'explicit-process-machine' -and ($_.timedOut -or $_.exitCode -ne 0) }).Count) { throw 'Explicit process-machine comparison failed' }

## Real assembler, pinned injector and retained failing shim; no mocks.
## Each parent starts a fresh assembler through the normal entry-park path.
## Successful assembly must produce an x64 COFF object and real read/write
## records belonging to the injected child. The default deadlines are intact.
import std/[os, osproc, strtabs, strutils, json]
import stackable_hooks/windows_injector
import io_mon/[codec, encode, types]

let args = commandLineParams()
doAssert args.len == 4
let mode = args[0]
let assembler = args[1]
let shim = args[2]
let evidence = absolutePath(args[3])
createDir(evidence)
let source = evidence / "borrowed-assembler-input.s"
let target = evidence / "borrowed-assembler-output.o"
writeFile(source, ".text\n.globl probe\nprobe:\n  ret\n")
let fragmentDir = evidence / "fragments"
createDir(fragmentDir)
var code: int
var rootPid: uint64
if mode == "native":
  let child = startProcess(assembler, args = [source, "-o", target],
    options = {poParentStreams})
  code = child.waitForExit()
  child.close()
else:
  doAssert mode == "monitored"
  var environment = newStringTable(modeCaseInsensitive)
  for key, value in envPairs(): environment[key] = value
  environment["REPRO_MONITOR_FRAGMENT_DIR"] = fragmentDir
  environment["REPRO_MONITOR_SESSION"] = "borrowed-assembler"
  environment["REPRO_MONITOR_SHIM_LIB"] = shim
  let observed = runWithMonitorShim([assembler, source, "-o", target], shim,
    captureStdio = true, captureStdioPath = evidence / "assembler.log",
    env = environment)
  doAssert not observed.monitoringSkipped
  code = observed.exitCode
  rootPid = observed.rootPid
doAssert code == 0
let objectBytes = readFile(target)
doAssert objectBytes.len > 20
doAssert objectBytes[0] == '\x64' and objectBytes[1] == '\x86'
var started = false
var readSource = false
var wroteObject = false
if mode == "monitored":
  for path in walkFiles(fragmentDir / "*.iomon-frag"):
    for record in decodeFrames(readFile(path).toBytes()):
      if record.osPid != rootPid: continue
      if record.kind == mrProcessStart: started = true
      let name = record.path.replace('\\', '/').extractFilename.toLowerAscii()
      if record.kind == mrFileRead and name == source.extractFilename:
        readSource = true
      if record.kind == mrFileWrite and name == target.extractFilename:
        wroteObject = true
  doAssert started and readSource and wroteObject
echo %*{"mode": mode, "exitCode": code, "pid": rootPid,
  "started": started, "sourceRead": readSource, "objectWritten": wroteObject}

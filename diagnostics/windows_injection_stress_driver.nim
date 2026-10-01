## Real native/injected children; preserve their DWORD status in JSON before
## returning a Boolean diagnostic status. No mocked Windows APIs.
import std/[json, os, osproc, streams, strtabs, strutils]
import stackable_hooks/windows_injector

proc ExitProcess(code: uint32) {.stdcall, importc, dynlib: "kernel32", noreturn.}

let args = commandLineParams()
if args == @["--exit-code-control"]:
  ExitProcess(0xC0000005'u32)
if args == @["--capture-control"]:
  stdout.write("first\n")
  stdout.flushFile()
  sleep(100)
  stdout.write("second\n")
  stdout.flushFile()
  quit 17
doAssert args.len >= 4
let mode = args[0]
let target = absolutePath(args[1])
let shim = absolutePath(args[2])
let folder = absolutePath(args[3])
let targetArgs = args[4 .. ^1]
createDir(folder)
var rawCode: uint32
var pid: uint64
if mode == "native":
  let child = startProcess(target, args = targetArgs,
    options = {poStdErrToStdOut})
  pid = uint64(child.processID)
  # readAll stops after a short pipe read. These children have no descendants,
  # so drain until real EOF to retain output emitted after the suite heading.
  let capture = open(folder / "target.log", fmWrite)
  var buffer: array[8192, char]
  while true:
    let count = child.outputStream.readData(addr buffer[0], buffer.len)
    if count == 0: break
    discard capture.writeBuffer(addr buffer[0], count)
  capture.close()
  rawCode = uint32(int64(child.waitForExit()) and 0xFFFFFFFF'i64)
  child.close()
else:
  doAssert mode == "monitored"
  let fragments = folder / "fragments"
  createDir(fragments)
  var environment = newStringTable(modeCaseInsensitive)
  for key, value in envPairs(): environment[key] = value
  environment["REPRO_MONITOR_FRAGMENT_DIR"] = fragments
  environment["REPRO_MONITOR_SESSION"] = "injection-stress"
  environment["REPRO_MONITOR_SHIM_LIB"] = shim
  let observed = runWithMonitorShim(@[target] & targetArgs, shim,
    captureStdio = true, captureStdioPath = folder / "target.log",
    env = environment)
  doAssert not observed.monitoringSkipped
  rawCode = uint32(int64(observed.exitCode) and 0xFFFFFFFF'i64)
  pid = observed.rootPid
let record = %*{"mode": mode, "rootPid": pid,
  "rawExitCode": uint64(rawCode), "rawExitHex": toHex(rawCode, 8)}
writeFile(folder / "root-result.json", $record)
echo record
quit(if rawCode == 0: 0 else: 1)

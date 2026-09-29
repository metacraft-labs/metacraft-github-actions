## No mocks: load real Windows performance counters and compare native and
## monitored shutdown. This narrows the RunQuota failure without its scheduler.
import std/[dynlib, os, osproc, strutils, tempfiles, widestrs]
import io_mon

type
  OpenQuery = proc(source: WideCString; data: uint; query: ptr pointer): uint32 {.stdcall.}
  AddCounter = proc(query: pointer; path: WideCString; data: uint;
    counter: ptr pointer): uint32 {.stdcall.}
  Collect = proc(query: pointer): uint32 {.stdcall.}
  CloseQuery = proc(query: pointer): uint32 {.stdcall.}

proc child(mode, marker: string) =
  doAssert readFile(marker) == "pdh exit probe"
  if mode == "plain": return
  let library = loadLib("pdh.dll")
  doAssert library != nil
  if mode == "load": return
  let openQuery = cast[OpenQuery](library.symAddr("PdhOpenQueryW"))
  let addCounter = cast[AddCounter](library.symAddr("PdhAddEnglishCounterW"))
  let collect = cast[Collect](library.symAddr("PdhCollectQueryData"))
  let closeQuery = cast[CloseQuery](library.symAddr("PdhCloseQuery"))
  doAssert openQuery != nil and addCounter != nil and collect != nil and closeQuery != nil
  var query: pointer
  doAssert openQuery(nil, 0, addr query) == 0
  if mode != "open":
    for path in [r"\Memory\Pages Input/sec", r"\PhysicalDisk(_Total)\Current Disk Queue Length", r"\System\Processor Queue Length"]:
      var counter: pointer
      doAssert addCounter(query, newWideCString(path), 0, addr counter) == 0
    doAssert collect(query) == 0
    sleep(100)
    doAssert collect(query) == 0
  if mode == "close":
    doAssert closeQuery(query) == 0
  echo "child completed ", mode

if paramCount() == 3 and paramStr(1) == "--child":
  child(paramStr(2), paramStr(3))
else:
  let work = createTempDir("io-mon-pdh-exit-", "")
  defer: removeDir(work)
  let marker = work / "marker.txt"
  writeFile(marker, "pdh exit probe")
  var failed = false
  for mode in ["plain", "load", "open", "collect", "close"]:
    let command = @[getAppFilename(), "--child", mode, marker]
    let process = startProcess(command[0], args=command[1..^1], options={poParentStreams})
    let native = process.waitForExit()
    process.close()
    let monitored = runMonitored(FsSnoopRequest(command:command,
      depFilePath:work/(mode & ".iomon"), captureChildStdio:true,
      captureStdioPath:work/(mode & ".log")))
    echo "mode=", mode, " native=", toHex(uint32(native)),
      " monitored=", toHex(uint32(monitored.exitCode)), " capture=", monitored.completeness
    echo readFile(work/(mode & ".log"))
    if native != 0 or monitored.exitCode != 0: failed = true
  if failed: quit 1

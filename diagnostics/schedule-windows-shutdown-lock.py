"""Control a real writer-lock schedule in a disposable Windows shim.

No mocks: an actual worker acquires the production registry lock after the
early flush, then Windows terminates it through the original exit path.
The optional guard is the only behavioral difference between the variants.
"""
import sys
from pathlib import Path

writer = Path("io-mon/src/io_mon/writer.nim")
text = writer.read_text()
anchor = "proc registerFragmentSlot() {.raises: [].} =\n"
assert text.count(anchor) == 1
text = text.replace(anchor, '''{.emit: "#include <windows.h>".}
proc diagnosticHoldWriterRegistry(requested, held, ready: pointer)
    {.exportc: "repro_diagnostic_hold_writer_registry", dynlib, cdecl.} =
  ensureRegistryLock()
  # Establish the worker's real DLL/TLS/lock entry before ExitProcess can
  # serialize new thread initialization behind the loader's exit lock.
  acquire(registryLock)
  release(registryLock)
  {.emit: "SetEvent((HANDLE)`ready`); WaitForSingleObject((HANDLE)`requested`, INFINITE);".}
  acquire(registryLock)
  # This explicitly controlled worker is terminated by real ExitProcess.
  {.emit: "SetEvent((HANDLE)`held`); Sleep(INFINITE);".}

''' + anchor)
writer.write_text(text)

shim = Path("io-mon/src/io_mon/shim/windows_interpose.nim")
text = shim.read_text()
anchor = "var terminateFlushDone {.global.}: Atomic[bool]\n"
assert text.count(anchor) == 1
text = text.replace(anchor, '''{.emit: """
#include <windows.h>
static HANDLE diagnostic_exit_request, diagnostic_exit_held, diagnostic_exit_worker;
__declspec(dllexport) void repro_diagnostic_schedule_exit(HANDLE request, HANDLE held, HANDLE worker) {
  diagnostic_exit_request = request;
  diagnostic_exit_held = held;
  diagnostic_exit_worker = worker;
}
static void diagnostic_wait_for_exit_lock(void) {
  if (diagnostic_exit_request) {
    if (!SetEvent(diagnostic_exit_request) ||
        WaitForSingleObject(diagnostic_exit_held, 5000) != WAIT_OBJECT_0)
      TerminateProcess(GetCurrentProcess(),
        WaitForSingleObject(diagnostic_exit_worker, 0) == WAIT_OBJECT_0 ? 82 : 81);
  }
}
""".}
proc diagnosticWaitForExitLock() {.importc: "diagnostic_wait_for_exit_lock",
    nodecl, raises: [].}

''' + anchor)
anchor = "        traceExitPhase(202)\n"
assert text.count(anchor) == 1
text = text.replace(anchor, anchor + "        diagnosticWaitForExitLock()\n")
if "--guard-late-flush" in sys.argv:
    anchor = '''        traceExitPhase(211)
        try:
          flushAllRegisteredSlots()
          traceExitPhase(212)
        except CatchableError, IOError, OSError:
          traceExitPhase(213)
'''
    assert text.count(anchor) == 1
    text = text.replace(anchor, '''        if not terminateFlushDone.exchange(true):
          traceExitPhase(211)
          try:
            flushAllRegisteredSlots()
            traceExitPhase(212)
          except CatchableError, IOError, OSError:
            traceExitPhase(213)
        else:
          traceExitPhase(217)
''')
shim.write_text(text)
print("Applied real shutdown-lock schedule; guarded=" + str("--guard-late-flush" in sys.argv))

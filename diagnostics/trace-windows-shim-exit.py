"""Add volatile shutdown checkpoints to the disposable Windows shim.

No mocks, extra waits, locks, I/O, or altered shutdown behavior. Keep these
separate from initialization phases so a completed init remains observable.
"""
import json
from pathlib import Path

source = Path("io-mon/src/io_mon/shim/windows_interpose.nim")
text = source.read_text()
anchor = "var terminateFlushDone {.global.}: Atomic[bool]\n"
assert text.count(anchor) == 1
text = text.replace(anchor, '''{.emit: """
__declspec(dllexport) volatile unsigned long repro_diagnostic_exit_phase = 0;
""".}
proc traceExitPhase(phase: uint32) {.inline.} =
  {.emit: "repro_diagnostic_exit_phase = `phase`;".}

''' + anchor)


def replace_once(old, new):
    global text
    assert text.count(old) == 1, old
    text = text.replace(old, new)


replace_once(
    "  if isSelf and initialized and not terminateFlushDone.exchange(true):\n"
    "    withShimMuted:\n"
    "      try:\n"
    "        flushAllRegisteredSlots()\n"
    "      except CatchableError, IOError, OSError:\n"
    "        discard\n"
    "  hr.callNext(ctx)\n",
    "  if isSelf and initialized and not terminateFlushDone.exchange(true):\n"
    "    traceExitPhase(201)\n"
    "    withShimMuted:\n"
    "      try:\n"
    "        flushAllRegisteredSlots()\n"
    "        traceExitPhase(202)\n"
    "      except CatchableError, IOError, OSError:\n"
    "        traceExitPhase(203)\n"
    "    traceExitPhase(204)\n"
    "  hr.callNext(ctx)\n",
)
replace_once("      addExitProc(proc() {.noconv.} =\n",
             "      addExitProc(proc() {.noconv.} =\n"
             "        traceExitPhase(210)\n")
replace_once(
    "        try:\n"
    "          flushAllRegisteredSlots()\n"
    "        except CatchableError, IOError, OSError:\n"
    "          discard\n"
    "        when ctInlineHookAvailable:\n"
    "          discard uninstallAllInlineHooks()\n"
    "        installedHookTargets.setLen(0))\n",
    "        traceExitPhase(211)\n"
    "        try:\n"
    "          flushAllRegisteredSlots()\n"
    "          traceExitPhase(212)\n"
    "        except CatchableError, IOError, OSError:\n"
    "          traceExitPhase(213)\n"
    "        when ctInlineHookAvailable:\n"
    "          traceExitPhase(214)\n"
    "          discard uninstallAllInlineHooks()\n"
    "          traceExitPhase(215)\n"
    "        installedHookTargets.setLen(0)\n"
    "        traceExitPhase(216))\n",
)
source.write_text(text)
Path("build/windows-runtime-phases/exit-phases.json").write_text(json.dumps({
    "201": "termination sweep entered with one-shot ownership",
    "202": "termination sweep returned",
    "203": "termination sweep caught an exception",
    "204": "termination hook about to call next hook/original",
    "210": "CRT exit callback entered",
    "211": "CRT exit callback about to sweep",
    "212": "CRT exit sweep returned",
    "213": "CRT exit sweep caught an exception",
    "214": "CRT exit about to uninstall hooks",
    "215": "CRT exit hook uninstall returned",
    "216": "CRT exit callback completed",
}, indent=2))
print("Added volatile shutdown checkpoints to the disposable shim.")

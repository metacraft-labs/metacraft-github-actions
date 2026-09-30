"""Expose only an integer phase in a disposable shim; no initialization I/O.

The parent reads the exported variable only when a borrowed call already
failed. Each checkpoint is a volatile store; deadlines and hook behavior stay
unchanged. The phase map is retained beside the failure evidence.
"""
import json
from pathlib import Path

source = Path('io-mon/src/io_mon/shim/windows_interpose.nim')
text = source.read_text()
anchor = 'proc installAllHooks(): int =\n'
assert text.count(anchor) == 1
text = text.replace(anchor, '''{.emit: """
#include <stdint.h>
__declspec(dllexport) volatile unsigned long repro_diagnostic_init_phase = 0;
__declspec(dllexport) volatile uintptr_t repro_diagnostic_patch_target = 0;
__declspec(dllexport) volatile uintptr_t repro_diagnostic_prepared_target = 0;
__declspec(dllexport) volatile unsigned long repro_diagnostic_frozen_count = 0;
__declspec(dllexport) volatile unsigned long repro_diagnostic_frozen_tids[4096];
""".}
proc traceInitPhase(phase: uint32) {.inline.} =
  {.emit: "repro_diagnostic_init_phase = `phase`;".}

''' + anchor)
phases = {
    1: 'init entered', 2: 'acquire init lock', 3: 'capture configuration',
    4: 'initialize registry', 5: 'register callbacks', 6: 'image bounds',
    7: 'load observed modules', 8: 'record process start',
    9: 'install hooks', 10: 'register DLL notification',
    11: 'enumerate modules', 12: 'flush initial batch',
    13: 'audit hooks', 14: 'pin shim', 15: 'register exit handler',
    16: 'init complete', 20: 'begin hook transaction',
    21: 'queue hook installs', 22: 'commit hook transaction',
    23: 'wire original callbacks', 24: 'log installed hooks',
    25: 'install IAT fallbacks', 26: 'hook install complete',
}

def before(needle, phase):
    global text
    assert text.count(needle) == 1, needle
    indent = needle[:len(needle)-len(needle.lstrip())]
    text = text.replace(needle, indent + f'traceInitPhase({phase})\n' + needle)

before('  dbg("[repro_monitor_shim] repro_monitor_shim_init entered\\n")', 1)
before('  acquire(initLockVar)\n', 2)
before('    fragmentDir = readEnvString("REPRO_MONITOR_FRAGMENT_DIR")', 3)
before('  hr.initShimRegistry()', 4)
before('  registerMonitorSnoopCallbacks()', 5)
before('  initMainImageRange()', 6)
before('    forceLoadObservedModules()', 7)
before('  recordProcessStart()\n', 8)
before('  let iatFallbackCount = installAllHooks()', 9)
before('  registerDllNotification()\n', 10)
before('  emitAlreadyLoadedModules()\n', 11)
# Limit duplicated helper calls to the init export itself.
start = text.index('proc repro_monitor_shim_init*')
prefix, init = text[:start], text[start:]
needle = '      flushFragmentBatch()\n'
assert init.count(needle) == 1
init = init.replace(needle, '      traceInitPhase(12)\n' + needle)
text = prefix + init
before('    var auditModules = initTable[string, HANDLE]()', 13)
before('    let pinProbe = cast[ByteAddress](repro_monitor_shim_init)', 14)
before('      addExitProc(proc() {.noconv.} =', 15)
before('    let beginRc = ctInlineHookBeginTransaction()', 20)
before('    let inTransaction = (beginRc == 0)', 21)
before('      let commitRc = ctInlineHookCommitTransaction()', 22)
before('  var commitEmpty = newSeq[bool](hookTable.len)', 23)
before('  # Post-commit pass 2: emit diagnostic lines.', 24)
before('  for spec in failed:\n', 25)
before('  result = failed.len\n', 26)
# The export ends before the next public proc. Add the final store immediately
# before its return expression, checking the exact source below.
needle = '  result = 0\n\nproc repro_monitor_shim_flush*'
assert text.count(needle) == 1
text = text.replace(needle, '  traceInitPhase(16)\n' + needle)
source.write_text(text)
Path('build/windows-arm-injection/init-phases.json').write_text(
    json.dumps(phases, indent=2))
print('Added volatile initialization checkpoints to the disposable shim.')

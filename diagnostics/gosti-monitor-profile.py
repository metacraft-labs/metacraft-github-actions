"""Add temporary phase timestamps to the actual Windows monitor, preserving LastError.

The caller retains the patch and restores source bytes. This adds diagnostic
stderr only; hook coverage, suspension, waiting, flushing and teardown stay intact.
"""
from pathlib import Path
import sys

shim = Path(sys.argv[1])
source = shim.read_text()


def replace_once(before, after):
    global source
    assert source.count(before) == 1, before
    source = source.replace(before, after)


helper = r'''
{.emit: """
#include <windows.h>
#include <stdio.h>
#include <string.h>
extern void ct_inline_hook_diagnostic_metrics(unsigned long long *, unsigned long long *,
                                              unsigned long long *, unsigned long long *);
static void io_mon_diagnostic_phase(const char *phase) {
  DWORD saved = GetLastError(), written = 0;
  LARGE_INTEGER tick, frequency;
  HMODULE image = NULL;
  char path[4096] = {0}, line[4608];
  QueryPerformanceCounter(&tick);
  QueryPerformanceFrequency(&frequency);
  GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                    GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                    (LPCSTR)&io_mon_diagnostic_phase, &image);
  if (image) GetModuleFileNameA(image, path, sizeof(path));
  int size = snprintf(line, sizeof(line),
      "monitor-profile pid=%lu phase=%s tick=%lld frequency=%lld image=%s\n",
      (unsigned long)GetCurrentProcessId(), phase,
      (long long)tick.QuadPart, (long long)frequency.QuadPart, path);
  if (size > 0 && size < sizeof(line))
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), line, size, &written, NULL);
  if (!strcmp(phase, "install-hooks-end") || !strcmp(phase, "uninstall-hooks-end")) {
    unsigned long long counts[6], ticks[6], clock_frequency, clock_errors;
    const char *names[] = {"protect", "icache", "snapshot", "open-thread", "suspend", "resume"};
    ct_inline_hook_diagnostic_metrics(counts, ticks, &clock_frequency, &clock_errors);
    for (int i = 0; i < 6; ++i) {
      size = snprintf(line, sizeof(line),
          "hook-profile pid=%lu phase=%s api=%s count=%llu ticks=%llu frequency=%llu clock-errors=%llu\n",
          (unsigned long)GetCurrentProcessId(), phase, names[i], counts[i], ticks[i],
          clock_frequency, clock_errors);
      if (size > 0 && size < sizeof(line))
        WriteFile(GetStdHandle(STD_ERROR_HANDLE), line, size, &written, NULL);
    }
  }
  SetLastError(saved);
}
""".}
proc diagnosticPhaseRaw(phase: cstring)
    {.importc: "io_mon_diagnostic_phase", nodecl, raises: [].}
proc diagnosticPhase(phase: cstring) {.raises: [], stackTrace: off.} =
  # Only the diagnostic write is muted; the measured operation stays outside.
  # Preserve the value across Nim's own TLS accesses as well as the C writer.
  let savedDiagnosticError = GetLastError()
  inc disabled
  try:
    diagnosticPhaseRaw(phase)
  finally:
    dec disabled
    SetLastError(savedDiagnosticError)

'''
replace_once('proc dbg(msg: cstring) =', helper + 'proc dbg(msg: cstring) =')
replace_once('  let report = shProp.injectShimIntoChildReport(pi[].hProcess,',
             '  diagnosticPhase("inject-begin")\n  let report = shProp.injectShimIntoChildReport(pi[].hProcess,')
replace_once('    selfDllPath(), "repro_runtime_init", spawnInjectionConfig, hThread)',
             '    selfDllPath(), "repro_runtime_init", spawnInjectionConfig, hThread)\n  diagnosticPhase("inject-end")')
start = source.index('proc snoopCreateProcessW(')
end = source.index('\nproc ', start + 1)
part = source[start:end]
assert part.count('  hr.callNext(ctx)') == 1
part = part.replace('  hr.callNext(ctx)',
                    '  diagnosticPhase("create-process-begin")\n  hr.callNext(ctx)\n  diagnosticPhase("create-process-end")')
part = part.replace('        childForkRuntime =\n', '        diagnosticPhase("fork-runtime-begin")\n        childForkRuntime =\n')
part = part.replace('          shProp.windowsForkRuntimeForProcess(lpProcessInfo[].hProcess)',
                    '          shProp.windowsForkRuntimeForProcess(lpProcessInfo[].hProcess)\n        diagnosticPhase("fork-runtime-end")')
source = source[:start] + part + source[end:]
replace_once('  dbg("[repro_monitor_shim] repro_monitor_shim_init entered\\n")',
             '  diagnosticPhase("init-begin")\n  dbg("[repro_monitor_shim] repro_monitor_shim_init entered\\n")')
replace_once('  let iatFallbackCount = installAllHooks()',
             '  diagnosticPhase("install-hooks-begin")\n  let iatFallbackCount = installAllHooks()\n  diagnosticPhase("install-hooks-end")')
replace_once('  dbg("[repro_monitor_shim] initialization complete\\n")',
             '  diagnosticPhase("init-complete")\n  dbg("[repro_monitor_shim] initialization complete\\n")')
for indent in ('        ', '          '):
    before = '\n' + indent + 'flushAllRegisteredSlots()\n'
    replace_once(before, '\n' + indent + 'diagnosticPhase("flush-begin")' + before +
                 indent + 'diagnosticPhase("flush-end")\n')
replace_once('          discard uninstallAllInlineHooks()',
             '          diagnosticPhase("uninstall-hooks-begin")\n          discard uninstallAllInlineHooks()\n          diagnosticPhase("uninstall-hooks-end")')
shim.write_text(source)

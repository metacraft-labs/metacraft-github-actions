"""Time real Windows hook-backend API calls without logging while peers freeze.

Only the caller's separately muted phase reporter reads these counters. Each
wrapper preserves LastError, invokes the real API once and returns its result.
No allocation, I/O, changed patching, suspension or cache flushing is introduced.
"""
from pathlib import Path
import sys

source = Path(sys.argv[1])
text = source.read_text()
anchor = "#include <tlhelp32.h>\n"
assert text.count(anchor) == 1
apis = [
    ("BOOL", "VirtualProtect", "LPVOID address, SIZE_T size, DWORD protection, PDWORD old", "address, size, protection, old"),
    ("BOOL", "FlushInstructionCache", "HANDLE process, LPCVOID address, SIZE_T size", "process, address, size"),
    ("HANDLE", "CreateToolhelp32Snapshot", "DWORD flags, DWORD process", "flags, process"),
    ("HANDLE", "OpenThread", "DWORD access, BOOL inherit, DWORD thread", "access, inherit, thread"),
    ("DWORD", "SuspendThread", "HANDLE thread", "thread"),
    ("DWORD", "ResumeThread", "HANDLE thread", "thread"),
]
helper = """
static unsigned long long ct_diagnostic_counts[6], ct_diagnostic_ticks[6];
static unsigned long long ct_diagnostic_frequency, ct_diagnostic_clock_errors;
typedef LONG (NTAPI *ct_diagnostic_clock_proc)(LARGE_INTEGER *, LARGE_INTEGER *);
static ct_diagnostic_clock_proc ct_diagnostic_clock;
/* Diagnostic only: the public QPC entry itself is patched during this batch.
 * Resolve the unhooked native counter before the first preparation call. Its
 * returned frequency grades the measurements; absent/failed clocks invalidate
 * the diagnostic explicitly. No native-API dependency ships in the product.
 * https://learn.microsoft.com/en-us/windows/win32/devnotes/ntqueryperformancecounter */
static LONGLONG ct_diagnostic_tick(void) {
    LARGE_INTEGER tick = {0}, frequency = {0};
    if (ct_diagnostic_clock == NULL) {
        FARPROC raw = GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQueryPerformanceCounter");
        FARPROC hooked = GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "QueryPerformanceCounter");
        if (raw != hooked) ct_diagnostic_clock = (ct_diagnostic_clock_proc)raw;
    }
    if (ct_diagnostic_clock == NULL ||
        ct_diagnostic_clock(&tick, &frequency) != 0 || frequency.QuadPart <= 0) {
        ct_diagnostic_clock_errors++;
        return 0;
    }
    ct_diagnostic_frequency = (unsigned long long)frequency.QuadPart;
    return tick.QuadPart;
}
void ct_inline_hook_diagnostic_metrics(unsigned long long *counts,
                                      unsigned long long *ticks,
                                      unsigned long long *frequency,
                                      unsigned long long *errors) {
    for (int i = 0; i < 6; ++i) {
        counts[i] = ct_diagnostic_counts[i];
        ticks[i] = ct_diagnostic_ticks[i];
    }
    *frequency = ct_diagnostic_frequency;
    *errors = ct_diagnostic_clock_errors;
}
"""
for index, (result, name, params, args) in enumerate(apis):
    helper += f"""
static {result} ct_diagnostic_{name}({params}) {{
    DWORD saved = GetLastError();
    LONGLONG begin = ct_diagnostic_tick();
    SetLastError(saved);
    {result} result = {name}({args});
    DWORD returned = GetLastError();
    LONGLONG end = ct_diagnostic_tick();
    ct_diagnostic_counts[{index}]++;
    if (end >= begin) ct_diagnostic_ticks[{index}] += (unsigned long long)(end - begin);
    else ct_diagnostic_clock_errors++;
    SetLastError(returned);
    return result;
}}
#define {name} ct_diagnostic_{name}
"""
source.write_text(text.replace(anchor, anchor + helper))

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
void ct_inline_hook_diagnostic_metrics(unsigned long long *counts,
                                      unsigned long long *ticks) {
    for (int i = 0; i < 6; ++i) {
        counts[i] = ct_diagnostic_counts[i];
        ticks[i] = ct_diagnostic_ticks[i];
    }
}
"""
for index, (result, name, params, args) in enumerate(apis):
    helper += f"""
static {result} ct_diagnostic_{name}({params}) {{
    DWORD saved = GetLastError();
    LARGE_INTEGER begin, end;
    QueryPerformanceCounter(&begin);
    SetLastError(saved);
    {result} result = {name}({args});
    DWORD returned = GetLastError();
    QueryPerformanceCounter(&end);
    ct_diagnostic_counts[{index}]++;
    ct_diagnostic_ticks[{index}] += (unsigned long long)(end.QuadPart - begin.QuadPart);
    SetLastError(returned);
    return result;
}}
#define {name} ct_diagnostic_{name}
"""
source.write_text(text.replace(anchor, anchor + helper))

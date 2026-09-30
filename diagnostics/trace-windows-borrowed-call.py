"""Add failure-only register/module evidence to a disposable bootstrap source."""
from pathlib import Path

source = Path('nim-stackable-hooks/src/stackable_hooks/windows_entry_park.nim')
text = source.read_text()
anchor = '  proc poisonChild(park: var EntryPark; hThread: pointer) =\n'
assert text.count(anchor) == 1
helper = r'''
  {.emit: """
#include <windows.h>
#include <stdio.h>
static void trace_park_address(HANDLE process, const char *label, void *address) {
  MEMORY_BASIC_INFORMATION memory;
  char path[1024] = {0};
  typedef DWORD (WINAPI *NameFn)(HANDLE, HMODULE, LPSTR, DWORD);
  NameFn name = (NameFn)GetProcAddress(GetModuleHandleA("kernel32.dll"),
                                      "K32GetModuleFileNameExA");
  if (VirtualQueryEx(process, address, &memory, sizeof(memory))) {
    if (name) name(process, (HMODULE)memory.AllocationBase, path, sizeof(path));
    fprintf(stderr, " PARK-TRACE %s=%p module=%s base=%p offset=%llx protect=%lx\n",
            label, address, path, memory.AllocationBase,
            (unsigned long long)((char*)address-(char*)memory.AllocationBase),
            (unsigned long)memory.Protect);
  } else {
    fprintf(stderr, " PARK-TRACE %s=%p query-error=%lu\n", label, address,
            (unsigned long)GetLastError());
  }
}
static void trace_park_failure(void *process, void *thread, void *entry, void *fn) {
  DWORD originalError = GetLastError();
  CONTEXT context __attribute__((aligned(16))) = {0};
  context.ContextFlags = CONTEXT_FULL;
  BOOL got = GetThreadContext(thread, &context);
  fprintf(stderr, "PARK-TRACE parent=%lu child=%lu thread=%lu context=%d error=%lu prior-error=%lu\n",
          (unsigned long)GetCurrentProcessId(), (unsigned long)GetProcessId(process),
          (unsigned long)GetThreadId(thread), got, (unsigned long)GetLastError(),
          (unsigned long)originalError);
  trace_park_address(process, "entry", entry);
  trace_park_address(process, "borrowed-function", fn);
  if (got) {
    trace_park_address(process, "rip", (void*)context.Rip);
    fprintf(stderr, " PARK-TRACE rsp=%llx rax=%llx rcx=%llx\n",
            (unsigned long long)context.Rsp, (unsigned long long)context.Rax,
            (unsigned long long)context.Rcx);
  }
  unsigned char bytes[16] = {0}; SIZE_T count = 0;
  if (ReadProcessMemory(process, entry, bytes, sizeof(bytes), &count)) {
    fprintf(stderr, " PARK-TRACE entry-bytes=");
    for (SIZE_T i=0; i<count; ++i) fprintf(stderr, "%02x", bytes[i]);
    fprintf(stderr, "\n");
  }
  fflush(stderr);
  SetLastError(originalError);
}
""".}
  proc traceParkFailure(process, thread, entry, fn: pointer)
    {.cdecl, importc: "trace_park_failure", nodecl.}

'''
text = text.replace(anchor, helper + anchor)
needle = '        poisonChild(park, hThread)\n'
assert text.count(needle) == 3
text = text.replace(needle, '        traceParkFailure(park.hProcess, hThread, park.entry, fn)\n' + needle)
source.write_text(text)
print('Instrumented only the three already-fatal borrowed-call paths; deadlines unchanged.')

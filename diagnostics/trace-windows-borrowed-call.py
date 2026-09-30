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
#include <string.h>
static void trace_init_phase(HANDLE process, void *fn) {
  MEMORY_BASIC_INFORMATION memory;
  IMAGE_DOS_HEADER dos; IMAGE_NT_HEADERS64 nt; IMAGE_EXPORT_DIRECTORY exports;
  SIZE_T count;
  if (!VirtualQueryEx(process, fn, &memory, sizeof(memory))) return;
  char *base = (char*)memory.AllocationBase;
  if (!ReadProcessMemory(process, base, &dos, sizeof(dos), &count) ||
      dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew < 0 || dos.e_lfanew > 1048576) return;
  if (!ReadProcessMemory(process, base + dos.e_lfanew, &nt, sizeof(nt), &count) ||
      nt.Signature != IMAGE_NT_SIGNATURE ||
      nt.OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) return;
  DWORD rva = nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress;
  if (!rva || !ReadProcessMemory(process, base + rva, &exports, sizeof(exports), &count) ||
      exports.NumberOfNames > 65536) return;
  for (DWORD i = 0; i < exports.NumberOfNames; ++i) {
    DWORD nameRva = 0, valueRva = 0; WORD ordinal = 0; char name[64] = {0};
    if (!ReadProcessMemory(process, base + exports.AddressOfNames + i * 4,
                           &nameRva, sizeof(nameRva), &count) ||
        !ReadProcessMemory(process, base + nameRva, name, sizeof(name)-1, &count)) continue;
    if (strcmp(name, "repro_diagnostic_init_phase")) continue;
    if (!ReadProcessMemory(process, base + exports.AddressOfNameOrdinals + i * 2,
                           &ordinal, sizeof(ordinal), &count) || ordinal >= exports.NumberOfFunctions ||
        !ReadProcessMemory(process, base + exports.AddressOfFunctions + ordinal * 4,
                           &valueRva, sizeof(valueRva), &count)) return;
    DWORD phase = 0;
    if (ReadProcessMemory(process, base + valueRva, &phase, sizeof(phase), &count))
      fprintf(stderr, " PARK-TRACE init-phase=%lu\n", (unsigned long)phase);
    return;
  }
}
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
static void trace_park_failure(void *process, void *thread, void *entry, void *fn,
                               unsigned int reason) {
  DWORD originalError = GetLastError();
  CONTEXT context __attribute__((aligned(16))) = {0};
  context.ContextFlags = CONTEXT_FULL;
  BOOL got = GetThreadContext(thread, &context);
  fprintf(stderr, "PARK-TRACE parent=%lu child=%lu thread=%lu context=%d error=%lu prior-error=%lu reason=%u\n",
          (unsigned long)GetCurrentProcessId(), (unsigned long)GetProcessId(process),
          (unsigned long)GetThreadId(thread), got, (unsigned long)GetLastError(),
          (unsigned long)originalError, reason);
  trace_park_address(process, "entry", entry);
  trace_park_address(process, "borrowed-function", fn);
  trace_init_phase(process, fn);
  if (got) {
    trace_park_address(process, "rip", (void*)context.Rip);
    fprintf(stderr, " PARK-TRACE rsp=%llx rax=%llx rcx=%llx\n",
            (unsigned long long)context.Rsp, (unsigned long long)context.Rax,
            (unsigned long long)context.Rcx);
    /* These are executable-image candidates, NOT an unwound stack. Never
       print raw stack data: retain only mapped code addresses and offsets. */
    unsigned long long words[256] = {0}; SIZE_T read = 0;
    if (ReadProcessMemory(process, (void*)context.Rsp, words, sizeof(words), &read)) {
      unsigned int emitted = 0;
      for (SIZE_T i = 0; i < read / sizeof(words[0]) && emitted < 24; ++i) {
        MEMORY_BASIC_INFORMATION code;
        void *address = (void*)words[i];
        if (VirtualQueryEx(process, address, &code, sizeof(code)) &&
            code.State == MEM_COMMIT && code.Type == MEM_IMAGE &&
            (code.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                             PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) {
          fprintf(stderr, " PARK-TRACE code-candidate-stack-offset=%llu\n",
                  (unsigned long long)(i * sizeof(words[0])));
          trace_park_address(process, "code-candidate", address);
          ++emitted;
        }
      }
    }
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
  proc traceParkFailure(process, thread, entry, fn: pointer; reason: cuint)
    {.cdecl, importc: "trace_park_failure", nodecl.}

'''
text = text.replace(anchor, helper + anchor)
needle = '        poisonChild(park, hThread)\n'
assert text.count(needle) == 3
# 1: failed resume and restore; 2: hard deadline; 3: failed final restore.
parts = text.split(needle)
text = parts[0]
for reason, part in enumerate(parts[1:], 1):
    text += ('        traceParkFailure(park.hProcess, hThread, park.entry, fn, '
             + str(reason) + "'u32)\n" + needle + part)
source.write_text(text)
print('Instrumented only the three already-fatal borrowed-call paths; deadlines unchanged.')

"""Add failure-only register/module evidence to a disposable bootstrap source."""
from pathlib import Path

source = Path('nim-stackable-hooks/src/stackable_hooks/windows_entry_park.nim')
text = source.read_text()
anchor = '  proc poisonChild(park: var EntryPark; hThread: pointer) =\n'
assert text.count(anchor) == 1
helper = r'''
  {.emit: """
#include <windows.h>
#include <dbghelp.h>
#include <stdio.h>
#include <string.h>
static void trace_park_address(HANDLE process, const char *label, void *address);
static void *trace_export_address(HANDLE process, void *fn, const char *wanted) {
  MEMORY_BASIC_INFORMATION memory;
  IMAGE_DOS_HEADER dos; IMAGE_NT_HEADERS64 nt; IMAGE_EXPORT_DIRECTORY exports;
  SIZE_T count;
  if (!VirtualQueryEx(process, fn, &memory, sizeof(memory))) return NULL;
  char *base = (char*)memory.AllocationBase;
  if (!ReadProcessMemory(process, base, &dos, sizeof(dos), &count) ||
      dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew < 0 || dos.e_lfanew > 1048576) return NULL;
  if (!ReadProcessMemory(process, base + dos.e_lfanew, &nt, sizeof(nt), &count) ||
      nt.Signature != IMAGE_NT_SIGNATURE ||
      nt.OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) return NULL;
  DWORD rva = nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress;
  if (!rva || !ReadProcessMemory(process, base + rva, &exports, sizeof(exports), &count) ||
      exports.NumberOfNames > 65536) return NULL;
  for (DWORD i = 0; i < exports.NumberOfNames; ++i) {
    DWORD nameRva = 0, valueRva = 0; WORD ordinal = 0; char name[64] = {0};
    if (!ReadProcessMemory(process, base + exports.AddressOfNames + i * 4,
                           &nameRva, sizeof(nameRva), &count) ||
        !ReadProcessMemory(process, base + nameRva, name, sizeof(name)-1, &count)) continue;
    if (strcmp(name, wanted)) continue;
    if (!ReadProcessMemory(process, base + exports.AddressOfNameOrdinals + i * 2,
                           &ordinal, sizeof(ordinal), &count) || ordinal >= exports.NumberOfFunctions ||
        !ReadProcessMemory(process, base + exports.AddressOfFunctions + ordinal * 4,
                           &valueRva, sizeof(valueRva), &count)) return NULL;
    return base + valueRva;
  }
  return NULL;
}
static void trace_init_phase(HANDLE process, void *fn) {
  SIZE_T got;
  void *symbol = trace_export_address(process, fn, "repro_diagnostic_init_phase");
  DWORD phase = 0;
  if (symbol && ReadProcessMemory(process, symbol, &phase, sizeof(phase), &got))
    fprintf(stderr, " PARK-TRACE init-phase=%lu\n", (unsigned long)phase);
  symbol = trace_export_address(process, fn, "repro_diagnostic_patch_target");
  void *target = NULL;
  if (symbol && ReadProcessMemory(process, symbol, &target, sizeof(target), &got))
    trace_park_address(process, "patch-target", target);
  symbol = trace_export_address(process, fn, "repro_diagnostic_prepared_target");
  void *prepared = NULL;
  if (symbol && ReadProcessMemory(process, symbol, &prepared, sizeof(prepared), &got) && prepared)
    trace_park_address(process, "prepared-target", prepared);
  symbol = trace_export_address(process, fn, "repro_diagnostic_frozen_count");
  DWORD count = 0;
  if (!symbol || !ReadProcessMemory(process, symbol, &count, sizeof(count), &got)) return;
  fprintf(stderr, " PARK-TRACE frozen-count=%lu\n", (unsigned long)count);
  if (count > 64) count = 64;
  DWORD ids[64] = {0};
  symbol = trace_export_address(process, fn, "repro_diagnostic_frozen_tids");
  if (!symbol || !ReadProcessMemory(process, symbol, ids, count * sizeof(DWORD), &got)) return;
  for (DWORD i = 0; i < count; i++) {
    HANDLE thread = OpenThread(THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, ids[i]);
    CONTEXT context __attribute__((aligned(16))) = {0};
    context.ContextFlags = CONTEXT_FULL;
    BOOL ok = thread && GetThreadContext(thread, &context);
    fprintf(stderr, " PARK-TRACE frozen-thread=%lu context=%d error=%lu\n",
            (unsigned long)ids[i], ok, (unsigned long)GetLastError());
    if (ok) trace_park_address(process, "frozen-rip", (void*)context.Rip);
    if (thread) CloseHandle(thread);
  }
}
static void trace_nearest_export(HANDLE process, void *base, void *address) {
  IMAGE_DOS_HEADER dos; IMAGE_NT_HEADERS64 nt; IMAGE_EXPORT_DIRECTORY exports;
  SIZE_T got;
  char *image = (char*)base;
  if (!ReadProcessMemory(process, image, &dos, sizeof(dos), &got) ||
      dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew < 0 || dos.e_lfanew > 1048576) return;
  if (!ReadProcessMemory(process, image + dos.e_lfanew, &nt, sizeof(nt), &got) ||
      nt.Signature != IMAGE_NT_SIGNATURE || nt.OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) return;
  DWORD rva = nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress;
  if (!rva || !ReadProcessMemory(process, image + rva, &exports, sizeof(exports), &got) ||
      exports.NumberOfNames > 65536 || exports.NumberOfFunctions > 65536) return;
  DWORD offset = (DWORD)((char*)address - image), closest = 0, best = 0xffffffff;
  for (DWORD i = 0; i < exports.NumberOfFunctions; i++) {
    DWORD functionRva = 0;
    if (ReadProcessMemory(process, image + exports.AddressOfFunctions + i * 4,
                           &functionRva, sizeof(functionRva), &got) &&
        functionRva && functionRva <= offset && functionRva >= closest) {
      closest = functionRva; best = i;
    }
  }
  if (best == 0xffffffff) return;
  for (DWORD i = 0; i < exports.NumberOfNames; i++) {
    WORD ordinal; DWORD nameRva; char name[128] = {0};
    if (!ReadProcessMemory(process, image + exports.AddressOfNameOrdinals + i * 2,
                           &ordinal, sizeof(ordinal), &got) || ordinal != best) continue;
    if (ReadProcessMemory(process, image + exports.AddressOfNames + i * 4,
                          &nameRva, sizeof(nameRva), &got) &&
        ReadProcessMemory(process, image + nameRva, name, sizeof(name)-1, &got))
      fprintf(stderr, " PARK-TRACE nearest-export=%s offset=%lx\n", name,
              (unsigned long)(offset - closest));
    break;
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
    if (memory.Type == MEM_IMAGE) trace_nearest_export(process, memory.AllocationBase, address);
  } else {
    fprintf(stderr, " PARK-TRACE %s=%p query-error=%lu\n", label, address,
            (unsigned long)GetLastError());
  }
}
static void trace_unwind(HANDLE process, HANDLE thread, CONTEXT context) {
  /* Runtime unwind records only: do not dump memory, arguments, credentials,
     environment blocks or raw stack contents into public CI artifacts. */
  HMODULE helper = LoadLibraryA("dbghelp.dll");
  if (!helper) return;
  typedef BOOL (WINAPI *InitFn)(HANDLE, PCSTR, BOOL);
  typedef BOOL (WINAPI *CleanupFn)(HANDLE);
  typedef BOOL (WINAPI *WalkFn)(DWORD, HANDLE, HANDLE, LPSTACKFRAME64, PVOID,
      PREAD_PROCESS_MEMORY_ROUTINE64, PFUNCTION_TABLE_ACCESS_ROUTINE64,
      PGET_MODULE_BASE_ROUTINE64, PTRANSLATE_ADDRESS_ROUTINE64);
  InitFn init = (InitFn)GetProcAddress(helper, "SymInitialize");
  CleanupFn cleanup = (CleanupFn)GetProcAddress(helper, "SymCleanup");
  WalkFn walk = (WalkFn)GetProcAddress(helper, "StackWalk64");
  PFUNCTION_TABLE_ACCESS_ROUTINE64 functions = (PFUNCTION_TABLE_ACCESS_ROUTINE64)GetProcAddress(helper, "SymFunctionTableAccess64");
  PGET_MODULE_BASE_ROUTINE64 modules = (PGET_MODULE_BASE_ROUTINE64)GetProcAddress(helper, "SymGetModuleBase64");
  if (init && cleanup && walk && functions && modules && init(process, "", TRUE)) {
    STACKFRAME64 frame = {0};
    frame.AddrPC.Offset = context.Rip;
    frame.AddrPC.Mode = AddrModeFlat;
    frame.AddrStack.Offset = context.Rsp;
    frame.AddrStack.Mode = AddrModeFlat;
    frame.AddrFrame.Offset = context.Rbp;
    frame.AddrFrame.Mode = AddrModeFlat;
    DWORD64 previous = 0;
    for (unsigned i = 0; i < 32; i++) {
      if (!walk(IMAGE_FILE_MACHINE_AMD64, process, thread, &frame, &context,
                NULL, functions, modules, NULL) || !frame.AddrPC.Offset || frame.AddrPC.Offset == previous) break;
      previous = frame.AddrPC.Offset;
      fprintf(stderr, " PARK-TRACE unwind-frame=%u\n", i);
      trace_park_address(process, "unwind-rip", (void*)frame.AddrPC.Offset);
    }
    cleanup(process);
  }
  FreeLibrary(helper);
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
    trace_unwind(process, thread, context);
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

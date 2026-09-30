/* Disposable observations of real Windows processes; no mocks.
 * Only QUERY_INFORMATION and VM_READ are requested for observed targets.
 * No target threads are suspended and no target code is executed.
 * The separate --control mode owns and reaps its explicitly created child.
 */
#include <windows.h>
#include <tlhelp32.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

__declspec(dllexport) volatile unsigned long repro_diagnostic_init_phase = 321;
static PROCESSENTRY32 processes[4096];
static DWORD selected[64];
static unsigned long long selected_birth[64];

static unsigned long long ticks(FILETIME time) {
    return ((unsigned long long)time.dwHighDateTime << 32) | time.dwLowDateTime;
}

static unsigned long long birth(HANDLE process) {
    FILETIME c, e, k, u;
    return GetProcessTimes(process, &c, &e, &k, &u) ? ticks(c) : 0;
}

static void *export_address(HANDLE process, char *base, const char *wanted) {
    IMAGE_DOS_HEADER dos;
    IMAGE_NT_HEADERS64 nt;
    IMAGE_EXPORT_DIRECTORY exports;
    SIZE_T count;
    if (!ReadProcessMemory(process, base, &dos, sizeof(dos), &count) ||
        dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew < 0 ||
        dos.e_lfanew > 1048576) return NULL;
    if (!ReadProcessMemory(process, base + dos.e_lfanew, &nt, sizeof(nt), &count) ||
        nt.Signature != IMAGE_NT_SIGNATURE ||
        nt.OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) return NULL;
    DWORD rva = nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress;
    if (!rva || !ReadProcessMemory(process, base + rva, &exports, sizeof(exports), &count) ||
        exports.NumberOfNames > 65536 || exports.NumberOfFunctions > 65536) return NULL;
    for (DWORD i = 0; i < exports.NumberOfNames; ++i) {
        DWORD name_rva = 0, value_rva = 0;
        WORD ordinal = 0;
        char name[80] = {0};
        if (!ReadProcessMemory(process, base + exports.AddressOfNames + i * 4,
                               &name_rva, sizeof(name_rva), &count) ||
            !ReadProcessMemory(process, base + name_rva, name, sizeof(name)-1, &count) ||
            strcmp(name, wanted)) continue;
        if (!ReadProcessMemory(process, base + exports.AddressOfNameOrdinals + i * 2,
                               &ordinal, sizeof(ordinal), &count) ||
            ordinal >= exports.NumberOfFunctions ||
            !ReadProcessMemory(process, base + exports.AddressOfFunctions + ordinal * 4,
                               &value_rva, sizeof(value_rva), &count)) return NULL;
        return base + value_rva;
    }
    return NULL;
}

static unsigned observe_process(DWORD pid, unsigned long long earliest) {
    HANDLE process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, pid);
    if (!process) {
        printf("PHASE-STATE pid=%lu open-error=%lu\n", pid, GetLastError());
        return 0;
    }
    FILETIME c, e, k, u;
    if (!GetProcessTimes(process, &c, &e, &k, &u) || ticks(c) < earliest) {
        printf("PHASE-STATE pid=%lu rejected-creation-time\n", pid);
        CloseHandle(process);
        return 0;
    }
    DWORD exit_code = 0;
    GetExitCodeProcess(process, &exit_code);
    printf("PHASE-STATE pid=%lu creation=%llu kernel_100ns=%llu user_100ns=%llu exit=%lu\n",
           pid, ticks(c), ticks(k), ticks(u), exit_code);
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
    unsigned control_seen = 0, found = 0;
    if (snapshot != INVALID_HANDLE_VALUE) {
        MODULEENTRY32 module = {0};
        module.dwSize = sizeof(module);
        unsigned count = 0;
        if (Module32First(snapshot, &module)) do {
            if (++count > 512) break;
            if (_stricmp(module.szModule, "librepro_monitor_shim.dll") &&
                _stricmp(module.szModule, "windows-process-phase.exe")) continue;
            void *symbol = export_address(process, (char *)module.modBaseAddr,
                                          "repro_diagnostic_init_phase");
            DWORD phase = 0;
            SIZE_T got;
            if (!symbol || !ReadProcessMemory(process, symbol, &phase, sizeof(phase), &got)) continue;
            ++found;
            if (phase == 321) ++control_seen;
            printf("PHASE-STATE pid=%lu module=%s phase=%lu\n", pid, module.szModule, phase);
            const char *names[] = {"repro_diagnostic_frozen_count", "repro_diagnostic_prepared_count"};
            for (unsigned i = 0; i < 2; ++i) {
                DWORD value = 0;
                symbol = export_address(process, (char *)module.modBaseAddr, names[i]);
                if (symbol && ReadProcessMemory(process, symbol, &value, sizeof(value), &got))
                    printf("PHASE-STATE pid=%lu last_%s=%lu\n", pid, names[i], value);
            }
            uintptr_t target = 0;
            symbol = export_address(process, (char *)module.modBaseAddr,
                                    "repro_diagnostic_patch_target");
            MEMORY_BASIC_INFORMATION memory;
            if (symbol && ReadProcessMemory(process, symbol, &target, sizeof(target), &got) &&
                target && VirtualQueryEx(process, (void *)target, &memory, sizeof(memory)))
                printf("PHASE-STATE pid=%lu target=%llx base=%llx offset=%llx protect=%lx\n",
                       pid, (unsigned long long)target,
                       (unsigned long long)(uintptr_t)memory.AllocationBase,
                       (unsigned long long)(target - (uintptr_t)memory.AllocationBase), memory.Protect);
        } while (Module32Next(snapshot, &module));
        CloseHandle(snapshot);
    } else {
        printf("PHASE-STATE pid=%lu module-snapshot-error=%lu\n", pid, GetLastError());
    }
    if (!found) printf("PHASE-STATE pid=%lu no-readable-phase-export\n", pid);
    CloseHandle(process);
    return control_seen;
}

static int tree(DWORD root, unsigned long long expected) {
    HANDLE process = OpenProcess(PROCESS_QUERY_INFORMATION, FALSE, root);
    if (!process) return 2;
    unsigned long long created = birth(process);
    CloseHandle(process);
    if (!created || created != expected) return 3;
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return 4;
    PROCESSENTRY32 entry = {0};
    entry.dwSize = sizeof(entry);
    unsigned count = 0, size = 1;
    selected[0] = root;
    selected_birth[0] = created;
    if (Process32First(snapshot, &entry)) do {
        if (count == 4096) break;
        processes[count++] = entry;
    } while (Process32Next(snapshot, &entry));
    CloseHandle(snapshot);
    for (unsigned at = 0; at < size && size < 64; ++at) {
        for (unsigned i = 0; i < count && size < 64; ++i) {
            if (processes[i].th32ParentProcessID != selected[at]) continue;
            DWORD pid = processes[i].th32ProcessID;
            unsigned j = 0;
            while (j < size && selected[j] != pid) ++j;
            if (j == size) {
                HANDLE candidate = OpenProcess(PROCESS_QUERY_INFORMATION, FALSE, pid);
                if (!candidate) continue;
                unsigned long long candidate_birth = birth(candidate);
                CloseHandle(candidate);
                if (!candidate_birth || candidate_birth < selected_birth[at]) continue;
                selected_birth[size] = candidate_birth;
                selected[size++] = pid;
            }
        }
    }
    printf("PHASE-STATE tree-root=%lu creation=%llu members=%u capped=%d\n",
           root, created, size, size == 64);
    for (unsigned i = 0; i < size; ++i) observe_process(selected[i], created);
    return 0;
}

static int control(int wrong_phase) {
    char self[MAX_PATH], command[2 * MAX_PATH], event_name[80];
    if (!GetModuleFileNameA(NULL, self, sizeof(self))) return 10;
    snprintf(event_name, sizeof(event_name), "Local\\rq-phase-control-%lu", GetCurrentProcessId());
    HANDLE ready = CreateEventA(NULL, TRUE, FALSE, event_name);
    if (!ready) return 11;
    snprintf(command, sizeof(command), "\"%s\" %s %s", self,
             wrong_phase ? "--control-child-negative" : "--control-child", event_name);
    STARTUPINFOA startup = {0};
    PROCESS_INFORMATION child = {0};
    startup.cb = sizeof(startup);
    if (!CreateProcessA(NULL, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &child)) {
        CloseHandle(ready);
        return 12;
    }
    int result = 13;
    if (WaitForSingleObject(ready, 10000) == WAIT_OBJECT_0) {
        unsigned seen = observe_process(child.dwProcessId, birth(child.hProcess));
        if (seen == 1 && WaitForSingleObject(child.hProcess, 0) == WAIT_TIMEOUT &&
            tree(child.dwProcessId, birth(child.hProcess)) == 0 &&
            WaitForSingleObject(child.hProcess, 0) == WAIT_TIMEOUT) result = 0;
    }
    /* Control-only cleanup; the observation paths above never terminate. */
    TerminateProcess(child.hProcess, 17);
    WaitForSingleObject(child.hProcess, 10000);
    DWORD code = 0;
    if (!GetExitCodeProcess(child.hProcess, &code) || code != 17) result = 14;
    CloseHandle(child.hThread);
    CloseHandle(child.hProcess);
    CloseHandle(ready);
    printf("PHASE-STATE control-result=%d child-exit=%lu\n", result, code);
    return result;
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--control")) return control(0);
    if (argc == 2 && !strcmp(argv[1], "--control-negative")) return control(1);
    if (argc == 3 && (!strcmp(argv[1], "--control-child") ||
                      !strcmp(argv[1], "--control-child-negative"))) {
        if (!strcmp(argv[1], "--control-child-negative")) repro_diagnostic_init_phase = 322;
        HANDLE ready = OpenEventA(EVENT_MODIFY_STATE, FALSE, argv[2]);
        if (!ready || !SetEvent(ready)) return 20;
        CloseHandle(ready);
        Sleep(20000);
        return 21;
    }
    if (argc == 3 && !strcmp(argv[1], "--creation")) {
        HANDLE process = OpenProcess(PROCESS_QUERY_INFORMATION, FALSE, strtoul(argv[2], NULL, 10));
        if (!process) return 2;
        unsigned long long created = birth(process);
        CloseHandle(process);
        printf("%llu\n", created);
        return created ? 0 : 3;
    }
    if (argc == 4 && !strcmp(argv[1], "--tree"))
        return tree(strtoul(argv[2], NULL, 10), strtoull(argv[3], NULL, 10));
    return 64;
}

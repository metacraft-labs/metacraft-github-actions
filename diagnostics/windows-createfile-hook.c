/* Exercise the real pinned hook installer and Windows CreateFileW; no mocks.
 * A fresh child compares ordinary installation with an initial protection
 * transition while peers are active. Patch writes still use the production
 * suspend/commit/uninstall paths. The parent retains progress on a timeout. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "install_windows.h"

volatile long *repro_hook_probe_state;
static volatile LONG calls;
static void *original;
typedef HANDLE (WINAPI *CreateFileFn)(LPCWSTR, DWORD, DWORD,
    LPSECURITY_ATTRIBUTES, DWORD, DWORD, HANDLE);

static HANDLE WINAPI observed_create_file(LPCWSTR path, DWORD access,
    DWORD sharing, LPSECURITY_ATTRIBUTES security, DWORD disposition,
    DWORD flags, HANDLE templateFile) {
    InterlockedIncrement(&calls);
    return ((CreateFileFn)original)(path, access, sharing, security,
                                   disposition, flags, templateFile);
}

int main(int argc, char **argv) {
    if (argc != 2 && argc != 3) return 2;
    const int fullShim = argc == 3;
    const int prepared = strcmp(argv[1], "prepared") == 0;
    if (!prepared && strcmp(argv[1], "original")) return 2;
    char mappingName[96];
    snprintf(mappingName, sizeof(mappingName), "Local\\ReproHookProbe-%lu",
             (unsigned long)GetCurrentProcessId());
    HANDLE mapping = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL,
        PAGE_READWRITE, 0, 16, mappingName);
    if (!mapping) return 3;
    repro_hook_probe_state = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0,
                                         16);
    if (!repro_hook_probe_state) return 4;
    const wchar_t *modules[] = {L"ws2_32.dll", L"bcrypt.dll", L"advapi32.dll",
        L"bcryptprimitives.dll", L"ucrtbase.dll", L"msvcrt.dll"};
    for (unsigned i = 0; i < sizeof(modules) / sizeof(modules[0]); i++)
        if (!LoadLibraryW(modules[i])) return 5;
    void *target = (void *)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "CreateFileW");
    if (!target) return 6;
    HMODULE shim = NULL;
    if (fullShim) {
        repro_hook_probe_state[0] = 10;
        shim = LoadLibraryA(argv[2]);
        if (!shim) { printf("shim-load-error=%lu\n", (unsigned long)GetLastError()); return 17; }
        volatile unsigned long *phase = (volatile unsigned long *)GetProcAddress(shim, "repro_diagnostic_init_phase");
        if (!phase) return 18;
        *(volatile uint64_t *)(repro_hook_probe_state + 2) = (uintptr_t)phase;
    }
    repro_hook_probe_state[0] = 1;
    if (prepared) {
        DWORD old, ignored;
        if (!VirtualProtect(target, 5, PAGE_EXECUTE_READWRITE, &old)) return 7;
        if (!VirtualProtect(target, 5, old, &ignored)) return 8;
    }
    if (fullShim) {
        typedef DWORD (WINAPI *InitFn)(LPVOID);
        InitFn init = (InitFn)GetProcAddress(shim, "repro_runtime_init");
        if (!init) return 19;
        repro_hook_probe_state[0] = 11;
        DWORD code = init(NULL);
        printf("actual-shim-init=%lu\n", (unsigned long)code);
        fflush(stdout);
        if (code) return 20;
        repro_hook_probe_state[0] = 12;
        HANDLE file = ((CreateFileFn)target)(L"NUL", GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
        if (file == INVALID_HANDLE_VALUE) return 21;
        CloseHandle(file);
        puts("actual shim initialization and real file call completed");
        return 0;
    }
    repro_hook_probe_state[0] = 2;
    if (ct_inline_hook_begin_transaction()) return 9;
    if (ct_inline_hook_install(target, observed_create_file, &original)) return 10;
    repro_hook_probe_state[0] = 3;
    int code = ct_inline_hook_commit_transaction();
    printf("install=%d freeze-rounds=%lu\n", code, ct_inline_hook_suspend_round_count());
    fflush(stdout);
    if (code || !original) return 11;
    repro_hook_probe_state[0] = 4;
    HANDLE file = ((CreateFileFn)target)(L"NUL", GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (file == INVALID_HANDLE_VALUE || calls != 1) return 12;
    CloseHandle(file);
    repro_hook_probe_state[0] = 5;
    if (ct_inline_hook_begin_transaction()) return 13;
    if (ct_inline_hook_uninstall(target)) return 14;
    if (ct_inline_hook_commit_transaction()) return 15;
    file = ((CreateFileFn)target)(L"NUL", GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (file == INVALID_HANDLE_VALUE || calls != 1) return 16;
    CloseHandle(file);
    repro_hook_probe_state[0] = 6;
    puts("real call intercepted once and original restored");
    UnmapViewOfFile((void *)repro_hook_probe_state);
    CloseHandle(mapping);
    return 0;
}

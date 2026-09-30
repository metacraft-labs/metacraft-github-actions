/* Real shim, events, thread, file read and ExitProcess. No mocks.
 * The optional worker takes the actual writer registry lock only after the
 * shim's early termination flush. Windows then terminates it during exit.
 */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef int (__cdecl *init_fn)(const char *);
typedef void (__cdecl *schedule_fn)(HANDLE, HANDLE, HANDLE);
typedef void (__cdecl *hold_fn)(HANDLE, HANDLE, HANDLE);
static HANDLE requested, held, ready;
static hold_fn hold_registry;

static DWORD WINAPI worker(LPVOID unused) {
    (void)unused;
    hold_registry(requested, held, ready);
    return 83;
}

int main(int argc, char **argv) {
    if (argc != 5) return 64;
    HMODULE shim = LoadLibraryA(argv[1]);
    if (!shim) return 65;
    init_fn init = (init_fn)(uintptr_t)GetProcAddress(shim, "repro_monitor_shim_init");
    schedule_fn schedule = (schedule_fn)(uintptr_t)GetProcAddress(shim, "repro_diagnostic_schedule_exit");
    hold_registry = (hold_fn)(uintptr_t)GetProcAddress(shim, "repro_diagnostic_hold_writer_registry");
    if (!init || !schedule || !hold_registry || init(NULL)) return 66;
    if (!strcmp(argv[2], "scheduled")) {
        requested = CreateEventA(NULL, TRUE, FALSE, NULL);
        held = CreateEventA(NULL, TRUE, FALSE, argv[4]);
        ready = CreateEventA(NULL, TRUE, FALSE, NULL);
        if (!requested || !held || !ready) return 67;
        HANDLE thread = CreateThread(NULL, 0, worker, NULL, 0, NULL);
        if (!thread) return 68;
        if (WaitForSingleObject(ready, 5000) != WAIT_OBJECT_0) return 72;
        schedule(requested, held, thread);
        /* Retain the worker handle through exit; no destructor runs here. */
    } else if (strcmp(argv[2], "ordinary")) return 69;
    HANDLE probe = CreateFileA(argv[3], GENERIC_READ, FILE_SHARE_READ, NULL,
                               OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (probe == INVALID_HANDLE_VALUE) return 70;
    char bytes[32] = {0};
    DWORD count = 0;
    if (!ReadFile(probe, bytes, sizeof(bytes), &count, NULL) ||
        count != 15 || memcmp(bytes, "shutdown probe\n", 15)) return 71;
    CloseHandle(probe);
    printf("SHUTDOWN-CONTROL application complete mode=%s requested-exit=17\n", argv[2]);
    fflush(stdout);
    ExitProcess(17);
}

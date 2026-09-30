/* Real Windows memory protection and thread suspension, without hooks or mocks.
 * Each worker owns an executable page and repeatedly protects and executes it.
 * The parent runner kills a disposable child that misses its observation bound;
 * no production timeout or patching policy is changed by this diagnostic. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string.h>

#define WORKERS 4
/* All-thread enumeration costs about 60 ms per round on the ARM host.
 * Keep a batch well inside the external 30-second observation bound. */
#define ROUNDS 128
static volatile LONG ready;
static volatile LONG stopped;
static volatile LONG *observation;

/* Only stores while peers are frozen: stdio/loader locks may belong to them.
 * The external PowerShell parent reads this mapping before terminating a
 * stalled child. Fields are round, phase, frozen count, most recent thread. */
static void observe(unsigned round, LONG state) {
    observation[0] = (LONG)round;
    observation[1] = state;
}

static unsigned peer_handles(HANDLE *handles, DWORD *ids) {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snapshot == INVALID_HANDLE_VALUE) ExitProcess(16);
    THREADENTRY32 entry = {0};
    entry.dwSize = sizeof(entry);
    unsigned count = 0;
    if (!Thread32First(snapshot, &entry)) ExitProcess(17);
    do {
        if (entry.th32OwnerProcessID == GetCurrentProcessId() &&
            entry.th32ThreadID != GetCurrentThreadId()) {
            if (count == 128) ExitProcess(18);
            HANDLE thread = OpenThread(THREAD_SUSPEND_RESUME, FALSE, entry.th32ThreadID);
            if (!thread) ExitProcess(19);
            handles[count] = thread;
            ids[count++] = entry.th32ThreadID;
        }
        entry.dwSize = sizeof(entry);
    } while (Thread32Next(snapshot, &entry));
    CloseHandle(snapshot);
    return count;
}

static void phase(unsigned round, const char *name) {
    printf("round=%u phase=%s\n", round, name);
    fflush(stdout);
}

static unsigned char *code_page(void) {
    unsigned char *p = VirtualAlloc(NULL, 4096, MEM_RESERVE | MEM_COMMIT,
                                   PAGE_EXECUTE_READWRITE);
    if (!p) ExitProcess(2);
    /* mov eax, 7; ret -- real x64 code, including on the emulated host. */
    const unsigned char code[] = {0xb8, 7, 0, 0, 0, 0xc3};
    memcpy(p, code, sizeof(code));
    if (!FlushInstructionCache(GetCurrentProcess(), p, sizeof(code))) ExitProcess(3);
    return p;
}

static DWORD WINAPI protection_worker(void *unused) {
    (void)unused;
    unsigned char *page = code_page();
    int (*call)(void) = (int (*)(void))page;
    InterlockedIncrement(&ready);
    while (!InterlockedCompareExchange(&stopped, 0, 0)) {
        DWORD old;
        if (!VirtualProtect(page, 4096, PAGE_EXECUTE_READ, &old)) ExitProcess(4);
        if (call() != 7) ExitProcess(5);
        if (!VirtualProtect(page, 4096, PAGE_EXECUTE_READWRITE, &old)) ExitProcess(6);
    }
    VirtualFree(page, 0, MEM_RELEASE);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    const int active = strcmp(argv[1], "active") == 0;
    const int protect = active || strcmp(argv[1], "protect") == 0;
    const int flush = strcmp(argv[1], "flush") == 0;
    const int write = strcmp(argv[1], "write") == 0;
    const int all = strcmp(argv[2], "all") == 0;
    const int image = strcmp(argv[3], "image") == 0;
    const int system = strcmp(argv[3], "system") == 0;
    if (!protect && !flush && !write) return 2;
    char mappingName[96];
    snprintf(mappingName, sizeof(mappingName), "Local\\ReproProtectionProbe-%lu",
             (unsigned long)GetCurrentProcessId());
    HANDLE mapping = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE,
                                        0, 4 * sizeof(LONG), mappingName);
    if (!mapping) return 20;
    observation = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, 4 * sizeof(LONG));
    if (!observation) return 21;
    HMODULE module = image ? LoadLibraryA("protection-target.dll") :
        system ? GetModuleHandleA("kernel32.dll") : NULL;
    unsigned char *page = image ? (unsigned char *)GetProcAddress(module, "repro_probe_code") :
        system ? (unsigned char *)GetProcAddress(module, "GetFileAttributesW") : code_page();
    if (!page) return 22;
    const unsigned char expected[] = {0xb8, 7, 0, 0, 0, 0xc3};
    if (!system && memcmp(page, expected, sizeof(expected))) return 23;
    MEMORY_BASIC_INFORMATION pageInfo;
    if (!VirtualQuery(page, &pageInfo, sizeof(pageInfo)) ||
        pageInfo.Type != (image || system ? MEM_IMAGE : MEM_PRIVATE) ||
        !(pageInfo.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                             PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) return 24;
    /* Translate the probe page too: real hook targets already contain code
     * that has executed, unlike a fresh untouched executable allocation. */
    if (system) {
        typedef DWORD (WINAPI *AttributesFn)(LPCWSTR);
        if (((AttributesFn)page)(L".") == INVALID_FILE_ATTRIBUTES) return 25;
    } else if (((int (*)(void))page)() != 7) return 15;
    printf("target=%s address=%p type=%lx original-protection=%lx rounds=%u\n",
           argv[3], page, (unsigned long)pageInfo.Type,
           (unsigned long)pageInfo.Protect, ROUNDS);
    HANDLE workers[WORKERS];
    DWORD workerIds[WORKERS];
    for (unsigned i = 0; i < WORKERS; i++) {
        workers[i] = CreateThread(NULL, 0, protection_worker, NULL, 0, &workerIds[i]);
        if (!workers[i]) return 7;
    }
    while (InterlockedCompareExchange(&ready, 0, 0) != WORKERS) Sleep(0);
    for (unsigned round = 0; round < ROUNDS; round++) {
        DWORD old;
        if (!VirtualProtect(page, 6, write ? PAGE_EXECUTE_READWRITE : PAGE_EXECUTE_READ, &old)) return 8;
        phase(round, active ? "workers-active" : "freeze-workers");
        HANDLE peers[128]; DWORD ids[128];
        observe(round, 1);
        unsigned count = all ? peer_handles(peers, ids) : WORKERS;
        if (!all) {
            memcpy(peers, workers, sizeof(workers));
            memcpy(ids, workerIds, sizeof(workerIds));
        }
        observation[2] = 0;
        if (!active) {
            observe(round, 2);
            for (unsigned i = 0; i < count; i++) {
                observation[3] = (LONG)ids[i];
                if (SuspendThread(peers[i]) == (DWORD)-1) return 9;
                observation[2] = (LONG)(i + 1);
            }
        }
        observe(round, 3);
        if (protect && !VirtualProtect(page, 6, PAGE_EXECUTE_READWRITE, &old)) return 10;
        if (flush && !FlushInstructionCache(GetCurrentProcess(), page, 6)) return 11;
        /* A same-byte store exercises the system page's CoW/invalidation
         * path without corrupting an API that the probe may call later. */
        if (write) {
            volatile unsigned char *byte = page + 1;
            *byte = system ? *byte : (unsigned char)(round & 127);
        }
        observe(round, 4);
        if (!active) {
            observe(round, 5);
            for (unsigned i = 0; i < count; i++)
                if (ResumeThread(peers[i]) == (DWORD)-1) return 12;
        }
        if (all) for (unsigned i = 0; i < count; i++) CloseHandle(peers[i]);
        phase(round, "operation-returned");
        if (write && !FlushInstructionCache(GetCurrentProcess(), page, 6)) return 13;
        Sleep(0);
    }
    InterlockedExchange(&stopped, 1);
    if (WaitForMultipleObjects(WORKERS, workers, TRUE, 5000) != WAIT_OBJECT_0) return 14;
    for (unsigned i = 0; i < WORKERS; i++) CloseHandle(workers[i]);
    if (image) FreeLibrary(module);
    else if (!system) VirtualFree(page, 0, MEM_RELEASE);
    UnmapViewOfFile((void *)observation);
    CloseHandle(mapping);
    puts("all rounds completed");
    return 0;
}

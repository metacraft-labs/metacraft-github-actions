/* Real Windows memory protection and thread suspension, without hooks or mocks.
 * Each worker owns an executable page and repeatedly protects and executes it.
 * The parent runner kills a disposable child that misses its observation bound;
 * no production timeout or patching policy is changed by this diagnostic. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define WORKERS 4
#define ROUNDS 512
static volatile LONG ready;
static volatile LONG stopped;

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
    if (argc != 2) return 2;
    const int active = strcmp(argv[1], "active") == 0;
    const int protect = active || strcmp(argv[1], "protect") == 0;
    const int flush = strcmp(argv[1], "flush") == 0;
    const int write = strcmp(argv[1], "write") == 0;
    if (!protect && !flush && !write) return 2;
    unsigned char *page = code_page();
    /* Translate the probe page too: real hook targets already contain code
     * that has executed, unlike a fresh untouched executable allocation. */
    if (((int (*)(void))page)() != 7) return 15;
    HANDLE workers[WORKERS];
    for (unsigned i = 0; i < WORKERS; i++) {
        workers[i] = CreateThread(NULL, 0, protection_worker, NULL, 0, NULL);
        if (!workers[i]) return 7;
    }
    while (InterlockedCompareExchange(&ready, 0, 0) != WORKERS) Sleep(0);
    for (unsigned round = 0; round < ROUNDS; round++) {
        DWORD old;
        if (!VirtualProtect(page, 4096, write ? PAGE_EXECUTE_READWRITE : PAGE_EXECUTE_READ, &old)) return 8;
        phase(round, active ? "workers-active" : "freeze-workers");
        if (!active) {
            for (unsigned i = 0; i < WORKERS; i++)
                if (SuspendThread(workers[i]) == (DWORD)-1) return 9;
        }
        phase(round, argv[1]);
        if (protect && !VirtualProtect(page, 4096, PAGE_EXECUTE_READWRITE, &old)) return 10;
        if (flush && !FlushInstructionCache(GetCurrentProcess(), page, 6)) return 11;
        if (write) ((volatile unsigned char *)page)[1] = (unsigned char)(round & 127);
        phase(round, "operation-returned");
        if (!active) {
            for (unsigned i = 0; i < WORKERS; i++)
                if (ResumeThread(workers[i]) == (DWORD)-1) return 12;
        }
        if (write && !FlushInstructionCache(GetCurrentProcess(), page, 6)) return 13;
        Sleep(0);
    }
    InterlockedExchange(&stopped, 1);
    if (WaitForMultipleObjects(WORKERS, workers, TRUE, 5000) != WAIT_OBJECT_0) return 14;
    for (unsigned i = 0; i < WORKERS; i++) CloseHandle(workers[i]);
    VirtualFree(page, 0, MEM_RELEASE);
    puts("all rounds completed");
    return 0;
}

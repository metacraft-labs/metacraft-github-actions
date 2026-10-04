/* Diagnostic only: compare real thread enumeration APIs in the same x64
 * process. Four live worker threads establish that both snapshots are complete
 * for known peers. No thread is suspended and no hook is changed here. */
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <tlhelp32.h>
#include <processsnapshot.h>
#include <stdio.h>
#include <string.h>

static DWORD peers[4];
static HANDLE stop_event;

static DWORD WINAPI worker(void *unused) {
    (void)unused;
    return WaitForSingleObject(stop_event, INFINITE) == WAIT_OBJECT_0 ? 0 : 1;
}

static unsigned known_thread(DWORD id) {
    unsigned found = id == GetCurrentThreadId() ? 16u : 0u;
    for (unsigned i = 0; i < 4; ++i)
        if (id == peers[i]) found |= 1u << i;
    return found;
}

static int toolhelp(unsigned *count) {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return 10;
    THREADENTRY32 entry = {0};
    entry.dwSize = sizeof(entry);
    unsigned found = 0;
    BOOL more = Thread32First(snapshot, &entry);
    while (more) {
        if (entry.th32OwnerProcessID == GetCurrentProcessId()) {
            ++*count;
            found |= known_thread(entry.th32ThreadID);
        }
        entry.dwSize = sizeof(entry);
        more = Thread32Next(snapshot, &entry);
    }
    DWORD error = GetLastError();
    CloseHandle(snapshot);
    return error == ERROR_NO_MORE_FILES && found == 31u ? 0 : 11;
}

static int process_snapshot(unsigned *count) {
    HPSS snapshot = NULL;
    HPSSWALK marker = NULL;
    DWORD error = PssCaptureSnapshot(GetCurrentProcess(), PSS_CAPTURE_THREADS,
                                      0, &snapshot);
    if (error != ERROR_SUCCESS) return 20;
    error = PssWalkMarkerCreate(NULL, &marker);
    unsigned found = 0;
    if (error == ERROR_SUCCESS) {
        PSS_THREAD_ENTRY entry;
        while ((error = PssWalkSnapshot(snapshot, PSS_WALK_THREADS, marker,
                                        &entry, sizeof(entry))) == ERROR_SUCCESS) {
            if (entry.ProcessId != GetCurrentProcessId()) {
                error = ERROR_INVALID_DATA;
                break;
            }
            ++*count;
            found |= known_thread(entry.ThreadId);
        }
        PssWalkMarkerFree(marker);
    }
    PssFreeSnapshot(GetCurrentProcess(), snapshot);
    return error == ERROR_NO_MORE_ITEMS && found == 31u ? 0 : 21;
}

int main(int argc, char **argv) {
    IMAGE_DOS_HEADER *image = (IMAGE_DOS_HEADER *)GetModuleHandleW(NULL);
    IMAGE_NT_HEADERS *header = (IMAGE_NT_HEADERS *)((char *)image + image->e_lfanew);
    if (header->FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64) return 30;
    SYSTEM_INFO system;
    GetNativeSystemInfo(&system);
    printf("PE machine=0x%x native processor architecture=%u\n",
            header->FileHeader.Machine, system.wProcessorArchitecture);
    USHORT process_machine = 0, native_machine = 0;
    if (!IsWow64Process2(GetCurrentProcess(), &process_machine, &native_machine)) return 34;
    printf("IsWow64Process2 process=0x%x native=0x%x\n", process_machine, native_machine);
    if (argc != 2 ||
        (strcmp(argv[1], "ARM64") == 0 ? native_machine != IMAGE_FILE_MACHINE_ARM64 :
          strcmp(argv[1], "X64") != 0 || native_machine != IMAGE_FILE_MACHINE_AMD64)) return 35;
    stop_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!stop_event) return 31;
    HANDLE workers[4] = {0};
    int result = 0;
    for (unsigned i = 0; i < 4; ++i) {
        workers[i] = CreateThread(NULL, 0, worker, NULL, 0, &peers[i]);
        if (!workers[i]) { result = 32; goto cleanup; }
    }
    LARGE_INTEGER frequency;
    QueryPerformanceFrequency(&frequency);
    for (unsigned round = 0; round < 20; ++round) {
        for (unsigned mode = 0; mode < 2; ++mode) {
            unsigned count = 0;
            LARGE_INTEGER start, end;
            QueryPerformanceCounter(&start);
            result = mode ? process_snapshot(&count) : toolhelp(&count);
            QueryPerformanceCounter(&end);
            printf("round=%u api=%s own_threads=%u milliseconds=%.6f result=%d\n",
                    round, mode ? "PSS" : "Toolhelp", count,
                    1000.0 * (double)(end.QuadPart - start.QuadPart) /
                    (double)frequency.QuadPart, result);
            if (result) goto cleanup;
        }
    }
cleanup:
    SetEvent(stop_event);
    for (unsigned i = 0; i < 4; ++i) {
        if (!workers[i]) continue;
        if (WaitForSingleObject(workers[i], 30000) != WAIT_OBJECT_0) result = 33;
        CloseHandle(workers[i]);
    }
    CloseHandle(stop_event);
    return result;
}

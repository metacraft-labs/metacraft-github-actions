/* Disposable Windows startup evidence. Real processes and threads; no mocks.
 * The wait keeps the fixture's original deadline. Only after expiry do we
 * capture bounded instruction addresses, before terminating the helper.
 * No stack memory, arguments, environment values or file contents are logged.
 */
#ifndef RUNQUOTA_DIAGNOSTIC_HELPER_STARTUP_H
#define RUNQUOTA_DIAGNOSTIC_HELPER_STARTUP_H
#include <windows.h>
#include <tlhelp32.h>
#include <dbghelp.h>
#include <stdio.h>
#include <stdint.h>

static unsigned rq_diagnostic_contexts;

static void rq_startup_address(HANDLE process, const char *label, DWORD64 ip) {
    MEMORY_BASIC_INFORMATION memory;
    char path[1024] = {0};
    typedef DWORD (WINAPI *NameFn)(HANDLE, HMODULE, LPSTR, DWORD);
    NameFn name = (NameFn)GetProcAddress(GetModuleHandleA("kernel32.dll"),
                                       "K32GetModuleFileNameExA");
    if (VirtualQueryEx(process, (void *)(uintptr_t)ip, &memory, sizeof(memory))) {
        if (name) name(process, (HMODULE)memory.AllocationBase, path, sizeof(path));
        fprintf(stderr, "HELPER-START %s=%llx module=%s offset=%llx\n", label,
                (unsigned long long)ip, path,
                (unsigned long long)(ip - (uintptr_t)memory.AllocationBase));
    }
}

static void rq_startup_unwind(HANDLE process, HANDLE thread, CONTEXT context) {
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
    PFUNCTION_TABLE_ACCESS_ROUTINE64 functions =
        (PFUNCTION_TABLE_ACCESS_ROUTINE64)GetProcAddress(helper, "SymFunctionTableAccess64");
    PGET_MODULE_BASE_ROUTINE64 modules =
        (PGET_MODULE_BASE_ROUTINE64)GetProcAddress(helper, "SymGetModuleBase64");
    if (init && cleanup && walk && functions && modules && init(process, "", TRUE)) {
        STACKFRAME64 frame = {0};
        frame.AddrPC.Offset = context.Rip;
        frame.AddrPC.Mode = AddrModeFlat;
        frame.AddrStack.Offset = context.Rsp;
        frame.AddrStack.Mode = AddrModeFlat;
        frame.AddrFrame.Offset = context.Rbp;
        frame.AddrFrame.Mode = AddrModeFlat;
        DWORD64 previous = 0;
        for (unsigned i = 0; i < 8; ++i) {
            if (!walk(IMAGE_FILE_MACHINE_AMD64, process, thread, &frame, &context,
                      NULL, functions, modules, NULL) || !frame.AddrPC.Offset ||
                frame.AddrPC.Offset == previous) break;
            previous = frame.AddrPC.Offset;
            rq_startup_address(process, "unwind-ip", frame.AddrPC.Offset);
        }
        cleanup(process);
    }
    FreeLibrary(helper);
}

static DWORD rq_diagnostic_wait_helper(DWORD pid, DWORD timeout) {
    HANDLE process = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_INFORMATION |
                                 PROCESS_VM_READ | PROCESS_TERMINATE, FALSE, pid);
    if (!process) return WAIT_FAILED;
    DWORD result = WaitForSingleObject(process, timeout);
    if (result == WAIT_TIMEOUT) {
        FILETIME created, exited, kernel, user;
        fprintf(stderr, "HELPER-START timeout pid=%lu bound_ms=%lu\n",
                (unsigned long)pid, (unsigned long)timeout);
        if (GetProcessTimes(process, &created, &exited, &kernel, &user)) {
            ULARGE_INTEGER k, u;
            k.LowPart = kernel.dwLowDateTime; k.HighPart = kernel.dwHighDateTime;
            u.LowPart = user.dwLowDateTime; u.HighPart = user.dwHighDateTime;
            fprintf(stderr, "HELPER-START kernel_100ns=%llu user_100ns=%llu\n",
                    (unsigned long long)k.QuadPart, (unsigned long long)u.QuadPart);
        }
        HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
        if (snapshot != INVALID_HANDLE_VALUE) {
            THREADENTRY32 entry = {0};
            entry.dwSize = sizeof(entry);
            unsigned observed = 0;
            if (Thread32First(snapshot, &entry)) do {
                if (entry.th32OwnerProcessID != pid || observed >= 8) continue;
                ++observed;
                HANDLE thread = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT |
                                           THREAD_QUERY_INFORMATION, FALSE, entry.th32ThreadID);
                if (!thread) continue;
                DWORD previous = SuspendThread(thread);
                if (previous != (DWORD)-1) {
                    CONTEXT context __attribute__((aligned(16))) = {0};
                    context.ContextFlags = CONTEXT_FULL;
                    BOOL got = GetThreadContext(thread, &context);
                    fprintf(stderr, "HELPER-START thread=%lu context=%d previous_suspend=%lu\n",
                            (unsigned long)entry.th32ThreadID, got, (unsigned long)previous);
                    if (got) {
                        ++rq_diagnostic_contexts;
                        rq_startup_address(process, "ip", context.Rip);
                        rq_startup_unwind(process, thread, context);
                    }
                    ResumeThread(thread);
                }
                CloseHandle(thread);
            } while (Thread32Next(snapshot, &entry));
            CloseHandle(snapshot);
        }
        fflush(stderr);
        /* Match Nim's timeout exit code. The caller also records WAIT_TIMEOUT,
         * so zero cannot turn an expired normal-exit helper into a success. */
        TerminateProcess(process, 0);
    }
    CloseHandle(process);
    return result;
}
#endif

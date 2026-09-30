/* Real CreateProcessW control, independent of RunQuota and its launcher.
 * Never print the inherited environment: only the three synthetic/public
 * names relevant to this experiment and a count of all remaining names. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

static int child(void) {
    const wchar_t *names[] = {
        L"RQ_TEST_DECLARED", L"RQ_TEST_LAUNCHER_ONLY", L"PROCESSOR_ARCHITECTURE"
    };
    wchar_t *block = GetEnvironmentStringsW();
    if (!block) return 2;
    unsigned total = 0, other = 0;
    for (const wchar_t *entry = block; *entry; entry += wcslen(entry) + 1) {
        total++;
        int known = 0;
        for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
            size_t n = wcslen(names[i]);
            if (_wcsnicmp(entry, names[i], n) == 0 && entry[n] == L'=') {
                wprintf(L"ENV %ls\n", entry);
                known = 1;
            }
        }
        if (!known) other++;
    }
    FreeEnvironmentStringsW(block);
    printf("total=%u other=%u\n", total, other);
    return 0;
}

int main(int argc, char **argv) {
    (void)argv;
    if (argc > 1) return child();
    if (!SetEnvironmentVariableW(L"RQ_TEST_LAUNCHER_ONLY", L"leaks")) return 3;
    wchar_t path[32768];
    DWORD length = GetModuleFileNameW(NULL, path, 32768);
    if (!length || length >= 32768) return 4;
    wchar_t onlyDeclared[] = L"RQ_TEST_DECLARED=yes\0";
    wchar_t explicitArchitecture[] =
        L"PROCESSOR_ARCHITECTURE=DECLARED_TEST_ARCH\0RQ_TEST_DECLARED=yes\0";
    void *blocks[] = {onlyDeclared, explicitArchitecture, NULL};
    const char *cases[] = {"declared-only", "declared-architecture", "inherited"};
    for (unsigned i = 0; i < 3; i++) {
        wchar_t command[32790];
        _snwprintf(command, 32790, L"\"%ls\" --child", path);
        STARTUPINFOW startup = {0};
        PROCESS_INFORMATION process = {0};
        startup.cb = sizeof(startup);
        printf("CASE %s\n", cases[i]);
        fflush(stdout);
        if (!CreateProcessW(path, command, NULL, NULL, TRUE,
                            CREATE_UNICODE_ENVIRONMENT, blocks[i], NULL,
                            &startup, &process)) {
            printf("CreateProcessW error=%lu\n", (unsigned long)GetLastError());
            return 5;
        }
        DWORD waited = WaitForSingleObject(process.hProcess, 30000);
        if (waited != WAIT_OBJECT_0) {
            TerminateProcess(process.hProcess, 124);
            WaitForSingleObject(process.hProcess, 5000);
        }
        DWORD code = 0;
        GetExitCodeProcess(process.hProcess, &code);
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        printf("RESULT %s waited=%lu exit=%lu\n", cases[i],
               (unsigned long)waited, (unsigned long)code);
        if (waited != WAIT_OBJECT_0 || code != 0) return 6;
    }
    return 0;
}

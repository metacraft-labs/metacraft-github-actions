/* Real child exits and a real sleeping child validate the failure observer. */
#include "windows-helper-startup.h"
#include <string.h>

static int check_child(const char *executable, const char *mode, DWORD expected_wait,
                       DWORD expected_exit) {
    char command[32768];
    if (snprintf(command, sizeof(command), "\"%s\" %s", executable, mode) >=
        (int)sizeof(command)) return 1;
    STARTUPINFOA startup = {0};
    PROCESS_INFORMATION child = {0};
    startup.cb = sizeof(startup);
    if (!CreateProcessA(NULL, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &child)) return 2;
    DWORD wait = rq_diagnostic_wait_helper(child.dwProcessId, 3000);
    DWORD code = STILL_ACTIVE;
    DWORD reaped = WaitForSingleObject(child.hProcess, 5000);
    GetExitCodeProcess(child.hProcess, &code);
    if (reaped != WAIT_OBJECT_0) TerminateProcess(child.hProcess, 99);
    CloseHandle(child.hThread);
    CloseHandle(child.hProcess);
    if (wait != expected_wait || code != expected_exit || reaped != WAIT_OBJECT_0) return 3;
    if (expected_wait == WAIT_TIMEOUT && rq_diagnostic_contexts == 0) return 4;
    fprintf(stdout, "PASS helper startup observer %s wait=%lu exit=%lu contexts=%u\n",
            mode, (unsigned long)wait, (unsigned long)code, rq_diagnostic_contexts);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "fast-child") == 0) return 17;
    if (argc == 2 && strcmp(argv[1], "slow-child") == 0) { Sleep(10000); return 31; }
    char executable[32768];
    if (!GetModuleFileNameA(NULL, executable, sizeof(executable))) return 5;
    int code = check_child(executable, "fast-child", WAIT_OBJECT_0, 17);
    if (code) return code;
    return check_child(executable, "slow-child", WAIT_TIMEOUT, 0);
}

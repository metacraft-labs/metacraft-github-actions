/* Real Windows process snapshots, with a named-event positive/negative control.
 * No mocks, handle closure in another process, memory dump, or VA clone.
 * https://learn.microsoft.com/windows/win32/api/processsnapshot/ns-processsnapshot-pss_handle_entry
 */
#define _WIN32_WINNT 0x0603
#include <windows.h>
#include <processsnapshot.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

static void text_utf8(const wchar_t *value, WORD bytes) {
  char buffer[4096];
  int count = value ? WideCharToMultiByte(CP_UTF8, 0, value,
      bytes / sizeof(wchar_t), buffer, sizeof(buffer) - 1, NULL, NULL) : 0;
  if (count <= 0) count = 0;
  buffer[count] = 0;
  for (int i = 0; i < count; ++i)
    if (buffer[i] == '\n' || buffer[i] == '\r' || buffer[i] == '\t') buffer[i] = ' ';
  fputs(buffer, stdout);
}

static int snapshot(DWORD pid, const char *phase, const wchar_t *control, int *found) {
  HANDLE process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ |
      PROCESS_DUP_HANDLE, FALSE, pid);
  if (!process) { fprintf(stderr, "OpenProcess: %lu\n", GetLastError()); return 1; }
  DWORD count = 0;
  if (!GetProcessHandleCount(process, &count)) {
    fprintf(stderr, "GetProcessHandleCount: %lu\n", GetLastError());
    CloseHandle(process); return 1;
  }
  printf("SNAPSHOT phase=%s pid=%lu handles=%lu\n", phase, pid, count);
  HPSS captured = NULL;
  DWORD rc = PssCaptureSnapshot(process, PSS_CAPTURE_HANDLES |
      PSS_CAPTURE_HANDLE_NAME_INFORMATION | PSS_CAPTURE_HANDLE_BASIC_INFORMATION |
      PSS_CAPTURE_HANDLE_TYPE_SPECIFIC_INFORMATION, 0, &captured);
  CloseHandle(process);
  if (rc) { fprintf(stderr, "PssCaptureSnapshot: %lu\n", rc); return 1; }
  HPSSWALK marker = NULL;
  rc = PssWalkMarkerCreate(NULL, &marker);
  if (rc) {
    fprintf(stderr, "PssWalkMarkerCreate: %lu\n", rc);
    PssFreeSnapshot(GetCurrentProcess(), captured); return 1;
  }
  PSS_HANDLE_ENTRY entry = {0};
  unsigned walked = 0;
  while ((rc = PssWalkSnapshot(captured, PSS_WALK_HANDLES, marker,
                              &entry, sizeof(entry))) == ERROR_SUCCESS) {
    printf("HANDLE phase=%s value=%p flags=%u type=%u typename=", phase,
            entry.Handle, (unsigned)entry.Flags, (unsigned)entry.ObjectType);
    text_utf8(entry.TypeName, entry.TypeNameLength);
    fputs(" name=", stdout);
    text_utf8(entry.ObjectName, entry.ObjectNameLength);
    putchar('\n');
    if (control && entry.ObjectName &&
        entry.ObjectNameLength >= wcslen(control) * sizeof(wchar_t)) {
      size_t n = entry.ObjectNameLength / sizeof(wchar_t);
      size_t wanted = wcslen(control);
      /* The length may include a terminator. Stay within the returned span. */
      while (n && entry.ObjectName[n - 1] == L'\0') --n;
      if (n >= wanted && wmemcmp(entry.ObjectName + n - wanted, control, wanted) == 0) ++*found;
    }
    ++walked;
    ZeroMemory(&entry, sizeof(entry));
  }
  printf("SNAPSHOT phase=%s walked=%u status=%lu\n", phase, walked, rc);
  DWORD marker_rc = PssWalkMarkerFree(marker);
  DWORD free_rc = PssFreeSnapshot(GetCurrentProcess(), captured);
  if (rc != ERROR_NO_MORE_ITEMS || marker_rc || free_rc) return 1;
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 3) return snapshot((DWORD)strtoul(argv[1], NULL, 10), argv[2], NULL, NULL);
  if (argc != 1) return 2;
  wchar_t name[100];
  swprintf(name, 100, L"mcl-handle-control-%lu", GetCurrentProcessId());
  HANDLE event = CreateEventW(NULL, TRUE, FALSE, name);
  if (!event) return 1;
  int before = 0, after = 0;
  int rc = snapshot(GetCurrentProcessId(), "control-open", name, &before);
  if (!CloseHandle(event)) return 1;
  rc |= snapshot(GetCurrentProcessId(), "control-closed", name, &after);
  printf("CONTROL open=%d closed=%d valid=%d\n", before, after, before == 1 && after == 0);
  return rc || before != 1 || after != 0;
}

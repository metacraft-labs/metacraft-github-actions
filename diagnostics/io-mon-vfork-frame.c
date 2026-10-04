/* Real vfork/exec under the current production shim. A temporary, trace-free
 * diagnostic export reads its Nim frame pointer without introducing a frame.
 * No host hooks or compiler behavior are mocked. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc != 2) return 10;
  void *(*frame)(void) = dlsym(RTLD_DEFAULT, "io_mon_diagnostic_frame_state");
  if (!frame) return 11;
  void *before = frame();
  pid_t child = vfork();
  if (child < 0) return 12;
  if (child == 0) {
    execl(argv[1], argv[1], (char *)0);
    _exit(13);
  }
  void *after = frame();
  int stale = after != before;
  printf("vfork frame state: before-null=%d after-null=%d changed=%d\n",
         before == NULL, after == NULL, stale);
  int status = 0;
  if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status))
    return 14;
  return stale ? 71 : 0;
}

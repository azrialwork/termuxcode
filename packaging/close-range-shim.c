/*
 * Termux runs its app with targetSdk 28, so Android's seccomp policy traps
 * close_range (added in API 30) with SIGSYS. Bun's startup calls
 * close_range(4, UINT_MAX, CLOSE_RANGE_CLOEXEC), which kills the binary
 * before it prints anything.
 *
 * This shim replaces the trapped call with a /proc/self/fd scan. It is
 * preloaded by the launcher; it only affects close_range and forwards every
 * other syscall() call unchanged.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef __NR_close_range
#define __NR_close_range 436
#endif
#define CLOSE_RANGE_CLOEXEC 4

static void emulate(unsigned int first, unsigned int last, unsigned int flags) {
  DIR *dir = opendir("/proc/self/fd");
  if (!dir) {
    errno = ENOSYS;
    return;
  }
  int dir_fd = dirfd(dir);
  char *names[256];
  int count = 0;
  struct dirent *entry;
  while ((entry = readdir(dir)) != NULL && count < 256) {
    if (entry->d_name[0] < '0' || entry->d_name[0] > '9') {
      continue;
    }
    names[count++] = strdup(entry->d_name);
  }
  for (int i = 0; i < count; i++) {
    unsigned int fd = (unsigned int)strtoul(names[i], NULL, 10);
    if (fd >= first && fd <= last && (int)fd != dir_fd) {
      if (flags & CLOSE_RANGE_CLOEXEC) {
        fcntl((int)fd, F_SETFD, FD_CLOEXEC);
      } else {
        close((int)fd);
      }
    }
    free(names[i]);
  }
  closedir(dir);
}

int close_range(unsigned int first, unsigned int last, unsigned int flags) {
  emulate(first, last, flags);
  return 0;
}

int close_range64(unsigned int first, unsigned int last, unsigned int flags) {
  return close_range(first, last, flags);
}

long syscall(long number, ...) {
  va_list args;
  va_start(args, number);
  long a1 = va_arg(args, long);
  long a2 = va_arg(args, long);
  long a3 = va_arg(args, long);
  long a4 = va_arg(args, long);
  long a5 = va_arg(args, long);
  long a6 = va_arg(args, long);
  va_end(args);

  if (number == __NR_close_range) {
    emulate((unsigned int)a1, (unsigned int)a2, (unsigned int)a3);
    return 0;
  }

  static long (*real_syscall)(long, ...) = NULL;
  if (real_syscall == NULL) {
    real_syscall = (long (*)(long, ...))dlsym(RTLD_NEXT, "syscall");
  }
  return real_syscall(number, a1, a2, a3, a4, a5, a6);
}

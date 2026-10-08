/* SPDX-License-Identifier: AGPL-3.0-or-later */
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/capability.h>
#include <pthread.h>
#include <seccomp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/socket.h>
#include <unistd.h>

static int denied(void) { return errno == EACCES || errno == ENOENT || errno == EROFS; }

static void *thread(void *arg) { return arg; }

int main(int argc, char **argv) {
    assert(argc >= 3);
    if (!strcmp(argv[1], "unsupported")) {
        scmp_filter_ctx filter = seccomp_init(SCMP_ACT_ALLOW);
        assert(filter);
        assert(!seccomp_rule_add(filter, SCMP_ACT_ERRNO(ENOSYS), SCMP_SYS(landlock_create_ruleset), 0));
        assert(!seccomp_load(filter));
        execv(argv[2], &argv[2]);
        return 1;
    }
    assert(argc == 4);
    int asset = open(argv[3], O_RDONLY);
    assert(asset >= 0);
    close(asset);
    assert(open(argv[3], O_WRONLY) == -1 && denied());
    assert(getenv("SANDBOX_TEST_SECRET") == NULL);
    assert(getenv("AWS_SECRET_ACCESS_KEY") == NULL);
    assert(getenv("LD_PRELOAD") == NULL);
    assert(prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) == 1);
    struct __user_cap_header_struct header = {.version = _LINUX_CAPABILITY_VERSION_3};
    struct __user_cap_data_struct caps[2];
    assert(!syscall(SYS_capget, &header, caps));
    assert(!caps[0].effective && !caps[1].effective && !caps[0].permitted && !caps[1].permitted);
    assert(open(argv[1], O_RDONLY) == -1 && denied());
    assert(open(argv[1], O_WRONLY | O_TRUNC) == -1 && denied());
    assert(truncate(argv[1], 0) == -1 && denied());
    assert(chmod(argv[1], 0) == -1 && errno == EPERM);
    assert(open("/proc/self/environ", O_RDONLY) == -1 && denied());
    assert(open("/proc/1/environ", O_RDONLY) == -1 && denied());
    char path[4096];
    assert(snprintf(path, sizeof(path), "%s/output", argv[2]) > 0);
    int fd = open(path, O_CREAT | O_WRONLY, 0600);
    assert(fd >= 0 && write(fd, "ok", 2) == 2);
    close(fd);
    char link_path[4096];
    assert(snprintf(link_path, sizeof(link_path), "%s/planted", argv[2]) > 0);
    assert(symlink(argv[1], link_path) == -1 && errno == EPERM);
    assert(symlinkat(argv[1], AT_FDCWD, link_path) == -1 && errno == EPERM);
    assert(link(path, link_path) == -1 && errno == EPERM);
    assert(linkat(AT_FDCWD, path, AT_FDCWD, link_path, 0) == -1 && errno == EPERM);
    assert(mknod(link_path, S_IFIFO | 0600, 0) == -1 && errno == EPERM);
    assert(mknodat(AT_FDCWD, link_path, S_IFIFO | 0600, 0) == -1 && errno == EPERM);
    /* HLS finalizes regular .tmp files by renaming them. */
    assert(rename(path, link_path) == 0);
    assert(snprintf(path, sizeof(path), "%s/escape", argv[2]) > 0);
    assert(open(path, O_RDONLY) == -1 && denied());
    assert(fork() == -1 && errno == EPERM);
    /* Bypass libc/preload entirely, as compromised native code can do. */
    assert(syscall(SYS_socket, AF_INET, SOCK_STREAM, 0) == -1 && errno == EPERM);
    assert(syscall(SYS_socket, AF_INET6, SOCK_STREAM, 0) == -1 && errno == EPERM);
    assert(syscall(SYS_socket, AF_UNIX, SOCK_STREAM, 0) == -1 && errno == EPERM);
    assert(syscall(SYS_connect, -1, NULL, 0) == -1 && errno == EPERM);
    assert(kill(getppid(), 0) == -1 && errno == EPERM);
    assert(syscall(SYS_tgkill, getppid(), getppid(), 0) == -1 && errno == EPERM);
    pthread_t child;
    assert(!pthread_create(&child, NULL, thread, NULL));
    assert(!pthread_join(child, NULL));
    struct rlimit limit;
    assert(prlimit(getppid(), RLIMIT_NOFILE, NULL, &limit) == -1 && errno == EPERM);
    assert(!getrlimit(RLIMIT_CORE, &limit) && limit.rlim_max == 0);
    assert(!getrlimit(RLIMIT_AS, &limit) && limit.rlim_max <= 16ULL * 1024 * 1024 * 1024);
    puts("sandbox confinement passed");
    return 0;
}

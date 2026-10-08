/* Simulate native code execution in the parser, including direct syscalls. */
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <linux/sockios.h>
#include <sys/prctl.h>
#include <unistd.h>

int main(int argc, char **argv) {
    assert(argc == 3);
    assert(!strcmp(argv[1], "http://127.0.0.1/0"));
    assert(!getenv("AWS_SECRET_ACCESS_KEY"));
    assert(open(argv[2], O_RDONLY) < 0);
    /* Block planted output links before filesystem resolution on every backend. */
    assert(symlink(argv[2], "/mave-output-link-probe") == -1 && errno == EPERM);
    assert(symlinkat(argv[2], AT_FDCWD, "/mave-output-link-probe") == -1 && errno == EPERM);
    assert(link(argv[2], "/mave-output-link-probe") == -1 && errno == EPERM);
    assert(linkat(AT_FDCWD, argv[2], AT_FDCWD, "/mave-output-link-probe", 0) == -1 && errno == EPERM);
    assert(open("/proc/self/environ", O_RDONLY) < 0);
    char parent[128];
    snprintf(parent, sizeof(parent), "/proc/%d/mem", getppid());
    assert(open(parent, O_RDONLY) < 0);
    assert(syscall(SYS_process_vm_readv, getppid(), NULL, 0, NULL, 0, 0) == -1 && errno == EPERM);
    assert(syscall(SYS_socket, AF_INET, SOCK_STREAM, 0) == -1 && errno == EPERM);
    assert(syscall(SYS_socket, AF_INET6, SOCK_STREAM, 0) == -1 && errno == EPERM);
    assert(syscall(SYS_socket, AF_UNIX, SOCK_STREAM, 0) == -1 && errno == EPERM);
    assert(syscall(SYS_connect, -1, NULL, 0) == -1 && errno == EPERM);
    assert(kill(getppid(), 0) == -1 && errno == EPERM);
    assert(fork() == -1 && errno == EPERM);
    int death_signal = 0;
    assert(!prctl(PR_GET_PDEATHSIG, &death_signal) && death_signal == SIGKILL);
    assert(prctl(PR_SET_PDEATHSIG, 0) == -1 && errno == EPERM);
    assert(syscall(SYS_prctl, (1ULL << 32) | PR_SET_PDEATHSIG, 0, 0, 0, 0) == -1 && errno == EPERM);
    assert(fcntl(3, F_SETOWN, getppid()) == -1 && errno == EPERM);
    assert(fcntl(3, F_SETSIG, SIGUSR1) == -1 && errno == EPERM);
    assert(syscall(SYS_fcntl, 3, (1ULL << 32) | F_SETOWN, getppid()) == -1 && errno == EPERM);
    int owner = getppid();
    assert(ioctl(3, FIOSETOWN, &owner) == -1 && errno == EPERM);
    /* The allowed transport is a fixed HTTP service, never a general socket proxy. */
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    assert(fd >= 0);
    const char request[] = "GET http://169.254.169.254/metadata HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    assert(write(fd, request, sizeof(request)-1) == sizeof(request)-1);
    char response[512] = {0};
    assert(read(fd, response, sizeof(response)-1) > 0);
    assert(strstr(response, "403 Forbidden"));
    close(fd);
    puts("native broker bypass, parent secrets and cross-job access denied");
}

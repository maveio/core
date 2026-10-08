/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Transport adapter, NOT the security boundary. Seccomp denies real sockets.
 * FD 3 only requests connections to the parent's fixed, per-command HTTP broker.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <netinet/in.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

int socket(int domain, int type, int protocol) {
    if ((domain != AF_INET && domain != AF_INET6) ||
        (type & ~(SOCK_CLOEXEC | SOCK_NONBLOCK)) != SOCK_STREAM ||
        (protocol != 0 && protocol != IPPROTO_TCP)) {
        errno = EPERM;
        return -1;
    }
    pthread_mutex_lock(&lock);
    char request = 'C', response;
    char control[CMSG_SPACE(sizeof(int))];
    struct iovec vector = {.iov_base = &response, .iov_len = 1};
    struct msghdr message = {.msg_iov = &vector, .msg_iovlen = 1,
                            .msg_control = control, .msg_controllen = sizeof(control)};
    int fd = -1;
    if (write(3, &request, 1) == 1 && recvmsg(3, &message, MSG_CMSG_CLOEXEC) == 1) {
        struct cmsghdr *header = CMSG_FIRSTHDR(&message);
        if (!(message.msg_flags & MSG_CTRUNC) && header &&
            header->cmsg_level == SOL_SOCKET && header->cmsg_type == SCM_RIGHTS &&
            header->cmsg_len == CMSG_LEN(sizeof(int)))
            memcpy(&fd, CMSG_DATA(header), sizeof(fd));
    }
    pthread_mutex_unlock(&lock);
    if (fd < 0) errno = ECONNREFUSED;
    return fd;
}

int connect(int fd, const struct sockaddr *address, socklen_t length) {
    (void)fd;
    (void)length;
    if (!address || (address->sa_family != AF_INET && address->sa_family != AF_INET6)) {
        errno = EPERM;
        return -1;
    }
    /* Already connected to an HTTP broker. No requested address is ever dialed. */
    return 0;
}

/* SPDX-License-Identifier: AGPL-3.0-or-later */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <linux/capability.h>
#include <linux/landlock.h>
#include <linux/sched.h>
#include <seccomp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/mount.h>
#include <sys/ioctl.h>
#include <linux/sockios.h>
#include <sched.h>
#include <limits.h>
#include <sys/syscall.h>
#include <unistd.h>

/* Require ABI 3: older Landlock kernels cannot prevent file truncation. */
#define FS_READ (LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR)
#define FS_WRITE (LANDLOCK_ACCESS_FS_WRITE_FILE | LANDLOCK_ACCESS_FS_REMOVE_DIR | \
                  LANDLOCK_ACCESS_FS_REMOVE_FILE | LANDLOCK_ACCESS_FS_MAKE_DIR | \
                  LANDLOCK_ACCESS_FS_MAKE_REG | LANDLOCK_ACCESS_FS_REFER | \
                  LANDLOCK_ACCESS_FS_TRUNCATE)
#define FS_ALL ((1ULL << 15) - 1)

static const char *namespace_root;

static void fail(const char *message) {
    fprintf(stderr, "media sandbox: %s (%s)\n", message, strerror(errno));
    exit(126);
}

static void write_mapping(const char *path, const char *value, int optional) {
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    /* gVisor/older kernels omit setgroups. The UID/GID maps remain mandatory,
       and our final seccomp policy independently prohibits setgroups. */
    if (fd < 0 && optional && errno == ENOENT) return;
    size_t size = strlen(value);
    if (fd < 0 || write(fd, value, size) != (ssize_t)size || close(fd))
        fail(path);
}

static void create_namespace(const char *root) {
    uid_t uid = getuid();
    gid_t gid = getgid();
    if (!root || unshare(CLONE_NEWUSER)) fail("filesystem isolation unavailable");
    char mapping[96];
    snprintf(mapping, sizeof(mapping), "%u %u 1", uid, uid);
    write_mapping("/proc/self/uid_map", mapping, 0);
    write_mapping("/proc/self/setgroups", "deny", 1);
    snprintf(mapping, sizeof(mapping), "%u %u 1", gid, gid);
    write_mapping("/proc/self/gid_map", mapping, 0);
    char options[96];
    snprintf(options, sizeof(options), "size=4m,mode=0700,uid=%u,gid=%u", uid, gid);
    if (unshare(CLONE_NEWNS) || mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) ||
        mount("tmpfs", root, "tmpfs", MS_NOSUID | MS_NODEV, options))
        fail("cannot create private filesystem");
    namespace_root = root;
}

static void bind_path(const char *path, uint64_t access, const struct stat *st) {
    char target[PATH_MAX];
    int length = snprintf(target, sizeof(target), "%s%s", namespace_root, path);
    if (path[0] != '/' || length < 0 || length >= (int)sizeof(target)) {
        errno = EINVAL; fail("invalid filesystem grant");
    }
    /* The new root is empty and these paths come from the trusted coordinator. */
    for (char *p = target + strlen(namespace_root) + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0';
        if (mkdir(target, 0755) && errno != EEXIST) fail("cannot create mount directory");
        *p = '/';
    }
    if (S_ISDIR(st->st_mode)) {
        if (mkdir(target, 0755) && errno != EEXIST) fail("cannot create mount target");
    } else {
        int fd = open(target, O_CREAT | O_WRONLY | O_CLOEXEC, 0600);
        if (fd < 0 || close(fd)) fail("cannot create mount target");
    }
    if (mount(path, target, NULL, MS_BIND, NULL)) fail("cannot bind allowed path");
    unsigned long flags = MS_BIND | MS_REMOUNT | MS_NOSUID;
    /* An unprivileged namespace cannot relax inherited, locked mount flags.
       Preserve the source restrictions when tightening this bind mount. */
    struct statvfs filesystem;
    if (statvfs(path, &filesystem)) fail("cannot inspect allowed mount");
    if (filesystem.f_flag & ST_RDONLY) flags |= MS_RDONLY;
    if (filesystem.f_flag & ST_NOSUID) flags |= MS_NOSUID;
    if (filesystem.f_flag & ST_NODEV) flags |= MS_NODEV;
    if (filesystem.f_flag & ST_NOEXEC) flags |= MS_NOEXEC;
    if (filesystem.f_flag & ST_NOATIME) flags |= MS_NOATIME;
    if (filesystem.f_flag & ST_NODIRATIME) flags |= MS_NODIRATIME;
    if (filesystem.f_flag & ST_RELATIME) flags |= MS_RELATIME;
    if (!(access & LANDLOCK_ACCESS_FS_WRITE_FILE)) flags |= MS_RDONLY;
    if (!(access & LANDLOCK_ACCESS_FS_EXECUTE)) flags |= MS_NOEXEC;
    if (mount(NULL, target, NULL, flags, NULL)) fail("cannot restrict allowed mount");
}

static void allow_path(int ruleset, const char *path, uint64_t access, int optional) {
    int fd = open(path, O_PATH | O_CLOEXEC);
    if (fd < 0) {
        if (optional && errno == ENOENT) return;
        fail("cannot open allowed path");
    }
    struct stat st;
    if (fstat(fd, &st)) fail("cannot inspect allowed path");
    if (namespace_root) {
        bind_path(path, access, &st);
        close(fd);
        return;
    }
    if (!S_ISDIR(st.st_mode)) {
        access &= LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_WRITE_FILE |
                  LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_TRUNCATE;
    }
    struct landlock_path_beneath_attr rule = {.allowed_access = access, .parent_fd = fd};
    if (syscall(SYS_landlock_add_rule, ruleset, LANDLOCK_RULE_PATH_BENEATH, &rule, 0))
        fail("cannot apply filesystem rule");
    close(fd);
}

static void limit_resource(int resource, const char *name, rlim_t fallback) {
    const char *value = getenv(name);
    rlim_t limit = fallback;
    if (value) {
        char *end;
        errno = 0;
        unsigned long long parsed = strtoull(value, &end, 10);
        if (errno || *value < '0' || *value > '9' || *end || !parsed || parsed >= RLIM_INFINITY) {
            errno = EINVAL;
            fail("invalid resource limit");
        }
        limit = parsed;
    }
    struct rlimit current;
    if (getrlimit(resource, &current)) fail("cannot read resource limit");
    if (current.rlim_max != RLIM_INFINITY && limit > current.rlim_max) limit = current.rlim_max;
    struct rlimit bounded = {.rlim_cur = limit, .rlim_max = limit};
    if (setrlimit(resource, &bounded)) fail("cannot bound resource");
}

static void restrict_syscalls(void) {
    scmp_filter_ctx filter = seccomp_init(SCMP_ACT_ALLOW);
    if (!filter) fail("cannot initialize seccomp");
    /* Container seccomp remains in force. These restrictions additionally protect
       the coordinating process, forbid new processes, and keep threads working. */
    const char *denied[] = {"fork", "vfork", "ptrace", "process_vm_readv", "process_vm_writev",
        "pidfd_getfd", "kill", "tkill", "pidfd_send_signal", "rt_sigqueueinfo", "rt_tgsigqueueinfo",
        "mount", "umount2", "pivot_root", "chroot", "setns", "unshare", "bpf", "perf_event_open",
        "keyctl", "add_key", "request_key", "open_by_handle_at", "io_uring_setup",
        "userfaultfd", "reboot", "kexec_load", "kexec_file_load", "init_module", "finit_module",
        "socket", "socketpair", "connect", "bind", "listen", "accept", "accept4",
        /* Output is consumed by a trusted coordinator outside this filesystem.
           Namespace confinement alone does not prevent planting escaping links. */
        "symlink", "symlinkat", "link", "linkat", "mknod", "mknodat",
        "delete_module", "setuid", "setgid", "setresuid", "setresgid", "setgroups",
        /* Landlock ABI 3 does not mediate these metadata changes. */
        "chmod", "fchmod", "fchmodat", "fchmodat2", "chown", "fchown", "lchown", "fchownat",
        "setxattr", "lsetxattr", "fsetxattr", "removexattr", "lremovexattr", "fremovexattr",
        "utime", "utimes", "utimensat", "futimesat", NULL};
    for (int i = 0; denied[i]; i++) {
        int nr = seccomp_syscall_resolve_name(denied[i]);
        if (nr != __NR_SCMP_ERROR && seccomp_rule_add(filter, SCMP_ACT_ERRNO(EPERM), nr, 0))
            fail("cannot add syscall restriction");
    }
    /* Async I/O ownership can otherwise signal a same-UID coordinator through
       inherited sockets, bypassing the restrictions on kill/tgkill. */
    const int ownership[] = {F_SETOWN, F_SETOWN_EX, F_SETSIG};
    const char *fcntl_names[] = {"fcntl", "fcntl64", NULL};
    for (int i = 0; fcntl_names[i]; i++) {
        int nr = seccomp_syscall_resolve_name(fcntl_names[i]);
        if (nr == __NR_SCMP_ERROR) continue;
        for (size_t j = 0; j < sizeof(ownership)/sizeof(ownership[0]); j++)
            if (seccomp_rule_add(filter, SCMP_ACT_ERRNO(EPERM), nr, 1,
                    SCMP_A1(SCMP_CMP_MASKED_EQ, 0xffffffffU, ownership[j]))) fail("cannot restrict async ownership");
    }
    const unsigned long ioctls[] = {FIOSETOWN, SIOCSPGRP, TIOCSTI, TIOCSPGRP, TIOCSCTTY};
    for (size_t i = 0; i < sizeof(ioctls)/sizeof(ioctls[0]); i++)
        if (seccomp_rule_add(filter, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(ioctl), 1,
                SCMP_A1(SCMP_CMP_MASKED_EQ, 0xffffffffU, ioctls[i]))) fail("cannot restrict async ioctl");
    /* Returning ENOSYS makes libc fall back to clone, whose flags are inspectable. */
    if (seccomp_rule_add(filter, SCMP_ACT_ERRNO(ENOSYS), SCMP_SYS(clone3), 0) ||
        seccomp_rule_add(filter, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(prctl), 1,
            SCMP_A0(SCMP_CMP_MASKED_EQ, 0xffffffffU, PR_SET_PDEATHSIG)) ||
        seccomp_rule_add(filter, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(clone), 1,
            SCMP_A0(SCMP_CMP_MASKED_EQ, CLONE_THREAD, 0)) ||
        seccomp_rule_add(filter, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(tgkill), 1,
            SCMP_A0(SCMP_CMP_NE, getpid())) ||
        seccomp_rule_add(filter, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(prlimit64), 1,
            SCMP_A0(SCMP_CMP_NE, 0)) || seccomp_load(filter))
        fail("cannot enforce seccomp");
    seccomp_release(filter);
}

int main(int argc, char **argv) {
    int arg = 1;
    int broker = arg < argc && !strcmp(argv[arg], "--broker");
    if (broker) arg++;
    const char *root = NULL;
    if (arg + 1 < argc && !strcmp(argv[arg], "--root")) { root = argv[arg + 1]; arg += 2; }
    const char *backend = getenv("MAVE_MEDIA_SANDBOX_BACKEND");
    if (backend && strcmp(backend, "namespace") && strcmp(backend, "landlock")) {
        errno = EINVAL; fail("invalid filesystem backend");
    }
    int abi = syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    int ruleset = -1;
    if ((backend && !strcmp(backend, "namespace")) || (abi < 3 && root && !backend)) {
        create_namespace(root);
    } else {
        if (abi < 3) { errno = ENOTSUP; fail("Landlock ABI 3 or newer is required; refusing unconfined execution"); }
        struct landlock_ruleset_attr policy = {.handled_access_fs = FS_ALL};
        ruleset = syscall(SYS_landlock_create_ruleset, &policy, sizeof(policy), 0);
        if (ruleset < 0) fail("cannot create filesystem policy");
    }
    while (arg + 1 < argc && (!strcmp(argv[arg], "--scratch") || !strcmp(argv[arg], "--read-only"))) {
        uint64_t access = FS_READ | (!strcmp(argv[arg], "--scratch") ? FS_WRITE : 0);
        allow_path(ruleset, argv[arg + 1], access, 0);
        arg += 2;
    }
    if (arg + 1 >= argc || strcmp(argv[arg], "--")) {
        errno = EINVAL;
        fail("expected [--scratch path | --read-only path ...] -- executable arguments");
    }
    arg++;
    char *executable = realpath(argv[arg], NULL);
    if (!executable) fail("cannot resolve executable");
    const char *base = strrchr(executable, '/');
    if (!base || (strcmp(base + 1, "ffmpeg") && strcmp(base + 1, "ffprobe"))) {
        errno = EINVAL;
        fail("only ffmpeg and ffprobe are supported");
    }
    allow_path(ruleset, executable, LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_EXECUTE, 0);

    const char *libraries[] = {"/lib", "/lib64", "/usr/lib", "/usr/lib64", "/usr/local/lib",
                              "/opt/ffmpeg/lib", NULL};
    for (int i = 0; libraries[i]; i++)
        allow_path(ruleset, libraries[i], FS_READ | LANDLOCK_ACCESS_FS_EXECUTE, 1);
    const char *data[] = {"/etc/ld.so.cache", "/etc/ld-musl-x86_64.path", "/etc/ld-musl-aarch64.path",
        "/etc/ssl/certs", "/etc/ssl/cert.pem", "/etc/resolv.conf", "/etc/hosts", "/etc/nsswitch.conf",
        "/etc/gai.conf", "/etc/localtime", "/etc/fonts", "/etc/alternatives", "/usr/share/fonts", "/usr/share/fontconfig",
        "/dev/urandom", "/dev/random", NULL};
    for (int i = 0; data[i]; i++) allow_path(ruleset, data[i], FS_READ, 1);
    allow_path(ruleset, "/dev/null", LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_WRITE_FILE, 0);

    const char *gpu_env = getenv("MAVE_MEDIA_SANDBOX_GPU");
    int gpu = gpu_env && !strcmp(gpu_env, "true");
    char *cuda_devices = gpu && getenv("CUDA_VISIBLE_DEVICES") ? strdup(getenv("CUDA_VISIBLE_DEVICES")) : NULL;
    if (gpu) {
        allow_path(ruleset, "/usr/local/nvidia", FS_READ | LANDLOCK_ACCESS_FS_EXECUTE, 1);
        allow_path(ruleset, "/usr/local/cuda", FS_READ | LANDLOCK_ACCESS_FS_EXECUTE, 1);
        glob_t devices = {0};
        int result = glob("/dev/nvidia*", 0, NULL, &devices);
        if (result != 0 && result != GLOB_NOMATCH) fail("cannot enumerate GPU devices");
        for (size_t i = 0; i < devices.gl_pathc; i++)
            allow_path(ruleset, devices.gl_pathv[i], FS_READ | LANDLOCK_ACCESS_FS_WRITE_FILE, 0);
        globfree(&devices);
    }

    limit_resource(RLIMIT_AS, "MAVE_MEDIA_MAX_ADDRESS_BYTES", 16ULL * 1024 * 1024 * 1024);
    limit_resource(RLIMIT_FSIZE, "MAVE_MEDIA_MAX_FILE_BYTES", 64ULL * 1024 * 1024 * 1024);
    limit_resource(RLIMIT_CPU, "MAVE_MEDIA_MAX_CPU_SECONDS", 7200);
    struct rlimit no_core = {0, 0};
    if (setrlimit(RLIMIT_CORE, &no_core)) fail("cannot disable core dumps");
    struct __user_cap_header_struct header = {.version = _LINUX_CAPABILITY_VERSION_3};
    struct __user_cap_data_struct capabilities[2] = {{0}, {0}};
    pid_t parent = getppid();
    if (namespace_root && (mount(NULL, namespace_root, NULL, MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NODEV, NULL) ||
        chroot(namespace_root))) fail("cannot seal private filesystem");
    if (syscall(SYS_capset, &header, capabilities) ||
        prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) || prctl(PR_SET_PDEATHSIG, SIGKILL))
        fail("cannot drop privileges");
    if (getppid() != parent) return 126;
    if (chdir("/") || (!namespace_root && syscall(SYS_landlock_restrict_self, ruleset, 0)))
        fail("cannot enforce filesystem policy");
    if (ruleset >= 0) close(ruleset);
    /* No credentials, proxy settings, preload hooks, or application configuration
       are inherited by the parser. Signed input URLs still exist in its argv. */
    if (clearenv() || setenv("PATH", "/opt/ffmpeg/bin:/usr/bin:/bin", 1) ||
        setenv("LANG", "C", 1) || setenv("HOME", "/nonexistent", 1))
        fail("cannot clear environment");
    if (gpu && setenv("LD_LIBRARY_PATH", "/usr/local/nvidia/lib:/usr/local/nvidia/lib64", 1))
        fail("cannot configure GPU libraries");
    if (cuda_devices && setenv("CUDA_VISIBLE_DEVICES", cuda_devices, 1)) fail("cannot configure GPU");
    free(cuda_devices);
    if (broker && setenv("LD_PRELOAD", "/usr/local/lib/mave-media-network.so", 1))
        fail("cannot configure media transport");
    if (syscall(SYS_close_range, broker ? 4 : 3, ~0U, 0)) fail("cannot close inherited descriptors");
    restrict_syscalls();
    execv(executable, &argv[arg]);
    fail("cannot execute media tool");
}

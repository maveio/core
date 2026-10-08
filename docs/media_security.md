# Processing untrusted media

No MIME check, signature test, antivirus scan, or successful FFprobe run proves
that an upload is free of exploit payloads. Keep validating uploads, but assume
that a decoder can be compromised. These controls reduce the resulting access;
they do not certify a file as safe or protect against every kernel vulnerability.

## Parser boundary

The Core development/release images and CPU/GPU encoder images set
`MAVE_MEDIA_SANDBOX=required`. Every Core FFmpeg/FFprobe invocation, including
inline inspection, and every external encoder invocation passes through
`mave-media-broker` and `mave-media-sandbox`. The same implementation serves
Core/SaaS, FLAME, and the CPU/GPU boosters. It needs no privileged container,
Docker socket, or added host capabilities.

The launcher:

- Removes inherited credentials, proxy variables, and dynamic-loader overrides.
  The trusted broker retains input URLs and storage headers; the parser only sees
  per-command handles such as `http://127.0.0.1/0`.
- Grants filesystem access to the referenced job's scratch directory or frame
  file, the selected media executable, runtime libraries, fonts, CA certificates,
  DNS configuration, the bundled play-button image and minimal devices. It cannot read the application release,
  source checkout, mounted secrets, `/proc` environments or other jobs' files.
  Do not mount secrets beneath the permitted library/configuration paths.
- Drops capabilities, enables `no_new_privs`, closes inherited descriptors except
  stdin/stdout/stderr and one connection to the broker, disables core dumps, and
  kills the child if its parent dies.
- Blocks native network sockets/connects, new processes, inspection of other processes, cross-process signals,
  namespace/mount changes and selected dangerous kernel interfaces. Codec threads
  still work. Container seccomp remains an additional restriction.
- Bounds virtual address space, CPU time and output file size. Core and booster
  command diagnostics retain at most 1 MiB. Existing wall-clock deadlines remain.

Input protocols are limited to `file,http,https,tcp,tls,crypto,pipe`. A step's
explicit, stricter protocol list is preserved. These FFmpeg flags are defense
in depth, not an OS boundary after an exploit.

The same C launcher is built from
`deploy/encoding-booster/encoder/sandbox/media_sandbox.c` in all images. Failure
to install a restriction exits with status 126 before the parser starts. There
is no automatic unconfined fallback. Filesystem isolation uses Landlock ABI 3+
when available. Otherwise it requires unprivileged user/mount namespaces, a
private tmpfs root containing only allowed bind mounts, chroot, capability
dropping, and seccomp. If either required setup fails, no parser starts. The
namespace backend exists for userspace kernels such as gVisor that do not expose
Landlock. Check the actual provider/runtime; upstream syscall support is not
proof that a provider permits namespaces. Kubernetes RuntimeDefault can retain
its namespace restrictions because its normal path uses Landlock.

`MAVE_MEDIA_SANDBOX_BACKEND=landlock` or `namespace` can require one filesystem
backend explicitly; unset selects based on Landlock support. Neither value
disables the network/process restrictions.

Native macOS development defaults to `MAVE_MEDIA_SANDBOX=disabled`; it still
clears subprocess credentials and bounds diagnostics but has **no OS parser
sandbox**. Use the Docker development image for untrusted uploads. An explicit
`disabled` override exists for operators providing an equivalent external
boundary; do not use it merely to suppress an unsupported-kernel error.

| Setting | Default | Meaning |
| --- | --- | --- |
| `MAVE_MEDIA_MAX_ADDRESS_BYTES` | 17179869184 | Per-process virtual address space (16 GiB), not RSS |
| `MAVE_MEDIA_MAX_FILE_BYTES` | 68719476736 | Maximum size of one output file (64 GiB) |
| `MAVE_MEDIA_MAX_CPU_SECONDS` | 7200 | CPU seconds summed over the process's threads |
| `MAVE_MEDIA_SANDBOX_GPU` | unset; `true` in GPU image | Allows NVIDIA devices and driver libraries |

Limits must be positive integers; they never raise an inherited hard limit.
Userspace kernels can implement only part of Linux rlimit enforcement; retain
provider/cgroup CPU, memory, task, scratch and wall-clock limits as well.
Size them for the largest supported media. GPU drivers may reserve substantial
virtual address space; validate the memory setting on the actual GPU nodes.
GPU device access exposes the GPU driver to decoder processes and requires its
own patching and isolation. Never share a GPU worker with sensitive workloads.

## Docker self-hosting

The bundled Core service runs with a read-only root filesystem, all capabilities
dropped, no privilege escalation, and writable, non-executable `/tmp` scratch.
Its configurable defaults are 4 CPUs, 8 GiB memory, 2048 tasks, and 8 GiB tmpfs:
`MAVE_CORE_CPU_LIMIT`, `MAVE_CORE_MEMORY_LIMIT`, `MAVE_CORE_PIDS_LIMIT`, and
`MAVE_CORE_SCRATCH_BYTES`. Scratch consumes memory; size both limits together.
Large inputs or parallel renditions can require larger limits. A per-file limit
alone is not an aggregate disk limit.

The single-container installation still shares a kernel and resource budget
between Core and media commands. `FLAME.LocalBackend` is scheduling in the same
BEAM VM, not a separate security boundary. The launcher confines the native
parser even on that path; separate worker nodes provide additional isolation.

## Kubernetes

Generated FLAME runner pods default to the Restricted Pod Security controls:
non-root UID/GID 65534, no privilege escalation, dropped capabilities and
`RuntimeDefault` seccomp. They have a read-only root filesystem and a bounded
`emptyDir` mounted at `/tmp` and `/var/tmp`. Service-account tokens are never
mounted. Defaults are 4 CPUs, 8 GiB memory, 24 GiB ephemeral-storage limit and
20 GiB scratch. Existing `cpu_limit`, `memory_limit`, and
`ephemeral_storage_limit` backend options override the resource limits.
`run_as_user`, `run_as_group`, `scratch_size_limit` and optional
`runtime_class_name` backend options support deployment-specific policy.

Apply equivalent pod settings to Core workers that inspect media inline and to
external encoder deployments; changing the FLAME manifest does not configure
those deployments. Set namespace quotas, admission policy, kubelet `podPidsLimit`,
CPU/memory/ephemeral-storage limits and a bounded `/var/tmp` volume for boosters.
An `emptyDir.sizeLimit` can cause eviction rather than immediate write rejection;
monitor node disk pressure too. Keep worker service accounts unprivileged and
place workers on dedicated nodes or a stronger compatible runtime where feasible.

### Streaming without parser network authority

A fresh broker process owns the allowed source URL/header table for each media
command. It rewrites direct inputs and trusted concat manifests to local HTTP
handles. FFmpeg's small dynamic transport adapter requests connected Unix
sockets over FD 3; each socket serves only this fixed HTTP interface. There is
no listening TCP port. The broker supports GET/HEAD and single byte ranges for
seeking, strips parser-supplied headers, rejects redirects and mutations, and
never returns upstream error bodies or cookies. Output still goes through
stdout or job files to the existing trusted upload code; whole inputs are not
staged on disk.

The adapter is not a security boundary: native socket/connect syscalls are
blocked by seccomp even if compromised code bypasses or unloads the adapter.
The broker does not accept new target URLs from the parser. Filesystem and
process restrictions protect the broker's credentials and other jobs. Async
I/O ownership changes are blocked too, since these can signal another process
without calling `kill`. The broker and child terminate with the command, so
warm booster reuse does not retain a parser from a completed command.

The source table comes from trusted application code. URL validation and
storage authorization in that code remain necessary; the broker does not
validate media content or confer legitimacy on arbitrary caller-supplied URLs.
Remote playlists that request unlisted resources are intentionally rejected.
Keep application/booster network policies scoped to storage and required
control-plane endpoints as additional protection of the trusted coordinator.
A native decoder compromise alone does not gain that coordinator's network
access. No cluster-wide NetworkPolicy is deployed by this change.

### Output handoff

Parser output remains untrusted. Both filesystem backends prohibit creating
symbolic links, hard links and special files through the shared syscall filter.
This also prevents a parser from planting a link for a trusted process to follow
after leaving the sandbox. Ordinary file creation and HLS `.tmp` renames remain
available.

The booster opens output relative to trusted temporary roots, pins and verifies
each descendant directory, refuses symlink leaves, and checks the opened file is
regular with a single link. ZIP, HLS uploads and seekable frame responses read
that descriptor. Upload retries retain the same descriptor rather than reopening
a parser-controlled pathname; collection-time metadata is not authorization to
read a later replacement. These controls preserve uploads of completed HLS
segments while encoding continues.

## Publication and updates

This hardening preserves the existing early-original-playback and storage
contracts. Originals can still be publicly served during processing; parser
confinement does not sanitize originals or generated media for viewers. A
quarantine-only publication policy needs a separate coordinated change to upload
ACLs, signed source access, manifests and browser behavior. Keep media on a
separate origin from authenticated application pages.

Core's release image and both CPU/GPU encoders pin FFmpeg 9.0.2. Core verifies
the upstream release signer; the encoder images pin the checksum of that verified
archive. Development images use their distribution's patched packages.
Rebuild and roll out images when FFmpeg, decoder libraries, kernels or GPU drivers
receive security fixes. Scanning or patching does not eliminate unknown bugs.

## Verification

Run `sh deploy/encoding-booster/encoder/sandbox/test.sh` inside a Linux development
image with `cc`, `libseccomp-dev`, FFmpeg and FFprobe. Run it as non-root with
capabilities dropped too. It checks secret/environment denial, write/truncation
and symlink escapes, process restrictions, working codec threads, unsupported
kernel failure, native socket denial, and real encode/probe/HLS operations.
Run `sh deploy/encoding-booster/encoder/sandbox/broker_test.sh` with the installed
broker, launcher, adapter and Python 3 to exercise native bypass attempts,
credential/parent-memory denial, streaming, seeking, remote concat and HLS.
Repeat both scripts with `MAVE_MEDIA_SANDBOX_BACKEND=namespace` on a disposable
runtime that permits unprivileged namespace creation. The broker Go module also
has focused HTTP authority, credential, range and redirect tests. Run Core tests, the encoder
Go suite and the isolated self-hosted smoke test as described in CONTRIBUTING.
Validate GPU encodes and the selected runtime/CNI on staging nodes before rollout.

References: [Landlock](https://docs.kernel.org/userspace-api/landlock.html),
[seccomp](https://docs.kernel.org/userspace-api/seccomp_filter.html),
[Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/),
[FFmpeg releases](https://ffmpeg.org/download.html).

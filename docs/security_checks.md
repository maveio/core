# Security checks

Pull requests run the complete test suite against disposable PostgreSQL,
ClickHouse and MinIO services, with Elixir 1.19.4 / OTP 28.2 and FFmpeg.
CI and the shared Core/SaaS asset builder use Node 24.21.0 LTS; the official
checkout/setup-node/cache Actions use Node 24 as well. Production Core, CPU and
GPU images use FFmpeg 9.0.2. The GPU build retains Ubuntu 24.04's NVIDIA headers
to preserve the existing driver baseline.
Compilation warnings, formatting, Credo, dependency advisories, high-severity
npm advisories and newly committed secrets fail their respective jobs. Scanner
output redacts secret values. Scheduled jobs scan the current tree and locally
built Core/CPU/GPU images, including unfixed high/critical OS and native-library
advisories. Images are never published or deployed by these workflows.

Actions are pinned to reviewed commit SHAs. PR jobs have read-only repository
permissions, do not persist checkout credentials, and receive no production
secrets. Review dependency, action and scanner pins when updating the runtime.

The MinIO server/client used by CI and Compose are built from pinned upstream
source releases in `deploy/minio/Dockerfile`, with Go module checksum validation.
They do not depend on the withdrawn community registry images. The application
runtime uses Ubuntu 26.04 independently of the Debian-based Hexpm builder and
installs available OS updates during the build. FFmpeg is built against that
same Ubuntu runtime base. This avoids the unfixed runtime-package advisories in
Debian without suppressing them. Unfixed advisories remain failures; an updated
base alone does not guarantee a clean scan.

## Sobelow exclusions

The existing security alias retains three framework-level exclusions. They are
not exemptions from review, and their corresponding regression tests run in CI:

| Exclusion | Reason | Regression coverage |
| --- | --- | --- |
| `Config.CSWH` | The public upload socket deliberately accepts arbitrary component origins; a current writable-key JWT authorizes the connection and channel. | `test/mave_core_web/channels/upload_socket_test.exs` |
| `Config.CSP` | Browser CSP is assembled by the `BrowserSecurity` plug at runtime. | `test/mave_core_web/browser_security_test.exs` |
| `Config.CSRF` | Public API requests use explicit API keys; session-authenticated flow writes separately enforce CSRF in `FlowAdminAuth`. | `test/mave_core_web/controllers/api/flow/runs_controller_test.exs` |

Review these assumptions whenever routes, session usage, socket authentication,
or component loading change. Function-local `sobelow_skip` annotations remain
visible in code review; do not add broad exclusions to make CI pass.

Gitleaks permits the committed synthetic TLS test key by exact path and the two
public Phoenix development/test cookie keys by both exact value and path. Add
new exceptions only with an explanation proving the value is a public fixture.

## Operation and rollback

Configure branch protection to require the `test` and `audit` checks after the
first successful hosted run. Repository workflows cannot enforce branch
protection themselves. Inspect scheduled failures and patch or replace affected
images before releasing. Do not treat a passing scan as proof of safety.

These workflows require no application migration. Reverting them removes the
automated checks without changing runtime behavior. Historical vulnerabilities
and baseline test failures must be fixed in focused PRs rather than hidden with
`continue-on-error` or expanded ignore lists.

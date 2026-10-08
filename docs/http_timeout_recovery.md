# HTTP timeout recovery

Two independent client defects were reproduced while investigating interrupted
media processing on 2026-09-30.

## Abandoned HTTP/1 responses

Mint 1.11 changed receive timeouts to leave the socket open. Finch 0.23 returned
that open connection to the pool even though the timed-out request's response
was still outstanding. The next checkout received events with the old request
reference, causing a `CaseClauseError` in `Finch.HTTP1.Conn.receive_response/8`.
Observed status events included 206 and 409; partial response bodies also
reproduce the defect. These exceptions bypass ordinary transport-error retries
and can fail a required flow step and cancel sibling work.

Finch 0.24.0 closes failed HTTP/1 requests before returning to the pool. It retains
keep-alive reuse for successful requests and Mint's current security fixes.
The [upstream release](https://github.com/sneako/finch/releases/tag/v0.24.0)
includes the fix in PR #397. Core requires this version and both Core and SaaS
lock it; no local fork is needed.

## Signed S3 retries

Req retries re-run request steps using the prior request's headers. Re-signing
without removing signer-owned headers produced repeated `x-amz-date` and
`x-amz-content-sha256` values. This provides a reproducible explanation for a
transport timeout being followed by a signature rejection rather than recovery.

Both object and service request builders now clear signer-owned headers before
each signing pass. Other headers, credentials, request bodies and existing retry
budgets remain in place. Existing fresh-request PUT/HEAD retry loops are retained.
Tests verify the resulting signature for object reads and bucket checks after
a transport timeout, not merely the final HTTP status.

## Verification and remaining operational risks

`test/mave_core/http_connection_reuse_test.exs` exercises real TCP sockets with
delayed status lines and bodies, plus successful connection reuse.
`test/mave_core/media/storage_test.exs` covers retry signing and storage behavior.

Validation with the project's Elixir 1.19.4/OTP 28 toolchain passed all 1,117
Core tests and 436 SaaS tests against isolated PostgreSQL, ClickHouse and MinIO
services, using official Finch 0.24.0 and Mint 1.11.0. This includes the real-TCP
regressions, signed retries, storage integration and broader booster/retry tests.
The SaaS `precommit` alias passed both Core and SaaS compilation with warnings
as errors and the shared dependency-lock check. Strict Credo and security
enforcement checks also passed for both applications.

These fixes prevent two failure cascades; they do not eliminate provider latency
or legitimate permission errors. Bucket policy HTTP 400 responses require their
own provider-policy diagnosis and should not be treated as transient by default.

Flow completion still performs storage publication while holding a database
transaction and asset lock. A sufficiently slow publication can exceed the
database checkout timeout. Moving publication to a durable, serialized outbox
is separate work: it must preserve replacement-version ordering and must not
mark an upload private before its durable manifest is published. Simply removing
the asset lock or raising retries would not preserve those guarantees.

Deploying the fix requires rebuilt application images, including FLAME runners;
it does not require an FFmpeg/booster image change or database migration. Release
inspection should report Finch `0.24.0`. Existing terminal flow failures
are not automatically reset by the patch; any operator retry should preserve
succeeded steps and their artifacts.

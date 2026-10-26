# Security checks

Pull requests run tests, formatting, compilation, Credo, dependency audits and
secret scanning. Scheduled and image-related checks also scan built images for
OS and native-library advisories. See the [workflows](../.github/workflows) and
[dependency configuration](../mix.exs) for current versions and check definitions.
These checks complement code review; a passing scan is not proof of safety.

Run local checks as described in [CONTRIBUTING](../CONTRIBUTING.md#validate-a-change).
Report vulnerabilities using [SECURITY.md](../SECURITY.md).

## Sobelow exclusions

The following exclusions require regression coverage and review when their
underlying contracts change:

| Exclusion | Reason | Coverage |
| --- | --- | --- |
| `Config.CSWH` | Upload components use arbitrary origins; writable-key JWTs authorize their sockets. | [Upload socket tests](../test/mave_core_web/channels/upload_socket_test.exs) |
| `Config.CSP` | `BrowserSecurity` assembles the browser policy at runtime. | [Browser security tests](../test/mave_core_web/browser_security_test.exs) |
| `Config.CSRF` | Public API requests use keys; session-authenticated flow writes enforce CSRF separately. | [Flow controller tests](../test/mave_core_web/controllers/api/flow/runs_controller_test.exs) |

Do not broaden exclusions or suppress findings merely to make CI pass. New
secret-scanner exceptions must identify a specific public test fixture, not a
class of credentials. Keep function-local exceptions visible in code review.

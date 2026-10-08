# Security

## Reporting a vulnerability

Report suspected vulnerabilities privately to [cert@mave.io](mailto:cert@mave.io).
Follow [Mave's responsible-disclosure policy](https://www.mave.io/docs/responsible-disclosure/)
for the disclosure process and the conditions for testing Mave-operated systems.
Do not post credentials, customer data, or exploit details in public issues or
pull requests.

Include the affected Core version or commit, relevant configuration with secrets
removed, required access, reproduction steps, expected and actual behaviour, and
the potential impact. Prefer a minimal reproduction using your own installation
and synthetic data.

This file does not authorize testing other people's installations or extend
response-time, reward, or support commitments to third-party deployments.

## Scope and trust boundaries

This policy covers the Core application and the self-hosted distribution in this
repository: dashboard and API access, bootstrap and login, uploads and hooks,
media processing, storage access, webhook delivery, and analytics.

Accounts, API clients, uploaded media, remote URLs, webhook destinations, and
browser events can supply untrusted input. Administrators of a self-hosted
installation control its configuration and infrastructure. Trust in those
administrators does not imply trust in every user or API key.

Vulnerabilities in Core remain in scope whether observed in a self-hosted
installation or through a managed service.

## Security expectations

- Authorization must preserve space isolation and API-key access levels.
- Login, invitation, bootstrap, and upload credentials must be validated for
  their intended purpose; bootstrap must not allow an unrelated second owner.
- Upload hooks must authenticate requests and validate current upload authority.
- Private source objects, account data, and secrets must not become public merely
  because processed media is served publicly.
- Untrusted media, URLs, paths, and event payloads must not bypass process,
  network, storage, or resource limits.

Reports should explain realistic reachability, prerequisites, and impact.
Passing tests or a scanner's configured exclusions do not establish that a
control is safe. Disclosure-program eligibility is not a blanket exclusion from
reviewing a security defect in Core.

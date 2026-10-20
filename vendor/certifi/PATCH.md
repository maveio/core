# Temporary certificate distrust

This directory vendors the `certifi` Hex package version 2.17.0. Its Erlang
implementation and public API are unchanged. The application version is marked
`2.17.0-mave.1` to distinguish this build from the upstream release.

The sole trust-store change removes **emSign ECC Root CA - G3** (SHA-256
`86A1ECBA089C4A8D3BBE2734C612BA341D813E043CF9E8A862CD5C57A36BBE6B`)
following the October 2026 intermediate-key compromise:
<https://emudhra.we-have-a-problem.com/>.

The other affected roots, including AAA Certificate Services, are already absent
from this upstream bundle. All other certificates are preserved. The original
BSD license and the Mozilla bundle's license notice are retained.

Vendoring is necessary because `certifi_pt` embeds the bundle into
`certifi:cacerts/0` during compilation. Editing a PEM file after compilation or
changing only an HTTP client's configuration does not protect every caller.
Both the compiled list and `certifi:cacertfile/0` must use the filtered bundle.

Remove this override once an upstream release contains the same distrust and
passes `test/mave_core/certificate_trust_test.exs`. Consuming applications that
also depend directly on HTTP clients may need the same top-level path override.
Rebuild releases and restart them; existing processes retain their old trust
stores and connections.

# External TLS trust

This public Mozilla CA bundle is generated from Alpine ca-certificates
20261020-r0 by `../tusd/Dockerfile`. It excludes the emSign ECC Root CA - G3
and Comodo AAA Services trust anchors used by compromised intermediate CAs.
There are no private certificates or keys in this file.

The Compose mounts deliberately set both SSL_CERT_FILE and SSL_CERT_DIR:
Go also loads certificate directories, so changing only the file can leave
removed roots reachable. ClickHouse uses an explicit OpenSSL client CA file.
Regenerate and test ordinary HTTPS and the incident test chains before updating.

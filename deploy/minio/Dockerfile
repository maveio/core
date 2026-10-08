# The community images are no longer publicly pullable. Build the same pinned
# releases from upstream source; Go's checksum database verifies module contents.
FROM golang:1.25.13-alpine3.23 AS server-build
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
RUN go install -trimpath github.com/minio/minio@v0.0.0-20250907161309-07c3a429bfed

FROM golang:1.25.13-alpine3.23 AS client-build
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
RUN go install -trimpath github.com/minio/mc@v0.0.0-20250813083541-7394ce0dd2a8

FROM alpine:3.23 AS base
RUN apk add --no-cache ca-certificates curl

FROM base AS client
LABEL org.opencontainers.image.source="https://github.com/minio/mc" \
      org.opencontainers.image.revision="7394ce0dd2a80935aded936b09fa12cbb3cb8096"
COPY --from=client-build /go/bin/mc /usr/bin/mc
COPY --from=client-build /go/pkg/mod/github.com/minio/mc@v0.0.0-20250813083541-7394ce0dd2a8/LICENSE /licenses/mc-LICENSE
ENTRYPOINT ["/usr/bin/mc"]

FROM base AS server
LABEL org.opencontainers.image.source="https://github.com/minio/minio" \
      org.opencontainers.image.revision="07c3a429bfed433e49018cb0f78a52145d4bedeb"
COPY --from=server-build /go/bin/minio /usr/bin/minio
COPY --from=server-build /go/pkg/mod/github.com/minio/minio@v0.0.0-20250907161309-07c3a429bfed/LICENSE /licenses/minio-LICENSE
EXPOSE 9000 9001
ENTRYPOINT ["/usr/bin/minio"]
CMD ["server", "/data"]

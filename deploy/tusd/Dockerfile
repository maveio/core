# Preserve the upstream upload API while updating its TLS implementation.
FROM golang:1.27.3-alpine3.23@sha256:7fd63dd7c37f5ddaef15bd8fd3f3e4f90f0d50cd9cae255c7cf73887a494d8df AS build
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
RUN go install -trimpath -ldflags="-s -w -X github.com/tus/tusd/v2/cmd/tusd/cli.VersionName=v2.5.0 -X github.com/tus/tusd/v2/cmd/tusd/cli.GitCommit=c5d5b0a0422db85e9aa41b0cfa6e34926d25d224" github.com/tus/tusd/v2/cmd/tusd@v2.5.0

FROM alpine:3.23@sha256:21f3e19bafab57a9ff7aa9dd571dac72f868370472c10f450cc0416cc1aca553
RUN apk add --no-cache ca-certificates=20261020-r0 \
  && sed -i -e '/^mozilla\/emSign_ECC_Root_CA_-_G3.crt$/s/^/!/' \
    -e '/^mozilla\/Comodo_AAA_Services_root.crt$/s/^/!/' /etc/ca-certificates.conf \
  && update-ca-certificates --fresh \
  && addgroup -g 1000 -S tusd && adduser -u 1000 -S -G tusd tusd \
  && mkdir -p /srv/tusd-data /srv/tusd-hooks && chown -R tusd:tusd /srv/tusd-data /srv/tusd-hooks
COPY --from=build /go/bin/tusd /usr/local/bin/tusd
COPY --from=build /go/pkg/mod/github.com/tus/tusd/v2@v2.5.0/LICENSE.txt /licenses/tusd-LICENSE.txt
WORKDIR /srv/tusd-data
USER tusd
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/tusd"]
CMD ["--hooks-dir", "/srv/tusd-hooks"]

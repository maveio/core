# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian
# instead of Alpine to avoid DNS resolution issues in production.
#
# https://hub.docker.com/r/hexpm/elixir/tags?name=ubuntu
# https://hub.docker.com/_/ubuntu/tags
#
# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the build image
#   - https://hub.docker.com/_/ubuntu/tags?name=26.04 - for the release image
#   - https://pkgs.org/ - resource for finding needed packages
#   - Ex: docker.io/hexpm/elixir:1.19.4-erlang-28.2-debian-trixie-20251208-slim
#
ARG ELIXIR_VERSION=1.19.4
ARG OTP_VERSION=28.2
ARG DEBIAN_VERSION=trixie-20251208-slim
ARG FFMPEG_VERSION=9.0.2
ARG VERSION=dev
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
# Ubuntu's newer glibc runs the Debian-built release while providing fixes for
# runtime packages still affected in Debian. Build FFmpeg against this same base.
ARG RUNNER_IMAGE="docker.io/ubuntu:26.04@sha256:da6fc2be547864451aa253836dd926da33623312df4a9a243e35dc877c378a78"

FROM node:24.21.0-bookworm-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6 AS node_build

FROM golang:1.25.13-alpine3.23 AS media_broker_build
WORKDIR /src
COPY deploy/encoding-booster/encoder/sandbox/broker/ ./
RUN go test ./... && CGO_ENABLED=0 go build -trimpath -o /mave-media-broker .

FROM ${RUNNER_IMAGE} AS ffmpeg_builder

ARG FFMPEG_VERSION

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    gnupg \
    libarchive-tools \
    libdav1d-dev \
    libgnutls28-dev \
    libmp3lame-dev \
    libopus-dev \
    libsvtav1enc-dev \
    libwebp-dev \
    libx264-dev \
    libx265-dev \
    nasm \
    pkg-config \
    xz-utils \
    zlib1g-dev \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

WORKDIR /tmp/ffmpeg

# Bind verification to the pinned release key, even if the downloaded key bundle contains others.
# bsdtar also supports extracting this archive under Docker's amd64 emulation.
RUN curl -fsSLo /tmp/ffmpeg.tar.xz "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
  && curl -fsSLo /tmp/ffmpeg.tar.xz.asc "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz.asc" \
  && curl -fsSLo /tmp/ffmpeg-devel.asc "https://ffmpeg.org/ffmpeg-devel.asc" \
  && gpg --batch --import /tmp/ffmpeg-devel.asc \
  && gpg --batch --assert-signer FCF986EA15E6E293A5644F10B4322F04D67658D8 \
    --verify /tmp/ffmpeg.tar.xz.asc /tmp/ffmpeg.tar.xz \
  && bsdtar -xf /tmp/ffmpeg.tar.xz -C /tmp/ffmpeg --strip-components=1

RUN ./configure \
    --prefix=/opt/ffmpeg \
    --disable-debug \
    --disable-doc \
    --disable-ffplay \
    --enable-gpl \
    --enable-gnutls \
    --enable-libdav1d \
    --enable-libmp3lame \
    --enable-libopus \
    --enable-libsvtav1 \
    --enable-libwebp \
    --enable-libx264 \
    --enable-libx265 \
  && make -j"$(nproc)" \
  && make install \
  && /opt/ffmpeg/bin/ffmpeg -version | grep "ffmpeg version ${FFMPEG_VERSION}" \
  && /opt/ffmpeg/bin/ffprobe -version | grep "ffprobe version ${FFMPEG_VERSION}" \
  && /opt/ffmpeg/bin/ffmpeg -hide_banner -encoders | grep -q 'libx264' \
  && /opt/ffmpeg/bin/ffmpeg -hide_banner -encoders | grep -q 'libx265' \
  && /opt/ffmpeg/bin/ffmpeg -hide_banner -encoders | grep -q 'libsvtav1' \
  && /opt/ffmpeg/bin/ffmpeg -hide_banner -encoders | grep -q 'libmp3lame' \
  && /opt/ffmpeg/bin/ffmpeg -hide_banner -encoders | grep -q 'libopus' \
  && /opt/ffmpeg/bin/ffmpeg -hide_banner -encoders | grep -q 'libwebp' \
  && mkdir -p /opt/ffmpeg/share/licenses /opt/ffmpeg/share/source \
  && cp COPYING* LICENSE.md /opt/ffmpeg/share/licenses/ \
  && cp /tmp/ffmpeg.tar.xz "/opt/ffmpeg/share/source/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
  && cp /tmp/ffmpeg.tar.xz.asc "/opt/ffmpeg/share/source/ffmpeg-${FFMPEG_VERSION}.tar.xz.asc" \
  && cp ffbuild/config.mak config.h /opt/ffmpeg/share/source/ \
  && /opt/ffmpeg/bin/ffmpeg -buildconf > /opt/ffmpeg/share/source/buildconf.txt 2>&1 \
  && rm -rf /tmp/ffmpeg /tmp/ffmpeg.tar.xz /tmp/ffmpeg.tar.xz.asc /tmp/ffmpeg-devel.asc /root/.gnupg

FROM ${BUILDER_IMAGE} AS builder_base

# install build dependencies
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git cargo rustc libseccomp-dev \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Use the same supported Node LTS as CI instead of Debian's older Node package.
COPY --from=node_build /usr/local/bin/node /usr/local/bin/node
COPY --from=node_build /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
  && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
  && node --version && npm --version

# prepare build dir
WORKDIR /app

# Disable Erlang JIT (Fixes QEMU crash during cross-compile)
ENV ERL_AFLAGS="+JMsingle true"

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# Build the launcher once for every image consuming the shared stages.
COPY deploy/encoding-booster/encoder/sandbox/media_sandbox.c /tmp/media_sandbox.c
COPY deploy/encoding-booster/encoder/sandbox/network.c /tmp/media_network.c
COPY --from=media_broker_build /mave-media-broker /usr/local/bin/mave-media-broker
RUN cc -O2 -Wall -Wextra -Werror -D_FORTIFY_SOURCE=2 -fstack-protector-strong \
    /tmp/media_sandbox.c -lseccomp -o /usr/local/bin/mave-media-sandbox \
    && cc -O2 -Wall -Wextra -Werror -fPIC -shared /tmp/media_network.c -pthread \
      -o /usr/local/lib/mave-media-network.so

FROM builder_base AS builder

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY assets/package.json assets/package-lock.json assets/
RUN mix assets.setup

COPY priv priv
COPY lib lib
RUN mix ua_inspector.download --force

# Compile the release
RUN mix compile

COPY assets assets

# compile assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# Preserve upstream notices before discarding build dependencies.
COPY LICENSE THIRD_PARTY_NOTICES.md Dockerfile ./
COPY deploy/licenses deploy/licenses
RUN sh deploy/licenses/collect.sh /app /opt/mave-licenses

# Compose runs Mix from the mounted checkout and also needs media tools at runtime.
FROM builder_base AS development

ENV MIX_ENV="dev" MAVE_MEDIA_SANDBOX="required"

RUN apt-get update \
  && apt-get install -y --no-install-recommends ffmpeg procps inotify-tools \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* \
  && ffmpeg -version \
  && ffprobe -version \
  && ffmpeg -hide_banner -encoders | grep -q 'libx264'

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE} AS runtime_base

ARG FFMPEG_VERSION
RUN apt-get update \
  && apt-get upgrade -y --no-install-recommends \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    libdav1d7 \
    libgnutls30t64 \
    libmp3lame0 \
    libncurses6 \
    libseccomp2 \
    libnuma1 \
    libopus0 \
    libsharpyuv0 \
    libstdc++6 \
    libsvtav1enc2 \
    libwebp7 \
    libwebpmux3 \
    libx264-165 \
    libx265-215 \
    locales \
    openssl \
    procps \
    tini \
    zlib1g \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

COPY --from=ffmpeg_builder /opt/ffmpeg /opt/ffmpeg
COPY --from=builder_base /usr/local/bin/mave-media-sandbox /usr/local/bin/mave-media-sandbox
COPY --from=builder_base /usr/local/bin/mave-media-broker /usr/local/bin/mave-media-broker
COPY --from=builder_base /usr/local/lib/mave-media-network.so /usr/local/lib/mave-media-network.so

ENV PATH="/opt/ffmpeg/bin:${PATH}" MAVE_MEDIA_SANDBOX="required"

RUN ffmpeg -version | grep "ffmpeg version ${FFMPEG_VERSION}" \
  && ffprobe -version | grep "ffprobe version ${FFMPEG_VERSION}"

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"

FROM runtime_base AS final

ARG VERSION
ARG VCS_REF
ARG BUILD_DATE

LABEL org.opencontainers.image.title="Mave Core" \
  org.opencontainers.image.description="Self-hosted Mave video platform" \
  org.opencontainers.image.source="https://github.com/maveio/core" \
  org.opencontainers.image.licenses="AGPL-3.0-or-later" \
  org.opencontainers.image.version="${VERSION}" \
  org.opencontainers.image.revision="${VCS_REF}" \
  org.opencontainers.image.created="${BUILD_DATE}"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/mave_core ./
COPY --from=builder /opt/mave-licenses /app/licenses
COPY --from=ffmpeg_builder /opt/ffmpeg/share/licenses/COPYING.GPLv3 /app/licenses/data/device-detector/COPYING

USER nobody

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 \
  CMD ["/app/bin/ready"]

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/bin/server"]

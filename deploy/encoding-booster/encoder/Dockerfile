FROM golang:1.25.13-alpine3.23 AS app-build
WORKDIR /src
COPY go.mod *.go ./
COPY assets/play.png ./assets/play.png
RUN go test ./... \
    && CGO_ENABLED=0 GOOS=linux go build \
      -trimpath -ldflags="-s -w -buildid=" -o /out/encoder .

FROM app-build AS broker-build
COPY sandbox/broker /broker
WORKDIR /broker
RUN go test ./... && CGO_ENABLED=0 go build -trimpath -o /mave-media-broker .

FROM alpine:3.23 AS sandbox-build
RUN apk add --no-cache build-base linux-headers libseccomp-dev
COPY sandbox/media_sandbox.c /src/media_sandbox.c
COPY sandbox/network.c /src/network.c
RUN cc -O2 -Wall -Wextra -Werror -D_FORTIFY_SOURCE=2 -fstack-protector-strong \
      /src/media_sandbox.c -lseccomp -o /mave-media-sandbox \
    && cc -O2 -Wall -Wextra -Werror -fPIC -shared /src/network.c -pthread -o /mave-media-network.so

FROM alpine:3.23 AS ffmpeg-build
ARG FFMPEG_VERSION=9.0.2
ARG FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
RUN apk add --no-cache \
      build-base \
      curl \
      dav1d-dev \
      lame-dev \
      libwebp-dev \
      nasm \
      openssl-dev \
      perl \
      pkgconf \
      svt-av1-dev \
      x264-dev \
      x265-dev \
      xz \
      zlib-dev
WORKDIR /src/ffmpeg
RUN curl -fsSLo /tmp/ffmpeg.tar.xz \
      "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
    && echo "${FFMPEG_SHA256}  /tmp/ffmpeg.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/ffmpeg.tar.xz --strip-components=1 \
    && ./configure \
      --prefix=/opt/ffmpeg \
      --disable-debug \
      --disable-doc \
      --disable-ffplay \
      --enable-gpl \
      --enable-version3 \
      --enable-libdav1d \
      --enable-libmp3lame \
      --enable-libsvtav1 \
      --enable-libwebp \
      --enable-libx264 \
      --enable-libx265 \
      --enable-openssl \
    && make -j"$(getconf _NPROCESSORS_ONLN)" \
    && make install

FROM alpine:3.23
RUN apk add --no-cache \
      ca-certificates \
      libdav1d \
      lame-libs \
      libcrypto3 \
      libssl3 \
      libstdc++ \
      libseccomp \
      libSvtAv1Enc \
      libwebp \
      libwebpmux \
      x264-libs \
      x265-libs \
      zlib
COPY --from=ffmpeg-build /opt/ffmpeg /opt/ffmpeg
ENV PATH="/opt/ffmpeg/bin:${PATH}"
RUN command -v ffmpeg | grep -q '^/opt/ffmpeg/bin/ffmpeg$' \
    && ffmpeg -version 2>&1 | grep -q "ffmpeg version 9.0.2" \
    && ffmpeg -hide_banner -decoders 2>&1 | grep -q libdav1d \
    && ffmpeg -hide_banner -encoders 2>&1 | grep -q libmp3lame \
    && ffmpeg -hide_banner -encoders 2>&1 | grep -q libwebp \
    && ffmpeg -hide_banner -encoders 2>&1 | grep -q libx264 \
    && ffmpeg -hide_banner -encoders 2>&1 | grep -q libx265 \
    && ffmpeg -hide_banner -encoders 2>&1 | grep -q libsvtav1 \
    && ffmpeg -hide_banner -loglevel error \
      -f lavfi -i color=c=black:s=16x16:d=0.04 \
      -frames:v 1 -c:v libwebp -f null - \
    && ffmpeg -hide_banner -loglevel error \
      -f lavfi -i color=c=black:s=64x64:d=0.04 \
      -frames:v 1 -c:v libsvtav1 -crf 55 -svtav1-params avif=1 \
      -f avif /tmp/frame.avif \
    && test -s /tmp/frame.avif \
    && ffmpeg -hide_banner -loglevel error \
      -f lavfi -i testsrc2=size=128x72:rate=25 -t 0.2 \
      -c:v libsvtav1 -preset 12 -pix_fmt yuv420p \
      /tmp/source-av1.mp4 \
    && ffmpeg -hide_banner -loglevel error \
      -i /tmp/source-av1.mp4 -map_metadata -1 -c:v mjpeg \
      -vf 'scale=iw*sar:ih,setsar=1' -frames:v 1 \
      -strict unofficial -q:v 6 /tmp/source-av1.jpg \
    && test -s /tmp/source-av1.jpg \
    && ffmpeg -hide_banner -loglevel error \
      -i /tmp/source-av1.mp4 -map_metadata -1 -map 0:v:0 \
      -vf 'scale=iw*sar:ih,setsar=1,scale=w=128:h=128:force_original_aspect_ratio=decrease:force_divisible_by=2' \
      -c:v libx264 -preset ultrafast -crf 23 -pix_fmt yuv420p -an \
      /tmp/source-av1-h264.mp4 \
    && test -s /tmp/source-av1-h264.mp4 \
    && rm /tmp/frame.avif /tmp/source-av1.mp4 /tmp/source-av1.jpg /tmp/source-av1-h264.mp4
COPY --from=sandbox-build /mave-media-sandbox /usr/local/bin/mave-media-sandbox
COPY --from=sandbox-build /mave-media-network.so /usr/local/lib/mave-media-network.so
COPY --from=broker-build /mave-media-broker /usr/local/bin/mave-media-broker
ENV MAVE_MEDIA_SANDBOX=required
COPY --from=app-build /out/encoder /encoder

USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/encoder"]

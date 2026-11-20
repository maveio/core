# syntax=docker/dockerfile:1
#
# Disposable sandbox image for AI pull-request testing. This file comes from the
# base branch; the build context is the untrusted pull-request checkout. Build
# it only in a job that holds no secrets: fetching and compiling dependencies
# already executes pull-request code.
#
# TOOLCHAIN_IMAGE is the base branch's `development` target of ../../Dockerfile.
ARG TOOLCHAIN_IMAGE=mave-ai-sandbox-toolchain
FROM ${TOOLCHAIN_IMAGE}

RUN useradd --create-home --uid 10001 --shell /bin/bash sandbox \
  && mkdir -p /app /sandbox \
  && chown sandbox:sandbox /app /sandbox

ENV MIX_ENV=test \
    MIX_HOME=/home/sandbox/.mix \
    HEX_HOME=/home/sandbox/.hex \
    MAVE_MEDIA_SANDBOX=disabled \
    HOME=/home/sandbox

WORKDIR /app
USER sandbox

COPY --chown=sandbox:sandbox . /app

# Fetching dependencies needs the network and must succeed. A pull request that
# does not compile is a finding, not a broken sandbox: the remaining steps
# record their output in /sandbox/prepare.log and never fail the build.
RUN <<'PREPARE'
set -eu
mix local.hex --force
mix local.rebar --force
mix deps.get

soft() {
  printf '\n$ %s\n' "$*" >> /sandbox/prepare.log
  if "$@" >> /sandbox/prepare.log 2>&1; then
    printf '[exit 0]\n' >> /sandbox/prepare.log
  else
    printf '[exit %s]\n' "$?" >> /sandbox/prepare.log
  fi
}

soft mix deps.compile
soft mix compile
soft mix assets.setup
soft mix assets.build
soft mix ua_inspector.download --force
PREPARE

CMD ["sleep", "infinity"]

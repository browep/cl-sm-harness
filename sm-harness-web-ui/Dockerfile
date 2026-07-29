# sm-harness-web-ui Docker image (CLOG + sm-harness + SDK)
ARG SBCL_VERSION=2:2.2.9-1
FROM node:22-bookworm-slim@sha256:6c74791e557ce11fc957704f6d4fe134a7bc8d6f5ca4403205b2966bd488f6b3 AS web-ui

ARG SBCL_VERSION
ARG CLAUDE_CODE_VERSION=2.1.219
# Pinned GitHub CLI release (installed from the upstream .deb below rather
# than adding cli.github.com's apt repo, keeping this to one apt source).
ARG GH_CLI_VERSION=2.96.0
# Matches the host repo owner so the /app bind mount (#90) is writable by
# the container user and edits land on the host with the right ownership.
ARG APP_UID=1000

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
      "sbcl=${SBCL_VERSION}" \
      cl-yason \
      cl-fiveam \
      cl-trivial-gray-streams \
      ca-certificates \
      curl \
      git \
      build-essential \
      libsqlite3-dev \
      procps \
      sudo \
 && npm install --global "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && curl -fsSL -o /tmp/gh.deb \
      "https://github.com/cli/cli/releases/download/v${GH_CLI_VERSION}/gh_${GH_CLI_VERSION}_linux_$(dpkg --print-architecture).deb" \
 && DEBIAN_FRONTEND=noninteractive apt-get install --yes /tmp/gh.deb \
 && rm -f /tmp/gh.deb \
 # The base image's "node" user already holds uid 1000; replace it rather
 # than stacking a second uid (#90).
 && userdel -r node \
 && useradd --create-home --uid ${APP_UID} --shell /usr/sbin/nologin app \
 # Passwordless sudo for the app user (#89): a deliberate extension of this
 # project's documented no-sandbox posture (#61) -- the harness's own
 # container/tailnet boundary is the isolation layer, nothing inside it is.
 && printf 'app ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/app \
 && chmod 0440 /etc/sudoers.d/app \
 && mkdir -p /cache /data /opt/quicklisp /app \
 && chown -R app:app /cache /data /opt/quicklisp /app \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

USER app
WORKDIR /home/app
ENV HOME=/home/app
RUN curl -fsSL https://beta.quicklisp.org/quicklisp.lisp -o /tmp/quicklisp.lisp \
 && sbcl --non-interactive \
      --load /tmp/quicklisp.lisp \
      --eval '(quicklisp-quickstart:install :path "/opt/quicklisp/")' \
      --eval '(load "/opt/quicklisp/setup.lisp")' \
      --eval '(ql:quickload :clog)' \
 && rm -f /tmp/quicklisp.lisp \
 && printf '%s\n' '(load "/opt/quicklisp/setup.lisp")' > /home/app/.sbclrc
# Wire git to use `gh` as its credential helper for github.com, written to
# the app user's *global* (~/.gitconfig) config -- deliberately not the
# /app repo's local config, since /app is the host repo bind mount (#90)
# and a local-config write would land on the host. `--force` is required
# here because no host is authenticated at build time; at runtime `gh`
# picks up credentials from the GH_TOKEN/GITHUB_TOKEN environment variable
# with no further setup (e.g. via the compose file's env_file: .env).
RUN gh auth setup-git --hostname github.com --force

USER root
COPY --chown=app:app claude-agent-sdk-cl.asd /app/claude-agent-sdk-cl.asd
COPY --chown=app:app src /app/src
COPY --chown=app:app sm-harness /app/sm-harness
COPY --chown=app:app sm-harness-web-ui /app/sm-harness-web-ui
COPY docker/claude-agent-sdk-cl-supervisor.c /tmp/claude-agent-sdk-cl-supervisor.c
COPY sm-harness-web-ui/docker/entrypoint.sh /usr/local/bin/sm-harness-web-ui-entrypoint
RUN mkdir -p /usr/local/libexec \
 && cc -O2 -Wall -Wextra -o /usr/local/libexec/claude-agent-sdk-cl-supervisor /tmp/claude-agent-sdk-cl-supervisor.c \
 && rm /tmp/claude-agent-sdk-cl-supervisor.c \
 && chmod 0755 /usr/local/bin/sm-harness-web-ui-entrypoint \
 # Assembled OUTSIDE /app on purpose: the compose web-ui service bind-mounts
 # the host repo over /app (#90), which would shadow anything baked there.
 && mkdir -p /opt/app-static \
 && cp -a /opt/quicklisp/dists/quicklisp/software/clog-*/static-files/. /opt/app-static/ \
 && cp -a /app/sm-harness-web-ui/static/. /opt/app-static/ \
 && chown -R app:app /app /home/app /opt/app-static

USER app
WORKDIR /app
ENV HOME=/home/app \
    CL_SOURCE_REGISTRY=/app// \
    XDG_CACHE_HOME=/cache \
    SM_HARNESS_DATA=/data \
    SM_HARNESS_HOST=0.0.0.0 \
    SM_HARNESS_PORT=8080 \
    SM_HARNESS_STATIC_ROOT=/opt/app-static
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/sm-harness-web-ui-entrypoint"]
CMD ["web"]

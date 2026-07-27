# sm-harness-web-ui Docker image (CLOG + sm-harness + SDK)
ARG SBCL_VERSION=2:2.2.9-1
FROM node:22-bookworm-slim@sha256:6c74791e557ce11fc957704f6d4fe134a7bc8d6f5ca4403205b2966bd488f6b3 AS web-ui

ARG SBCL_VERSION
ARG CLAUDE_CODE_VERSION=2.1.219

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
 && npm install --global "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && useradd --create-home --uid 10001 --shell /usr/sbin/nologin app \
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

USER root
COPY --chown=app:app claude-agent-sdk-cl.asd /app/claude-agent-sdk-cl.asd
COPY --chown=app:app src /app/src
COPY --chown=app:app sm-harness /app/sm-harness
COPY --chown=app:app sm-harness-web-ui /app/sm-harness-web-ui
COPY sm-harness-web-ui/docker/entrypoint.sh /usr/local/bin/sm-harness-web-ui-entrypoint
RUN chmod 0755 /usr/local/bin/sm-harness-web-ui-entrypoint \
 && mkdir -p /app/static \
 && cp -a /opt/quicklisp/dists/quicklisp/software/clog-*/static-files/. /app/static/ \
 && cp -a /app/sm-harness-web-ui/static/. /app/static/ \
 && chown -R app:app /app /home/app

USER app
WORKDIR /app
ENV HOME=/home/app \
    CL_SOURCE_REGISTRY=/app// \
    XDG_CACHE_HOME=/cache \
    SM_HARNESS_DATA=/data \
    SM_HARNESS_HOST=0.0.0.0 \
    SM_HARNESS_PORT=8080
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/sm-harness-web-ui-entrypoint"]
CMD ["web"]

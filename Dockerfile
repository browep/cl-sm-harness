FROM node:22-bookworm-slim@sha256:6c74791e557ce11fc957704f6d4fe134a7bc8d6f5ca4403205b2966bd488f6b3

ARG SBCL_VERSION=2:2.2.9-1
ARG FIVEAM_VERSION=1.4.2-1
ARG CLAUDE_CODE_VERSION=2.1.219

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        "sbcl=${SBCL_VERSION}" \
        "cl-fiveam=${FIVEAM_VERSION}" \
        ca-certificates \
    && npm install --global "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && useradd --create-home --uid 10001 --shell /usr/sbin/nologin sdk \
    && mkdir --parents /cache \
    && chown sdk:sdk /cache \
    && mkdir --parents /usr/local/share/claude-agent-sdk-cl \
    && { \
        printf 'sbcl='; sbcl --version; \
        printf 'cl-fiveam='; dpkg-query --showformat='${Version}' --show cl-fiveam; printf '\n'; \
        printf 'claude='; claude --version; \
       } > /usr/local/share/claude-agent-sdk-cl/runtime-versions.txt \
    && apt-get clean \
    && rm --recursive --force /var/lib/apt/lists/*

COPY docker/entrypoint.sh /usr/local/bin/claude-agent-sdk-cl-entrypoint
RUN chmod 0755 /usr/local/bin/claude-agent-sdk-cl-entrypoint

WORKDIR /workspace
ENV HOME=/home/sdk \
    CL_SOURCE_REGISTRY=/workspace// \
    XDG_CACHE_HOME=/cache
ENTRYPOINT ["/usr/local/bin/claude-agent-sdk-cl-entrypoint"]
CMD ["unit"]

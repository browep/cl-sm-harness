ARG UPSTREAM_COMMIT=3145cc637778b23cb3caff7556ab76a10028b084

FROM python:3.12-slim-bookworm@sha256:d50fb7611f86d04a3b0471b46d7557818d88983fc3136726336b2a4c657aa30b AS upstream-source
ARG UPSTREAM_COMMIT
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends git ca-certificates \
    && rm --recursive --force /var/lib/apt/lists/* \
    && git init /opt/upstream \
    && git -C /opt/upstream remote add origin https://github.com/anthropics/claude-agent-sdk-python.git \
    && git -C /opt/upstream fetch --depth=1 origin "${UPSTREAM_COMMIT}" \
    && git -C /opt/upstream checkout --detach FETCH_HEAD \
    && test "$(git -C /opt/upstream rev-parse HEAD)" = "${UPSTREAM_COMMIT}"

FROM upstream-source AS catalog
ARG UPSTREAM_COMMIT
COPY docker/reference/catalog.py /usr/local/bin/catalog.py
RUN python /usr/local/bin/catalog.py \
      --source /opt/upstream \
      --commit "${UPSTREAM_COMMIT}" \
      --output /opt/catalog/upstream-catalog.json

FROM catalog AS reference
COPY docker/reference/export_contracts.py /usr/local/bin/export-contracts.py
ENTRYPOINT ["python", "/usr/local/bin/export-contracts.py"]

FROM node:22-bookworm-slim@sha256:6c74791e557ce11fc957704f6d4fe134a7bc8d6f5ca4403205b2966bd488f6b3 AS test

ARG SBCL_VERSION=2:2.2.9-1
ARG FIVEAM_VERSION=1.4.2-1
ARG YASON_VERSION=0.7.6-1.1
ARG TRIVIAL_GRAY_STREAMS_VERSION=20210117.git2b3823e-1
ARG CLAUDE_CODE_VERSION=2.1.219

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        "sbcl=${SBCL_VERSION}" \
        "cl-fiveam=${FIVEAM_VERSION}" \
        "cl-yason=${YASON_VERSION}" \
        "cl-trivial-gray-streams=${TRIVIAL_GRAY_STREAMS_VERSION}" \
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
        printf 'upstream_commit=%s\n' "${UPSTREAM_COMMIT}"; \
       } > /usr/local/share/claude-agent-sdk-cl/runtime-versions.txt \
    && apt-get clean \
    && rm --recursive --force /var/lib/apt/lists/*

COPY --from=catalog /opt/catalog/upstream-catalog.json /opt/upstream-catalog.json
COPY docker/entrypoint.sh /usr/local/bin/claude-agent-sdk-cl-entrypoint
RUN chmod 0755 /usr/local/bin/claude-agent-sdk-cl-entrypoint

WORKDIR /workspace
ENV HOME=/home/sdk \
    CL_SOURCE_REGISTRY=/workspace// \
    XDG_CACHE_HOME=/cache
ENTRYPOINT ["/usr/local/bin/claude-agent-sdk-cl-entrypoint"]
CMD ["unit"]

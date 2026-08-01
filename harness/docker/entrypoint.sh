#!/bin/sh
set -eu

# Docker creates a fresh named volume as root. Give the unprivileged runtime user
# ownership before executing anything from the read-only source mount.
mkdir -p /cache
chown sdk:sdk /cache

exec runuser -u sdk -- sh /workspace/scripts/test.sh "$@"

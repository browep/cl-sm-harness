#!/bin/sh
set -eu
mkdir -p /data /cache
# Volumes created under an earlier image uid (10001, pre-#90) are not
# writable by the current app user; self-heal ownership via sudo (#89).
# The -w test keeps this a no-op on every boot where ownership is right.
for d in /data /cache; do
  if [ -d "$d" ] && [ ! -w "$d" ] && command -v sudo >/dev/null 2>&1; then
    sudo chown -R "$(id -u):$(id -g)" "$d" || true
  fi
done
# entrypoint runs as app user already in image
mode="${1:-web}"
# The baked quicklisp software tree sits BEFORE the Debian tree: apt's
# cl-drakma (#112) drags in Debian's cl-bordeaux-threads 0.8.8 (no BT2
# package), and if it shadowed the dist's bordeaux-threads, recompiling the
# dist's ironclad-v0.61 (clog's dep closure) would fail at boot with
# "Package BT2 does not exist". Debian's tree stays last so systems not in
# the dist still resolve offline.
export CL_SOURCE_REGISTRY="/app//:/opt/quicklisp/dists/quicklisp/software//:/usr/share/common-lisp/source//"
case "$mode" in
  web)
    system=':sm-harness-web-ui'
    if [ "${WEB_UI_E2E:-}" = "1" ]; then
      system=':sm-harness-web-ui/e2e'
    fi
    exec sbcl --non-interactive \
      --eval '(require :asdf)' \
      --eval "(asdf:load-system $system)" \
      --eval '(sm-harness-web-ui:main)'
    ;;
  health)
    # Lightweight non-Claude health: process is up if we got here under a healthcheck wrapper.
    printf 'ok\n'
    ;;
  *)
    printf 'unknown mode: %s\n' "$mode" >&2
    exit 64
    ;;
esac

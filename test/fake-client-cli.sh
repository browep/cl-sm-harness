#!/bin/sh
# Discard the real stream-json CLI flags and invoke the persistent fake protocol.
# This lets the public default client provisioning path be tested offline.
exec /workspace/test/fake-claude.sh client

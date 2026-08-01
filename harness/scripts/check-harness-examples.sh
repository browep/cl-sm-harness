#!/bin/sh
# Load and exercise credential-free harness examples. This script never invokes
# the Claude CLI; do not add live tests here.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export CL_SOURCE_REGISTRY="$root//:/usr/share/common-lisp/source//${CL_SOURCE_REGISTRY:+:$CL_SOURCE_REGISTRY}"
unset CLAUDE_SDK_LIVE_TEST CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY

for file in "$root"/examples/harness/[0-9][0-9]-*.lisp; do
  printf '%s\n' "loading ${file#$root/}"
  sbcl --disable-debugger --non-interactive \
    --eval '(require :asdf)' \
    --load "$file" \
    --eval '(uiop:quit 0)'
done

# Exercise only no-process, deterministic helpers from fresh load-safe files.
sbcl --disable-debugger --non-interactive \
  --eval '(require :asdf)' \
  --load "$root/examples/harness/01-install-and-verify.lisp" \
  --load "$root/examples/harness/04-message-mapping.lisp" \
  --load "$root/examples/harness/05-control-handlers.lisp" \
  --load "$root/examples/harness/06-session-store.lisp" \
  --load "$root/examples/harness/07-fake-query-transport.lisp" \
  --load "$root/examples/harness/09-fake-client-transport.lisp" \
  --load "$root/examples/harness/10-session-start-sdk-mcp.lisp" \
  --eval '(unless (getf (claude-agent-sdk-cl.harness-example.install:sdk-build-info) :sdk-version) (error "missing SDK version"))' \
  --eval '(multiple-value-bind (entries sessions) (claude-agent-sdk-cl.harness-example.session-store:record-in-memory-event "example-project" "example-session" "event-1" "payload") (unless (and (= 1 (length entries)) (equal sessions (list "example-session"))) (error "session-store example failed")))' \
  --eval '(multiple-value-bind (import rename) (claude-agent-sdk-cl.harness-example.session-store:make-session-plans) (unless (and (string= "run-42" (claude-agent-sdk-cl:session-import-plan-session-id import)) (string= "imports/run-42.jsonl" (claude-agent-sdk-cl:session-import-plan-path import)) (eq :rename (claude-agent-sdk-cl:session-mutation-plan-operation rename))) (error "session-plan example failed")))' \
  --eval '(let ((messages (claude-agent-sdk-cl.harness-example.fake-query:run-fixture-query))) (unless (and (= 2 (length messages)) (typep (first messages) (find-symbol "ASSISTANT-MESSAGE" :claude-agent-sdk-cl)) (typep (second messages) (find-symbol "RESULT-MESSAGE" :claude-agent-sdk-cl))) (error "fixture-query example failed")))' \
  --eval '(multiple-value-bind (messages writes) (claude-agent-sdk-cl.harness-example.fake-client:run-fixture-client) (unless (and (= 2 (length messages)) (= 2 (length writes)) (typep (first messages) (find-symbol "ASSISTANT-MESSAGE" :claude-agent-sdk-cl)) (typep (second messages) (find-symbol "RESULT-MESSAGE" :claude-agent-sdk-cl))) (error "fixture-client example failed")))' \
  --eval '(let* ((options (claude-agent-sdk-cl.harness-example.sdk-mcp:make-orders-catalog-options)) (names (claude-agent-sdk-cl.harness-example.sdk-mcp:catalog-server-names options)) (tools (claude-agent-sdk-cl.harness-example.sdk-mcp:qualified-tool-names options)) (client (claude-agent-sdk-cl.harness-example.control-handlers:make-catalog-policy-client))) (unless (and (equal names (list "orders")) (equal tools (list "mcp__orders__lookup_order")) (eq :none (claude-agent-sdk-cl:agent-options-builtin-tools options)) (eq t (claude-agent-sdk-cl:agent-options-strict-mcp-config options)) (typep client (find-symbol "CLAUDE-SDK-CLIENT" :claude-agent-sdk-cl))) (error "session-start SDK MCP example failed")))' \
  --eval '(format t "Harness examples passed.~%")' \
  --eval '(uiop:quit 0)'

printf '%s\n' 'Harness examples check passed.'

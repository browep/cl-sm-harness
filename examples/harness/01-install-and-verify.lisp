;;;; Load-safe SDK installation check. Does not start Claude.
(defpackage #:claude-agent-sdk-cl.harness-example.install
  (:use #:cl)
  (:export #:sdk-build-info))
(in-package #:claude-agent-sdk-cl.harness-example.install)
(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)

(defun sdk-build-info ()
  "Return the SDK version after ASDF has loaded the integration dependency."
  (list :sdk-version (claude-agent-sdk-cl:sdk-version)))

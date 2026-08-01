(in-package #:sm-harness-web-ui)

(defun e2e-upload-scenario ()
  (%e2e-object
   "name" "upload" "evidence_suffix" "path-appended"
   "steps"
   (list
    (%e2e-step "focus" "selector" "#new-session")
    (%e2e-step "press" "key" "Enter")
    (%e2e-step "wait" "selector" "#chat-root" "state" "visible")
    (%e2e-step "wait" "selector" "#prompt" "state" "visible")
    (%e2e-step "wait" "selector" "#upload-file" "state" "visible")
    (%e2e-step "wait" "selector" "#upload-spinner" "state" "hidden")
    ;; #127: an over-limit file must never even round-trip to /upload --
    ;; the client-side size check (INSTALL-UPLOAD-PANEL's inline JS) must
    ;; reject it before the spinner shows or the composer changes at all.
    ;; Asserted before the real (small) upload below so a regression that
    ;; dropped the client-side check would still fail this even if the
    ;; file happened to also get rejected server-side.
    (%e2e-step "set_input_files" "selector" "#upload-file-input"
               "name" "too-big.bin" "size_bytes" 20971521)
    (%e2e-step "wait_pattern" "selector" "#chat-error" "pattern" "exceeds 20MB limit")
    (%e2e-step "wait" "selector" "#upload-spinner" "state" "hidden")
    (%e2e-step "assert_value" "selector" "#prompt" "value" "")
    ;; A genuine small upload: the spinner shows while the hidden iframe's
    ;; POST to /upload (ON-UPLOAD-WINDOW, ui/upload.lisp) is in flight and
    ;; clears once its postMessage response lands.
    (%e2e-step "set_input_files" "selector" "#upload-file-input"
               "name" "e2e-upload.txt" "mime_type" "text/plain"
               "content" "hello from e2e")
    (%e2e-step "wait" "selector" "#upload-spinner" "state" "hidden")
    ;; The composer now holds the *server-side* saved path (under this
    ;; session's own upload directory, %UPLOAD-SESSION-DIR), not the
    ;; browser-local file name.
    (%e2e-step "assert_input_pattern" "selector" "#prompt" "pattern" "uploads[/\\\\].*e2e-upload\\.txt$")
    ;; The whole point of #127: appending the path must never invoke Send.
    (%e2e-step "assert_count" "selector" ".msg-user" "count" 0)
    (%e2e-step "assert_disabled" "selector" "#send" "value" nil)
    (%e2e-step "assert_text" "selector" "#chat-error" "value" ""))))

(in-package #:sm-harness-web-ui)

;;;; Test-only Lisp-side hook for #100's browser E2E coverage. Never loaded
;;;; by production: this file lives in the sm-harness-web-ui/e2e ASDF
;;;; system, only loaded when WEB_UI_E2E=1 (see %fixture-transport-factory
;;;; in application.lisp for the analogous existing pattern), and the route
;;;; it registers is only installed by START-WEB-UI when running under that
;;;; same flag (see %maybe-install-e2e-test-routes, application.lisp).
;;;;
;;;; The bug this exists to exercise (#100) needs a tab whose CLOG
;;;; connection reaches the exact terminal "Shutdown_ws already ran, ws is
;;;; permanently null" state that a rejected stale reconnect produces after
;;;; a real process restart (see docs/sm-harness-web-ui.md). CLOG exposes
;;;; that transition directly: (clog-connection:shutdown connection-id) sends the
;;;; client-side Shutdown_ws() call boot.js's own onclose handler sends on a
;;;; genuine rejected reconnect. There is no way for the Playwright/JS side
;;;; to reach the Lisp-side body object of an *already open* tab directly,
;;;; so this registers a second, throwaway CLOG route: opening it (in a
;;;; second browser tab/page, via the generic "open_tab" bridge op) shuts
;;;; down every other currently tracked live tab, then the test driver
;;;; closes that throwaway tab. See e2e/scenarios/connection-lost-recovery.lisp
;;;; and connection-lost-fallback.lisp.

(defun %e2e-shutdown-other-live-windows ()
  "Call CLOG:SHUTDOWN on every currently tracked live browser window (see
*LIVE-BROWSER-WINDOWS*, live-reload.lisp). In practice there is exactly one
such window during an E2E scenario: the primary tab under test. This
route's own window is never tracked -- it uses its own ON-NEW-WINDOW
handler below, not #'ON-NEW-WINDOW/%TRACK-LIVE-BROWSER-WINDOW -- so there
is no risk of it shutting itself down."
  (dolist (body *live-browser-windows*)
    (when (ignore-errors (clog-connection:validp (clog::connection-id body)))
      (ignore-errors (clog-connection:shutdown (clog::connection-id body))))))

(defun %e2e-drop-connection-window (body)
  (declare (ignore body))
  (%e2e-shutdown-other-live-windows))

(defun %e2e-install-test-routes ()
  "Register fixture-only CLOG routes. Only called from START-WEB-UI when
WEB_UI_E2E=1."
  (clog:set-on-new-window #'%e2e-drop-connection-window
                          :path "/e2e-drop-connection" :boot-file "/boot.html"))

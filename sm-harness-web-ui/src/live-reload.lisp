(in-package #:sm-harness-web-ui)

;;;; #78: once RELOAD_HARNESS finishes reloading this system's own source
;;;; without error, make that visible in the browser instead of requiring a
;;;; human to notice and hit F5.
;;;;
;;;; CLOG captures the ON-NEW-WINDOW function object exactly once, at
;;;; CLOG:INITIALIZE/CLOG:SET-ON-NEW-WINDOW time, into its own private
;;;; routing table. Redefining ON-NEW-WINDOW (or anything it calls, e.g.
;;;; RENDER-HOME/RENDER-CHAT/PRESENTER) via a later ASDF reload rebinds the
;;;; symbol's function cell but does not touch that already-captured
;;;; function object, so a *new* browser connection would otherwise keep
;;;; hitting stale pre-reload code until the process restarts.

(defvar *live-browser-windows* nil
  "CLOG body objects for currently open browser windows, tracked so a
successful RELOAD_HARNESS can push a page reload to each one still open.
Pruned lazily -- entries for tabs that closed since the last reload are
dropped the next time %REFRESH-LIVE-BROWSER-WINDOWS runs, not eagerly.")

(defun %track-live-browser-window (body)
  "Record BODY (a freshly opened window) so a later reload can find it."
  (push body *live-browser-windows*))

(defun %refresh-live-browser-windows ()
  "Reload every currently open browser tab and drop any that closed since
the last call. CLOG:RELOAD on a since-closed connection is a silent no-op
(CLOG-CONNECTION:EXECUTE just finds no live connection to send to), but the
VALIDP check here still lets this list stop growing unboundedly across a
long-running process's lifetime."
  (setf *live-browser-windows*
        (remove-if-not
         (lambda (body)
           (let ((live (clog-connection:validp (clog::connection-id body))))
             (when live (ignore-errors (clog:reload (clog:location body))))
             live))
         *live-browser-windows*)))

(defun %reinstall-clog-routes ()
  "Re-point CLOG's routing table at the just-reloaded #'ON-NEW-WINDOW so any
*new* connection (including a tab this same call is about to refresh) gets
current code, not the stale closure CLOG:INITIALIZE originally captured."
  (clog:set-on-new-window #'on-new-window :path "/" :boot-file "/boot.html")
  (clog:set-on-new-window #'on-new-window :path "/sessions" :boot-file "/boot.html"))

(defun %refresh-after-reload ()
  "Installed as SM-HARNESS:*POST-RELOAD-HOOK* by START-WEB-UI (#78)."
  (%reinstall-clog-routes)
  (%refresh-live-browser-windows))

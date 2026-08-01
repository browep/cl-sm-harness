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
  "Re-point CLOG's routing table at the just-reloaded #'ON-NEW-WINDOW (and
#'ON-UPLOAD-WINDOW, #127) so any *new* connection (including a tab this
same call is about to refresh) gets current code, not the stale closure
CLOG:INITIALIZE originally captured.

Also re-registers the #138 file-browser plugin path. Unlike the routes
above, ADD-PLUGIN-PATH's own hash table isn't a stale-closure problem --
see APPLICATION.LISP's ADD-PLUGIN-PATH call site comment, it closes over
nothing reload-sensitive -- but START-WEB-UI itself only ever runs once,
at real process boot, so a process that picks up #138 via RELOAD_HARNESS
rather than a fresh container start (exactly this project's own dev loop,
see docs/sm-harness-web-ui.md's RELOAD_HARNESS notes) would otherwise
never register it at all. Calling it again here is a harmless no-op
overwrite of the same regex/root pair on every ordinary reload.
(ADD-PLUGIN-PATH is CLOG-CONNECTION:ADD-PLUGIN-PATH, not a CLOG-package
symbol -- see APPLICATION.LISP's call site comment.)"
  (clog:set-on-new-window #'on-new-window :path "/" :boot-file "/boot.html")
  (clog:set-on-new-window #'on-new-window :path "/sessions" :boot-file "/boot.html")
  (clog:set-on-new-window #'on-upload-window :path "/upload" :boot-file "/boot.html")
  (clog-connection:add-plugin-path "^/app/" "/"))

(defun %reassert-static-root ()
  "Re-point CLOG-CONNECTION:*STATIC-ROOT* at the configured static root
(#105). CLOG keeps that path in a bare DEFPARAMETER
(clog-connection.lisp), not anything START-WEB-UI-owned, so any
RELOAD_HARNESS that happens to re-evaluate CLOG itself -- e.g. the
whole-dependency-tree reload a stale fasl can trigger, distinguishable
after the fact only by its warning output naming packages outside this
repo -- silently resets it to NIL. Nothing else ever assigns it again
(CLOG:INITIALIZE is a once-at-boot call), so from that moment every static
asset request 500s until a container restart, even though the harness,
sessions, and health check all keep looking fine. Re-asserting the
already-configured value here is a harmless no-op on an ordinary reload
that never touched CLOG; a log line only fires when this call actually
had to repair something, so it doubles as a diagnostic for the scenario
above."
  (let ((expected (namestring (web-ui-config-static-root *web-ui-config*))))
    (unless (equal clog-connection:*static-root* expected)
      (format *error-output*
              "RELOAD_HARNESS repaired CLOG-CONNECTION:*STATIC-ROOT* to ~S ~
after reload, re-asserting ~S -- see #105 (this reload likely re-evaluated ~
CLOG itself; check its warning output for packages outside this repo)~%"
              clog-connection:*static-root* expected)
      (setf clog-connection:*static-root* expected))))

(defun %refresh-after-reload ()
  "Installed as SM-HARNESS:*POST-RELOAD-HOOK* by START-WEB-UI (#78)."
  (%reassert-static-root)
  (%reinstall-clog-routes)
  (%refresh-live-browser-windows)
  ;; #116 phase 2: flag every open session to reconnect (picking up
  ;; *APP-HARNESS*'s current HARNESS-CATALOG-PROVIDER, itself already
  ;; re-resolved per #116 phase 1) the next time a turn starts for it --
  ;; never disrupts a turn actively in flight right now, see
  ;; MARK-SESSIONS-FOR-CATALOG-REFRESH's docstring. Guarded the same way
  ;; the calls above are: a reload with no harness constructed yet (should
  ;; not happen once START-WEB-UI has run, but this hook has no other
  ;; guarantee of ordering against a future caller) must not turn a
  ;; successful reload into a tool-result error.
  (when *app-harness*
    (sm-harness:mark-sessions-for-catalog-refresh *app-harness*)))

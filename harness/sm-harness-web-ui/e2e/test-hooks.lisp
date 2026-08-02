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

;;;; #129 coverage: a second, throwaway-tab test route that renames every
;;;; currently open session via the real SM-HARNESS:SET-SESSION-TITLE API
;;;; (the same call the set_session_title catalog tool itself makes; see
;;;; sm-harness/src/tool-catalog.lisp) -- exactly like the drop-connection
;;;; route above, this exists because the Playwright/JS side has no way to
;;;; reach the Lisp-side harness of an already-open tab directly, and
;;;; scripting a real tool_use through the fixture SDK transport would need
;;;; to hardcode a session id that does not exist until the scenario itself
;;;; creates one. Renaming *every* open session (there is exactly one during
;;;; this scenario, the primary tab under test) sidesteps needing to plumb
;;;; that runtime-generated id into this route at all.
(defun %e2e-rename-open-sessions (new-title)
  (let ((h (ensure-harness)))
    (dolist (summary (sm-harness:list-sessions h))
      (sm-harness:set-session-title h (sm-harness:session-summary-id summary) new-title))))

(defparameter +e2e-title-live-update-new-title+ "Renamed live via e2e"
  "Shared between this hook and e2e-title-live-update-scenario's own
assertions -- the actual string never matters, only that both sides agree
on it.")

(defun %e2e-rename-session-window (body)
  (declare (ignore body))
  (%e2e-rename-open-sessions +e2e-title-live-update-new-title+))



;;;; #140 coverage: the git diff viewer needs a *real* git repo with real
;;;; uncommitted changes on disk before the browser side can walk the file
;;;; tree to it -- unlike every scenario above, this is filesystem setup,
;;;; not a CLOG-state trick, but the same "no way for Playwright to reach
;;;; Lisp-side state directly, so use a throwaway open_tab route" shape
;;;; applies: e2e/scenarios/git-diff.lisp hits this route once, via
;;;; open_tab, before it ever opens the file browser. +E2E-GIT-DIFF-
;;;; FIXTURE-ROOT+ is a *fixed* path (not a random per-run temp dir the
;;;; way PRESENTER-TESTS's WITH-GIT-FIXTURE macro uses) precisely so the
;;;; scenario's own tree-navigation selectors can be static text.

(defparameter +e2e-git-diff-fixture-root+ #P"/tmp/e2e-git-diff-fixture/"
  "Rebuilt from scratch on every hit of /e2e-setup-git-diff-fixture --
see %E2E-BUILD-GIT-DIFF-FIXTURE. Deliberately under /tmp, not /app: this
must be a plain, disposable directory the E2E run can freely wipe and
recreate, never anything under the live repo mount.")

(defun %e2e-build-git-diff-fixture ()
  "(Re)build +E2E-GIT-DIFF-FIXTURE-ROOT+ as a small, deterministic git
repo: an initial empty commit, then a committed tracked.txt, then two
uncommitted changes -- tracked.txt modified (\"original line\" ->
\"changed line\") and a brand new untracked new-file.txt -- so
e2e-git-diff-scenario always finds exactly the same two changed-file rows
in the same sorted order (%GIT-STATUS-ENTRIES sorts by path: \"new-
file.txt\" before \"tracked.txt\"). Uses `echo`, not `printf` -- CL
string-literal syntax has no \"\\n means newline\" escape the way C-ish
languages do (a stray single backslash before an ordinary character in a
CL string literal just quotes that character, dropping the backslash
entirely), so a bare \"\\n\" written directly in a DEFUN body here would
silently reach the shell as a literal \"n\", not a newline -- `echo`
sidesteps the whole issue by appending the trailing newline itself,
exactly like PRESENTER-TESTS's own WITH-GIT-FIXTURE macro (test/ui-state.lisp)
already does."
  (let ((root +e2e-git-diff-fixture-root+))
    (ignore-errors (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))
    (ensure-directories-exist root)
    (let ((script
            (format nil
                    "cd ~A && git init -q && ~
git -c user.email=e2e@example.com -c user.name=e2e commit --allow-empty -qm init && ~
echo 'original line' > tracked.txt && git add tracked.txt && ~
git -c user.email=e2e@example.com -c user.name=e2e commit -qm seed && ~
echo 'changed line' > tracked.txt && ~
echo 'brand new content' > new-file.txt"
                    (namestring root))))
      (multiple-value-bind (out err code)
          (uiop:run-program (list "/bin/sh" "-c" script)
                            :output '(:string) :error-output '(:string)
                            :ignore-error-status t)
        (unless (zerop code)
          (error "e2e git-diff fixture setup failed (exit ~A): ~A / ~A" code out err))))))

(defun %e2e-setup-git-diff-fixture-window (body)
  (declare (ignore body))
  (%e2e-build-git-diff-fixture))

(defun %e2e-install-test-routes ()
  "Register fixture-only CLOG routes. Only called from START-WEB-UI when
WEB_UI_E2E=1."
  (clog:set-on-new-window #'%e2e-drop-connection-window
                          :path "/e2e-drop-connection" :boot-file "/boot.html")
  (clog:set-on-new-window #'%e2e-rename-session-window
                          :path "/e2e-rename-session" :boot-file "/boot.html")
  (clog:set-on-new-window #'%e2e-setup-git-diff-fixture-window
                          :path "/e2e-setup-git-diff-fixture" :boot-file "/boot.html"))

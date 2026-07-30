(in-package #:sm-harness-web-ui)

(defun %session-id-from-route (path)
  (let ((prefix "/sessions/"))
    (when (and (uiop:string-prefix-p prefix path)
               (> (length path) (length prefix)))
      (let ((id (subseq path (length prefix))))
        (and (null (position #\/ id)) id)))))

(defun on-new-window (body)
  (clog:load-css (clog:html-document body) "/app.css")
  ;; Browser log capture (#92): loaded once per tab. Home<->chat
  ;; transitions below are in-place DOM rebuilds in this same JS realm
  ;; (CLOG swaps innerHTML rather than navigating), so this single load
  ;; covers the whole tab lifetime, including later session switches.
  (clog:load-script (clog:html-document body) "/log-capture.js")
  ;; #100 fix A: a visible, actionable fallback if this connection's
  ;; websocket ever reaches its terminal "Shutdown_ws already ran" state
  ;; (e.g. a rejected stale reconnect after a container/process restart) --
  ;; see docs/sm-harness-web-ui.md and browser-logs.lisp. This is a
  ;; backstop: log-capture.js's own self-heal (fix B) already reloads the
  ;; tab automatically in the common case, before a user is likely to see
  ;; this at all.
  (%install-connection-lost-fallback body)
  ;; Tracked so a later successful reload_harness can refresh this tab
  ;; (#78).
  (%track-live-browser-window body)
  (let ((session-id (%session-id-from-route
                     (clog:path-name (clog:location body)))))
    (if session-id
        (handler-case (render-chat body session-id)
          (sm-harness:harness-not-found-error () (render-not-found body)))
        (render-home body))))

(defun start-web-ui (&key harness config fixture-p)
  "Start CLOG server. HARNESS must already be constructed. FIXTURE-P, when
true, additionally registers test-only E2E routes (#100) if the
sm-harness-web-ui/e2e system providing them is loaded -- see
%MAYBE-INSTALL-E2E-TEST-ROUTES."
  (setf *app-harness* harness
        *web-ui-config* (or config (make-web-ui-config)))
  (let ((cfg *web-ui-config*))
    (setf *clog-server*
          (clog:initialize #'on-new-window
                           :host (web-ui-config-host cfg)
                           :port (web-ui-config-port cfg)
                           :static-root (namestring (web-ui-config-static-root cfg))
                           :boot-file "/boot.html"
                           :extended-routing t))
    (clog:set-on-new-window #'on-new-window :path "/sessions" :boot-file "/boot.html")
    (%maybe-install-e2e-test-routes fixture-p)
    ;; Once this system's own source reloads, re-point CLOG's routing at
    ;; fresh code and push open tabs a refresh (#78).
    (setf sm-harness:*post-reload-hook* #'%refresh-after-reload)
    (format t "sm-harness-web-ui listening on ~A:~A~%"
            (web-ui-config-host cfg)
            (web-ui-config-port cfg))
    *clog-server*))

(defun stop-web-ui ()
  (when *app-harness*
    (ignore-errors (sm-harness:close-harness *app-harness*))
    (setf *app-harness* nil))
  (setf *clog-server* nil)
  ;; Drop tracked windows/hook too (#78): stale entries from a previous
  ;; start-web-ui must not survive into whatever runs next in this image.
  (setf *live-browser-windows* nil)
  (when (eq sm-harness:*post-reload-hook* #'%refresh-after-reload)
    (setf sm-harness:*post-reload-hook* nil))
  t)

(defun %fixture-transport-factory ()
  "Find the test-only E2E transport installed by sm-harness-web-ui/e2e."
  (let ((symbol (find-symbol "%E2E-TRANSPORT-FACTORY" :sm-harness-web-ui)))
    (unless (and symbol (fboundp symbol))
      (error "WEB_UI_E2E requires the sm-harness-web-ui/e2e ASDF system"))
    (symbol-function symbol)))

(defun %maybe-install-e2e-test-routes (fixture-p)
  "Register test-only CLOG routes (#100 browser E2E coverage) when
FIXTURE-P is true and the sm-harness-web-ui/e2e system (which defines
them) happens to be loaded. Unlike %FIXTURE-TRANSPORT-FACTORY this does
not error when the symbol is absent: e2e-contract-only load paths (e.g.
WRITE-E2E-CONTRACT callers that never load sm-harness-web-ui/e2e) must
keep working without this route existing."
  (when fixture-p
    (let ((symbol (find-symbol "%E2E-INSTALL-TEST-ROUTES" :sm-harness-web-ui)))
      (when (and symbol (fboundp symbol))
        (funcall (symbol-function symbol))))))

(defun %run-until-shutdown ()
  "Block until Docker's TERM/INT request is received, then release durable state."
  (let ((shutdown-requested nil))
    (%install-shutdown-signal-handlers (lambda () (setf shutdown-requested t)))
    (unwind-protect
         (loop until shutdown-requested do (sleep 0.1))
      (stop-web-ui))))

(defun %chat-agent-system-prompt (data-root)
  "System prompt for the chat agent this UI fronts.
DATA-ROOT is the harness data directory as the agent's container sees it;
the repository itself is bind-mounted at /app (compose.sm-harness-web-ui.yaml)."
  (format nil
          "You are the chat agent of the sm-harness web UI, running inside ~
its app container. The project repository (claude-agent-sdk-cl, sm-harness, ~
sm-harness-web-ui — Common Lisp) is mounted read-write at /app, and durable ~
harness state lives under ~A.~2%~
Project documentation lives in /app/docs/. When the user gives you a ~
session id (they look like sess-<digits>-<digits>, and the chat header ~
shows a copyable one) and asks you to debug or investigate it, do not ~
guess: first list /app/docs/ and read the docs that currently exist there ~
that bear on the question — start with sm-harness.md and ~
sm-harness-web-ui.md — then read that session's transcript file at ~
~:*~Aweb/sessions/<session-id>.json. Session ids map one-to-one onto those ~
files, and ~:*~Aweb/index.json lists every session.~2%~
You are running inside the very sbcl process that serves this web UI ~
(PID 1). Never kill or restart that process from bash: it takes down ~
the UI, this session, and every other open session mid-turn, and the ~
bash tool rejects kill/pkill/killall commands that would hit it (see ~
issue #101). To make your Lisp source edits take effect in this ~
harness, call the reload_harness tool instead. Starting and stopping ~
your own scratch sbcl servers to test changes is fine -- stop them by ~
their specific PID, or with a pkill pattern that cannot match this ~
process's own command line."
          (namestring (uiop:ensure-directory-pathname data-root))))

(defun main ()
  "Docker entrypoint helper."
  ;; reload_harness (issue #65) targets this system, not bare sm-harness:
  ;; ASDF's own dependency graph then transitively covers sm-harness and
  ;; claude-agent-sdk-cl too in a single call.
  (setf sm-harness:*reload-harness-system* :sm-harness-web-ui)
  (let* ((data (or (uiop:getenv "SM_HARNESS_DATA") "/data"))
         (port (parse-integer (or (uiop:getenv "SM_HARNESS_PORT") "8080")))
         (host (or (uiop:getenv "SM_HARNESS_HOST") "0.0.0.0"))
         (fixture (equal (uiop:getenv "WEB_UI_E2E") "1"))
         (read-recovery (equal (uiop:getenv "E2E_SCENARIO") "read-recovery"))
         ;; Resolved once: the CLOG static root and the E2E contract's home
         ;; must be the same directory, or the fixture contract is written
         ;; where no route serves it (#90 moved the default off /app/static).
         (static-root (uiop:ensure-directory-pathname
                       (or (uiop:getenv "SM_HARNESS_STATIC_ROOT")
                           "/app/static/")))
         (hcfg (sm-harness:make-harness-config
                :data-root data
                :project-key "web"
                :idle-ttl-seconds (if read-recovery 1 1800)
                :system-prompt (%chat-agent-system-prompt data)
                :transport-factory (when fixture (%fixture-transport-factory))))
         (harness (sm-harness:make-harness
                   :config hcfg
                   :catalog (when fixture (e2e-fixture-catalog)))))
    (when fixture
      (let ((writer (find-symbol "WRITE-E2E-CONTRACT" :sm-harness-web-ui)))
        (unless (and writer (fboundp writer))
          (error "WEB_UI_E2E requires the sm-harness-web-ui/e2e-contract ASDF system"))
        (funcall (symbol-function writer)
                 (merge-pathnames "e2e-contract.json" static-root))))
    (start-web-ui :harness harness
                  :config (make-web-ui-config
                           :host host :port port
                           ;; Overridable because the image assembles CLOG's
                           ;; static files outside /app (#90): a bind-mounted
                           ;; repo at /app would shadow a baked /app/static.
                           :static-root static-root)
                  :fixture-p fixture)
    (%run-until-shutdown)))

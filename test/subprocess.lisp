(in-package #:claude-agent-sdk-cl/tests)

(def-suite :claude-agent-sdk-cl/subprocess :in :claude-agent-sdk-cl/tests)
(in-suite :claude-agent-sdk-cl/subprocess)

(defun descendant-pid-from-file (path)
  (loop repeat 50
        do (when (probe-file path)
             (with-open-file (stream path :direction :input)
               (let ((line (read-line stream nil nil)))
                 (when (and line (> (length line) 0))
                   (return (parse-integer line))))))
           (sleep 0.02)
        finally (error "Fake descendant did not write PID file: ~A" path)))

(defun descendant-running-p (pid)
  ;; A zombie is terminated even if its container init has not reaped it yet.
  (let ((stat (format nil "/proc/~D/stat" pid)))
    (and (probe-file stat)
         (with-open-file (stream stat :direction :input)
           (let ((line (read-line stream nil "")))
             (not (search ") Z " line)))))))

(defun wait-for-descendant-exit (pid)
  (loop repeat 50
        unless (descendant-running-p pid) do (return t)
        do (sleep 0.02)
        finally (return nil)))

(defun kill-fixture-pid (pid)
  (when (and pid (descendant-running-p pid))
    (ignore-errors
      (uiop:run-program (list "/usr/bin/kill" "-KILL" (princ-to-string pid))
                        :ignore-error-status t))))

(defun process-identity-from-file (path)
  (loop repeat 50
        do (when (probe-file path)
             (with-open-file (stream path :direction :input)
               (let ((line (read-line stream nil nil)))
                 (when (and line (> (length line) 0))
                   (let ((fields (uiop:split-string line :separator '(#\Space #\Tab))))
                     (when (= 4 (length fields))
                       (return (mapcar #'parse-integer fields))))))))
           (sleep 0.02)
        finally (error "Fake CLI did not write process identity: ~A" path)))

(test cli-command-uses-reapable-process-supervisor
  (let ((command (claude-agent-sdk-cl::cli-process-command
                  "/workspace/test/fake-claude.sh" '("ok"))))
    (is (string= claude-agent-sdk-cl::+cli-process-supervisor+ (first command)))
    (is (string= "/workspace/test/fake-claude.sh" (second command)))
    (is (equal '("ok") (cddr command)))))

(test supervisor-creates-dedicated-cli-session-and-group
  (let* ((identity-file (format nil "/tmp/claude-sdk-process-identity-~D.txt"
                                (random most-positive-fixnum)))
         (transport (claude-agent-sdk-cl::make-subprocess-transport
                     "/workspace/test/fake-claude.sh"
                     (list "process-identity-wait" identity-file)))
         (identity nil))
    (unwind-protect
         (progn
           (claude-agent-sdk-cl::start-subprocess transport)
           (setf identity (process-identity-from-file identity-file))
           (destructuring-bind (cli-pid parent-pid process-group session) identity
             (let ((supervisor-pid
                     (uiop:process-info-pid
                      (claude-agent-sdk-cl::subprocess-transport-process transport))))
               (is (= cli-pid process-group))
               (is (= cli-pid session))
               (is (= supervisor-pid parent-pid))
               (is (/= cli-pid supervisor-pid))
               (is-true (claude-agent-sdk-cl::close-subprocess transport))
               (is-true (wait-for-descendant-exit cli-pid))
               (is-true (claude-agent-sdk-cl::close-subprocess transport)))))
      (ignore-errors (claude-agent-sdk-cl::close-subprocess transport))
      (ignore-errors (delete-file identity-file)))))

(test explicit-cli-path-runs-the-fake-cli
  (let ((result (claude-agent-sdk-cl::run-cli "/workspace/test/fake-claude.sh" '("ok"))))
    (is (= 0 (getf result :exit-code)))
    (is (search "fake response" (getf result :stdout)))
    (is (string= "" (getf result :stderr)))))

(test fake-cli-nonzero-exit-preserves-stderr
  (let ((result (claude-agent-sdk-cl::run-cli "/workspace/test/fake-claude.sh" '("fail"))))
    (is (= 23 (getf result :exit-code)))
    (is (search "fake cli failed" (getf result :stderr)))))

(defparameter *large-output-bytes* 2097152
  "Byte size the `large-output'/`interleaved-output' fake-CLI modes emit on each
of stdout and stderr. Kept in sync with test/fake-claude.sh (which hardcodes
2097152); update both together.")

(test subprocess-drains-large-and-interleaved-output
  (dolist (mode '("large-output" "interleaved-output"))
    (let ((result (claude-agent-sdk-cl::run-cli "/workspace/test/fake-claude.sh" (list mode) :timeout 10)))
      (is (= 0 (getf result :exit-code)))
      (is (= *large-output-bytes* (length (getf result :stdout))))
      (is (= *large-output-bytes* (length (getf result :stderr)))))))

(test transport-logger-keeps-full-lifecycle-payloads
  (let* ((events '())
         (claude-agent-sdk-cl::*transport-log-function*
           (lambda (event) (push event events))))
    (claude-agent-sdk-cl::run-cli "/workspace/test/fake-claude.sh" '("echo") :input "raw prompt")
    (setf events (nreverse events))
    (is (equal '(:cli.resolve :cli.spawn :cli.stdin.closed :cli.exit :cli.close)
               (mapcar (lambda (event) (getf event :event)) events)))
    (is (equal '("echo") (getf (second events) :arguments)))
    (is (string= "raw prompt" (getf (third events) :input)))
    (is (search "raw prompt" (getf (fourth events) :stdout)))
    (is (eq t (getf (fifth events) :waited-before-close)))
    (is (null (getf (fifth events) :alive-before-close)))
    (is (= 0 (getf (fifth events) :exit-code)))))

(test subprocess-drains-while-writing-large-stdin
  ;; Child writes 256 KiB to stdout before reading stdin; parent writes a large
  ;; stdin payload. Readers must run concurrently with the stdin write or both
  ;; sides deadlock on full pipes.
  (let ((input (make-string 262144 :initial-element #\i)))
    (let ((result (claude-agent-sdk-cl::run-cli
                   "/workspace/test/fake-claude.sh" '("write-before-read")
                   :input input :timeout 5)))
      (is (= 0 (getf result :exit-code)))
      (is (= 262144 (length (getf result :stdout)))))))

(test subprocess-preserves-exact-stdin
  (dolist (input (list "" "hello"
                       (format nil "hello~%")
                       (format nil "line1~%line2")
                       "café λ"))
    (let ((result (claude-agent-sdk-cl::run-cli
                   "/workspace/test/fake-claude.sh" '("raw-stdin") :input input)))
      (is (= 0 (getf result :exit-code)))
      (is (string= input (getf result :stdout)))))
  (let ((result (claude-agent-sdk-cl::run-cli
                 "/workspace/test/fake-claude.sh" '("raw-stdin"))))
    (is (= 0 (getf result :exit-code)))
    (is (string= "" (getf result :stdout)))))

(test fake-cli-reads-stdin
  (let ((result (claude-agent-sdk-cl::run-cli "/workspace/test/fake-claude.sh" '("echo") :input "hello")))
    (is (= 0 (getf result :exit-code)))
    (is (search "hello" (getf result :stdout)))))

(test subprocess-close-is-idempotent
  (let ((transport (claude-agent-sdk-cl::make-subprocess-transport
                    "/workspace/test/fake-claude.sh" '("sleep"))))
    (claude-agent-sdk-cl::start-subprocess transport)
    (is-true (claude-agent-sdk-cl::close-subprocess transport))
    (is-true (claude-agent-sdk-cl::close-subprocess transport))))

(test transport-logger-orders-timeout-before-close
  (let* ((events '())
         (claude-agent-sdk-cl::*transport-log-function*
           (lambda (event) (push event events))))
    (signals claude-agent-sdk-cl::process-error
      (claude-agent-sdk-cl::run-cli "/workspace/test/fake-claude.sh" '("sleep") :timeout 0.05))
    (setf events (nreverse events))
    (let ((names (mapcar (lambda (event) (getf event :event)) events)))
      (is (= 1 (count :cli.timeout names)))
      (is (= 1 (count :cli.close names)))
      (is (eq :cli.close (car (last names))))
      (is (< (position :cli.timeout names) (position :cli.close names))))))

(test subprocess-timeout-kills-descendant-tree
  ;; RED for #17: direct-child-only cleanup leaves this synthetic descendant alive.
  ;; The second case ignores TERM, proving the bounded KILL escalation.
  (dolist (mode '("term" "ignore-term"))
    (let* ((pid-file (format nil "/tmp/claude-sdk-descendant-~D.pid"
                             (random most-positive-fixnum)))
           (pid nil))
      (unwind-protect
           (progn
             (signals claude-agent-sdk-cl::process-error
               (claude-agent-sdk-cl::run-cli "/workspace/test/fake-claude.sh"
                                              (list "descendant-wait" pid-file mode)
                                              :timeout 0.5))
             (setf pid (descendant-pid-from-file pid-file))
             (is-true (wait-for-descendant-exit pid)))
        (kill-fixture-pid pid)
        (ignore-errors (delete-file pid-file))))))

(test subprocess-close-kills-descendant-tree
  (let* ((pid-file (format nil "/tmp/claude-sdk-close-descendant-~D.pid"
                           (random most-positive-fixnum)))
         (transport (claude-agent-sdk-cl::make-subprocess-transport
                     "/workspace/test/fake-claude.sh"
                     (list "descendant-wait" pid-file "ignore-term")))
         (pid nil))
    (unwind-protect
         (progn
           (claude-agent-sdk-cl::start-subprocess transport)
           (setf pid (descendant-pid-from-file pid-file))
           (is-true (claude-agent-sdk-cl::close-subprocess transport))
           (is-true (wait-for-descendant-exit pid))
           (is-true (claude-agent-sdk-cl::close-subprocess transport)))
      (kill-fixture-pid pid)
      (ignore-errors (delete-file pid-file)))))

(test subprocess-timeout-signals-process-error
  (signals claude-agent-sdk-cl::process-error
    (claude-agent-sdk-cl::run-cli "/workspace/test/fake-claude.sh" '("sleep") :timeout 0.05)))

(test run-cli-validates-timeout-before-spawn
  ;; Invalid timeouts must be rejected before CLI resolution/spawn: a bogus CLI
  ;; path still yields sdk-input-error, not cli-not-found-error, and emits no
  ;; lifecycle events.
  (dolist (bad '(0 -1 "soon"))
    (let* ((events '())
           (claude-agent-sdk-cl::*transport-log-function*
             (lambda (event) (push event events))))
      (signals claude-agent-sdk-cl::sdk-input-error
        (claude-agent-sdk-cl::run-cli "/no/such/cli" '("ok") :timeout bad))
      (is (null events))))
  ;; Positive integer and positive fractional timeouts are both valid.
  (dolist (good '(5 0.5 1.5d0))
    (let ((result (claude-agent-sdk-cl::run-cli
                   "/workspace/test/fake-claude.sh" '("ok") :timeout good)))
      (is (= 0 (getf result :exit-code)))))
  ;; nil means no timeout and runs normally.
  (let ((result (claude-agent-sdk-cl::run-cli
                 "/workspace/test/fake-claude.sh" '("ok") :timeout nil)))
    (is (= 0 (getf result :exit-code)))))

(test run-cli-recovers-after-timeout
  (signals claude-agent-sdk-cl::process-error
    (claude-agent-sdk-cl::run-cli "/workspace/test/fake-claude.sh" '("sleep") :timeout 0.05))
  ;; A fresh call after a timeout must succeed with no lingering state.
  (let ((result (claude-agent-sdk-cl::run-cli
                 "/workspace/test/fake-claude.sh" '("ok") :timeout 5)))
    (is (= 0 (getf result :exit-code)))
    (is (search "fake response" (getf result :stdout)))))

(test cli-discovery-precedence-and-validation
  ;; Explicit executable path wins even when the PATH resolver would fail.
  (let ((claude-agent-sdk-cl::*cli-path-resolver* (lambda () nil)))
    (is (search "fake-claude.sh"
                (claude-agent-sdk-cl::resolve-cli-path "/workspace/test/fake-claude.sh"))))
  ;; Injected PATH resolver succeeds without mutating the process PATH.
  (let ((claude-agent-sdk-cl::*cli-path-resolver*
          (lambda () "/workspace/test/fake-claude.sh")))
    (is (search "fake-claude.sh" (claude-agent-sdk-cl::resolve-cli-path))))
  ;; Injected PATH resolver returning nil signals the typed condition.
  (let ((claude-agent-sdk-cl::*cli-path-resolver* (lambda () nil)))
    (signals claude-agent-sdk-cl::cli-not-found-error
      (claude-agent-sdk-cl::resolve-cli-path)))
  ;; Explicit directory is rejected.
  (signals claude-agent-sdk-cl::cli-not-found-error
    (claude-agent-sdk-cl::resolve-cli-path "/workspace/test/"))
  ;; Explicit directory WITHOUT trailing slash is rejected too (syntax-only
  ;; directory-pathname-p would miss this).
  (signals claude-agent-sdk-cl::cli-not-found-error
    (claude-agent-sdk-cl::resolve-cli-path "/workspace/test"))
  ;; Explicit non-executable regular file is rejected.
  (signals claude-agent-sdk-cl::cli-not-found-error
    (claude-agent-sdk-cl::resolve-cli-path "/workspace/test/subprocess.lisp")))

(test cli-discovery-logs-source-and-does-not-shell-explicit-path
  (let* ((events '())
         (claude-agent-sdk-cl::*transport-log-function*
           (lambda (event) (push event events)))
         (claude-agent-sdk-cl::*cli-path-resolver* (lambda () nil)))
    ;; A path containing shell metacharacters must be treated literally, never
    ;; interpreted; it simply fails validation rather than executing anything.
    (signals claude-agent-sdk-cl::cli-not-found-error
      (claude-agent-sdk-cl::resolve-cli-path "/workspace/test/nope; touch /tmp/pwned"))
    (is (eq :explicit (getf (first (nreverse events)) :source)))
    (is (not (probe-file "/tmp/pwned")))))

(test missing-cli-signals-typed-condition
  (signals claude-agent-sdk-cl::cli-not-found-error
    (claude-agent-sdk-cl::resolve-cli-path "/does/not/exist")))

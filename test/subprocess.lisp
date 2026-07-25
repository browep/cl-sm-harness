(in-package #:claude-agent-sdk-cl/tests)

(def-suite :claude-agent-sdk-cl/subprocess :in :claude-agent-sdk-cl/tests)
(in-suite :claude-agent-sdk-cl/subprocess)

(test explicit-cli-path-runs-the-fake-cli
  (let ((result (claude-agent-sdk-cl::run-cli "/workspace/test/fake-claude.sh" '("ok"))))
    (is (= 0 (getf result :exit-code)))
    (is (search "fake response" (getf result :stdout)))
    (is (string= "" (getf result :stderr)))))

(test fake-cli-nonzero-exit-preserves-stderr
  (let ((result (claude-agent-sdk-cl::run-cli "/workspace/test/fake-claude.sh" '("fail"))))
    (is (= 23 (getf result :exit-code)))
    (is (search "fake cli failed" (getf result :stderr)))))

(test subprocess-drains-large-and-interleaved-output
  (dolist (mode '("large-output" "interleaved-output"))
    (let ((result (claude-agent-sdk-cl::run-cli "/workspace/test/fake-claude.sh" (list mode) :timeout 2)))
      (is (= 0 (getf result :exit-code)))
      (is (= 131072 (length (getf result :stdout))))
      (is (= 131072 (length (getf result :stderr)))))))

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

(test subprocess-timeout-signals-process-error
  (signals claude-agent-sdk-cl::process-error
    (claude-agent-sdk-cl::run-cli "/workspace/test/fake-claude.sh" '("sleep") :timeout 0.05)))

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

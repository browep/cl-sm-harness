(in-package #:claude-agent-sdk-cl)

(defvar *cli-path-resolver* nil
  "When non-NIL, a thunk returning a candidate CLI namestring for PATH discovery.
Bound in tests for deterministic discovery without mutating the process PATH.")

(defun default-cli-path-resolver ()
  "Discover `claude' on PATH. Explicit paths never pass through this function."
  (ignore-errors
    (string-trim '(#\Space #\Newline #\Return)
                 (uiop:run-program '("sh" "-c" "command -v claude") :output :string))))

(defun executable-file-p (path)
  "True only when PATH names an existing, executable, regular file.
Uses POSIX `test -f'/`test -x' (filesystem type, not pathname syntax) and never
routes the path through a shell, so metacharacters stay literal."
  (and path
       (let ((name (namestring (uiop:ensure-pathname path))))
         (and (zerop (nth-value 2 (uiop:run-program (list "test" "-f" name)
                                                    :ignore-error-status t)))
              (zerop (nth-value 2 (uiop:run-program (list "test" "-x" name)
                                                    :ignore-error-status t)))))))

(defun resolve-cli-path (&optional explicit-cli-path)
  "Resolve configured CLI path, otherwise PATH; no bundled-CLI packaging claim.
Explicit paths are validated directly and never routed through a shell."
  (multiple-value-bind (candidate source)
      (if explicit-cli-path
          (values explicit-cli-path :explicit)
          (values (funcall (or *cli-path-resolver* #'default-cli-path-resolver)) :path))
    (unless (executable-file-p candidate)
      (emit-transport-log :cli.resolve :source source
                                       :configured-path explicit-cli-path
                                       :candidate-path candidate
                                       :resolved-path nil)
      (error 'cli-not-found-error
             :message "Claude Code not found; provide an executable cli-path or install claude on PATH."))
    (let ((resolved (namestring (truename candidate))))
      (emit-transport-log :cli.resolve :source source
                                       :configured-path explicit-cli-path
                                       :candidate-path candidate
                                       :resolved-path resolved)
      resolved)))

(defun transport-reproducibility-context (&optional cli-path)
  "Collect non-secret runtime context for transport diagnostics."
  (labels ((command-output (command)
             (handler-case
                 (string-trim '(#\Space #\Newline #\Return)
                              (uiop:run-program command :output :string :ignore-error-status t))
               (error () nil))))
    (list :sdk-version (sdk-version)
          :sbcl-version (lisp-implementation-version)
          :os (software-type)
          :architecture (machine-type)
          :git-commit (command-output '("git" "rev-parse" "HEAD"))
          :cli-version (and cli-path (command-output (list cli-path "--version")))
          :mode (if (string= (or (uiop:getenv "CLAUDE_SDK_LIVE_TEST") "") "1") :live :offline))))

(defun cli-process-command (resolved-cli arguments)
  "Return the direct CLI command. Process-group isolation requires a verified
platform-specific launcher and is deliberately not enabled until #17 proves it."
  (cons resolved-cli arguments))

(defun terminate-cli-process-tree (process)
  "Terminate the direct child; descendant-group cleanup remains #17 work."
  (ignore-errors (uiop:terminate-process process)))

(defstruct (subprocess-transport (:constructor make-subprocess-transport (cli-path arguments)))
  cli-path arguments process (closed-p nil) (waited-p nil) exit-code)

(defun start-subprocess (transport)
  (unless (subprocess-transport-process transport)
    (let* ((resolved (resolve-cli-path (subprocess-transport-cli-path transport)))
           (command (cli-process-command resolved
                                         (subprocess-transport-arguments transport)))
           (context (transport-reproducibility-context resolved)))
      (setf (subprocess-transport-process transport)
            (uiop:launch-program command :input :stream :output :stream :error-output :stream))
      (emit-transport-log :cli.spawn :command command :arguments (subprocess-transport-arguments transport)
                           :reproducibility context)))
  transport)

(defun close-subprocess (transport)
  (unless (subprocess-transport-closed-p transport)
    (let ((process (subprocess-transport-process transport))
          (alive-before nil)
          (waited-before (subprocess-transport-waited-p transport)))
      (when (and process (not waited-before))
        (setf alive-before (uiop:process-alive-p process))
        (when alive-before
          (terminate-cli-process-tree process))
        (setf (subprocess-transport-exit-code transport) (uiop:wait-process process)
              (subprocess-transport-waited-p transport) t))
      (setf (subprocess-transport-closed-p transport) t)
      (emit-transport-log :cli.close
                          :alive-before-close alive-before
                          :waited-before-close waited-before
                          :exit-code (subprocess-transport-exit-code transport))))
  t)

(defun validate-timeout (timeout)
  "Accept NIL (no timeout) or a positive real timeout in seconds; else signal."
  (unless (or (null timeout)
              (and (realp timeout) (plusp timeout)))
    (signal-sdk-input-error "timeout must be NIL or a positive real number of seconds"))
  timeout)

(defun run-cli (cli-path arguments &key timeout input)
  ;; Validate BEFORE any spawn/resolve/logging so a bad timeout can never leave
  ;; a child process or partial lifecycle events behind.
  (validate-timeout timeout)
  (let* ((transport (make-subprocess-transport cli-path arguments))
         (process (progn (start-subprocess transport)
                         (subprocess-transport-process transport)))
         (stdout nil)
         (stderr nil)
         (stdin-closed-p nil))
    ;; Start readers BEFORE writing stdin: a child that writes stdout before
    ;; reading stdin will otherwise fill its stdout pipe and deadlock against
    ;; the parent's blocking stdin write.
    (let ((stdout-reader (sb-thread:make-thread
                          (lambda () (setf stdout (uiop:slurp-stream-string
                                                   (uiop:process-info-output process))))))
          (stderr-reader (sb-thread:make-thread
                          (lambda () (setf stderr (uiop:slurp-stream-string
                                                   (uiop:process-info-error-output process)))))))
      (labels ((close-stdin-once ()
                 ;; Single-threaded: with-timeout is synchronous, so the main
                 ;; path and the timeout handler never touch this concurrently.
                 (unless stdin-closed-p
                   (ignore-errors (close (uiop:process-info-input process)))
                   (setf stdin-closed-p t)
                   (emit-transport-log :cli.stdin.closed :input input)))
               (write-and-close-stdin ()
                 (unwind-protect
                      (when input
                        (write-string input (uiop:process-info-input process)))
                   (close-stdin-once)))
               (write-then-wait ()
                 (write-and-close-stdin)
                 (uiop:wait-process process))
               (join-readers ()
                 (sb-thread:join-thread stdout-reader)
                 (sb-thread:join-thread stderr-reader)))
        (handler-case
            ;; The timeout intentionally covers the stdin write too, so a child
            ;; that never drains stdin cannot hang the parent indefinitely.
            (let ((exit-code (if timeout
                                 (sb-ext:with-timeout timeout (write-then-wait))
                                 (write-then-wait))))
              (setf (subprocess-transport-exit-code transport) exit-code
                    (subprocess-transport-waited-p transport) t)
              (join-readers)
              (emit-transport-log :cli.exit :exit-code exit-code :stdout stdout :stderr stderr)
              (close-subprocess transport)
              (list :exit-code exit-code :stdout stdout :stderr stderr))
          (sb-ext:timeout ()
            ;; Do NOT re-enter the stdin write here: it may already be blocked
            ;; on a child that never drains stdin. Only ensure stdin is closed.
            (close-stdin-once)
            (when (uiop:process-alive-p process)
              (terminate-cli-process-tree process))
            (setf (subprocess-transport-exit-code transport) (uiop:wait-process process)
                  (subprocess-transport-waited-p transport) t)
            (join-readers)
            (emit-transport-log :cli.timeout :timeout timeout :stdout stdout :stderr stderr
                                             :exit-code (subprocess-transport-exit-code transport))
            (close-subprocess transport)
            (signal-process-error "Claude CLI timed out" 124 "timeout")))))))

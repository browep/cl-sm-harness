(in-package #:claude-agent-sdk-cl)

(defvar *transport-log-function* nil
  "Optional callback receiving full, unredacted transport event plists.")

(defun emit-transport-log (event &rest fields)
  (when *transport-log-function*
    (funcall *transport-log-function* (list* :event event fields))))

(defun resolve-cli-path (&optional explicit-cli-path)
  "Resolve configured CLI path, otherwise PATH; no bundled-CLI packaging claim."
  (let ((candidate (or explicit-cli-path
                       (ignore-errors
                         (string-trim '(#\Space #\Newline #\Return)
                                      (uiop:run-program '("sh" "-c" "command -v claude") :output :string))))))
    (unless (and candidate (probe-file candidate))
      (error 'cli-not-found-error :message "Claude Code not found; provide an executable cli-path or install claude on PATH."))
    (let ((resolved (namestring (truename candidate))))
      (emit-transport-log :cli.resolve :configured-path explicit-cli-path :resolved-path resolved)
      resolved)))

(defstruct (subprocess-transport (:constructor make-subprocess-transport (cli-path arguments)))
  cli-path arguments process (closed-p nil))

(defun start-subprocess (transport)
  (unless (subprocess-transport-process transport)
    (let ((command (cons (resolve-cli-path (subprocess-transport-cli-path transport))
                         (subprocess-transport-arguments transport))))
      (setf (subprocess-transport-process transport)
            (uiop:launch-program command :input :stream :output :stream :error-output :stream))
      (emit-transport-log :cli.spawn :command command :arguments (subprocess-transport-arguments transport))))
  transport)

(defun close-subprocess (transport)
  (unless (subprocess-transport-closed-p transport)
    (let ((process (subprocess-transport-process transport)))
      (when (and process (uiop:process-alive-p process))
        (uiop:terminate-process process))
      (when process (uiop:wait-process process)))
    (setf (subprocess-transport-closed-p transport) t))
  t)

(defun run-cli (cli-path arguments &key timeout input)
  (let* ((transport (make-subprocess-transport cli-path arguments))
         (process (progn (start-subprocess transport) (subprocess-transport-process transport)))
         (stdout nil)
         (stderr nil))
    (when input
      (write-string input (uiop:process-info-input process))
      (terpri (uiop:process-info-input process)))
    (close (uiop:process-info-input process))
    (emit-transport-log :cli.stdin.closed :input input)
    ;; Drain both pipes while the child runs; waiting first can deadlock once
    ;; either OS pipe fills.
    (let ((stdout-reader (sb-thread:make-thread
                          (lambda () (setf stdout (uiop:slurp-stream-string
                                                   (uiop:process-info-output process))))))
          (stderr-reader (sb-thread:make-thread
                          (lambda () (setf stderr (uiop:slurp-stream-string
                                                   (uiop:process-info-error-output process)))))))
      (handler-case
          (let ((exit-code (if timeout
                               (sb-ext:with-timeout timeout (uiop:wait-process process))
                               (uiop:wait-process process))))
            (sb-thread:join-thread stdout-reader)
            (sb-thread:join-thread stderr-reader)
            (emit-transport-log :cli.exit :exit-code exit-code :stdout stdout :stderr stderr)
            (list :exit-code exit-code :stdout stdout :stderr stderr))
        (sb-ext:timeout ()
          (close-subprocess transport)
          (sb-thread:join-thread stdout-reader)
          (sb-thread:join-thread stderr-reader)
          (emit-transport-log :cli.timeout :timeout timeout :stdout stdout :stderr stderr)
          (signal-process-error "Claude CLI timed out" 124 "timeout"))))))

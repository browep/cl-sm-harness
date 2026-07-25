(in-package #:claude-agent-sdk-cl)

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
  cli-path arguments process (closed-p nil) (waited-p nil) exit-code)

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
    (let ((process (subprocess-transport-process transport))
          (alive-before nil)
          (waited-before (subprocess-transport-waited-p transport)))
      (when (and process (not waited-before))
        (setf alive-before (uiop:process-alive-p process))
        (when alive-before
          (uiop:terminate-process process))
        (setf (subprocess-transport-exit-code transport) (uiop:wait-process process)
              (subprocess-transport-waited-p transport) t))
      (setf (subprocess-transport-closed-p transport) t)
      (emit-transport-log :cli.close
                          :alive-before-close alive-before
                          :waited-before-close waited-before
                          :exit-code (subprocess-transport-exit-code transport))))
  t)

(defun run-cli (cli-path arguments &key timeout input)
  (let* ((transport (make-subprocess-transport cli-path arguments))
         (process (progn (start-subprocess transport) (subprocess-transport-process transport)))
         (stdout nil)
         (stderr nil))
    (when input
      (write-string input (uiop:process-info-input process)))
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
            (setf (subprocess-transport-exit-code transport) exit-code
                  (subprocess-transport-waited-p transport) t)
            (sb-thread:join-thread stdout-reader)
            (sb-thread:join-thread stderr-reader)
            (emit-transport-log :cli.exit :exit-code exit-code :stdout stdout :stderr stderr)
            (close-subprocess transport)
            (list :exit-code exit-code :stdout stdout :stderr stderr))
        (sb-ext:timeout ()
          (when (uiop:process-alive-p process)
            (uiop:terminate-process process))
          (setf (subprocess-transport-exit-code transport) (uiop:wait-process process)
                (subprocess-transport-waited-p transport) t)
          (sb-thread:join-thread stdout-reader)
          (sb-thread:join-thread stderr-reader)
          (emit-transport-log :cli.timeout :timeout timeout :stdout stdout :stderr stderr
                                           :exit-code (subprocess-transport-exit-code transport))
          (close-subprocess transport)
          (signal-process-error "Claude CLI timed out" 124 "timeout"))))))

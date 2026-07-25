(in-package #:claude-agent-sdk-cl)

(defun resolve-cli-path (&optional explicit-cli-path)
  "Resolve configured CLI path, otherwise PATH; no bundled-CLI packaging claim."
  (let ((candidate (or explicit-cli-path
                       (ignore-errors
                         (string-trim '(#\Space #\Newline #\Return)
                                      (uiop:run-program '("sh" "-c" "command -v claude") :output :string))))))
    (unless (and candidate (probe-file candidate))
      (error 'cli-not-found-error :message "Claude Code not found; provide an executable cli-path or install claude on PATH."))
    (namestring (truename candidate))))

(defstruct (subprocess-transport (:constructor make-subprocess-transport (cli-path arguments)))
  cli-path arguments process (closed-p nil))

(defun start-subprocess (transport)
  (unless (subprocess-transport-process transport)
    (setf (subprocess-transport-process transport)
          (uiop:launch-program (cons (resolve-cli-path (subprocess-transport-cli-path transport))
                                     (subprocess-transport-arguments transport))
                               :input :stream :output :stream :error-output :stream)))
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
         (process (progn (start-subprocess transport) (subprocess-transport-process transport))))
    (when input
      (write-string input (uiop:process-info-input process))
      (terpri (uiop:process-info-input process)))
    (close (uiop:process-info-input process))
    (handler-case
        (let ((exit-code (if timeout
                             (sb-ext:with-timeout timeout (uiop:wait-process process))
                             (uiop:wait-process process))))
          (list :exit-code exit-code
                :stdout (uiop:slurp-stream-string (uiop:process-info-output process))
                :stderr (uiop:slurp-stream-string (uiop:process-info-error-output process))))
      (sb-ext:timeout ()
        (close-subprocess transport)
        (signal-process-error "Claude CLI timed out" 124 "timeout")))))

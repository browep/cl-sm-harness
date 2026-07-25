(in-package #:claude-agent-sdk-cl)

(defun resolve-cli-path (&optional explicit-cli-path)
  "Resolve the configured CLI path, otherwise search PATH.
The port deliberately uses a configured/system executable; it does not claim
parity with upstream Python's wheel-bundled CLI packaging."
  (let ((candidate (or explicit-cli-path
                       (ignore-errors
                         (string-trim '(#\Space #\Newline #\Return)
                                      (uiop:run-program '("sh" "-c" "command -v claude") :output :string))))))
    (unless (and candidate (probe-file candidate))
      (error 'cli-not-found-error
             :message "Claude Code not found; provide an executable cli-path or install claude on PATH."))
    (namestring (truename candidate))))

(defun run-cli (cli-path arguments)
  "Run CLI-PATH with ARGUMENTS and return a redacted process result plist.
This synchronous primitive is intentionally only the deterministic foundation
for the streaming transport added in the next Phase 4 slice."
  (let* ((program (resolve-cli-path cli-path))
         (process (uiop:launch-program (cons program arguments)
                                       :input nil :output :stream :error-output :stream))
         (exit-code (uiop:wait-process process))
         (stdout (uiop:slurp-stream-string (uiop:process-info-output process)))
         (stderr (uiop:slurp-stream-string (uiop:process-info-error-output process))))
    (list :exit-code exit-code :stdout stdout :stderr stderr)))

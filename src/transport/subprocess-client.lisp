(in-package #:claude-agent-sdk-cl)

;;;; Persistent subprocess transport for Phase 6 interactive clients.
;;;; Stdout is read synchronously by the client, preserving response backpressure;
;;;; stderr alone is drained in a worker so it cannot fill its pipe.

(defclass subprocess-client-transport (client-transport)
  ((cli-path :initarg :cli-path :reader sct-cli-path)
   (arguments :initarg :arguments :initform nil :reader sct-arguments)
   (process :initform nil :accessor sct-process)
   (stdout :initform nil :accessor sct-stdout)
   (stderr :initform "" :accessor sct-stderr)
   (stderr-thread :initform nil :accessor sct-stderr-thread)
   (read-buffer :initform (make-string 8192) :reader sct-read-buffer)
   (started-p :initform nil :accessor sct-started-p)
   (closed-p :initform nil :accessor sct-closed-p)
   (waited-p :initform nil :accessor sct-waited-p)
   (exit-code :initform nil :accessor sct-exit-code)))

(defun make-subprocess-client-transport (&key cli-path arguments timeout)
  "Construct a persistent subprocess client transport.
TIMEOUT is validated now; watchdog behavior is added with the client timeout slice."
  (validate-timeout timeout)
  (make-instance 'subprocess-client-transport :cli-path cli-path :arguments arguments))

(defun make-default-client-transport (options cli-path timeout)
  "Provision the public persistent stream-json CLI transport."
  (make-subprocess-client-transport
   :cli-path cli-path :timeout timeout :arguments (one-shot-query-arguments options)))

(defun %sct-reap (transport)
  (let ((process (sct-process transport)))
    (when (and process (not (sct-waited-p transport)))
      (setf (sct-exit-code transport) (uiop:wait-process process)
            (sct-waited-p transport) t)))
  (sct-exit-code transport))

(defun %sct-join-stderr (transport)
  (let ((thread (sct-stderr-thread transport)))
    (when (and thread (sb-thread:thread-alive-p thread))
      (ignore-errors (sb-thread:join-thread thread)))))

(defmethod start-client-transport ((transport subprocess-client-transport) options)
  (declare (ignore options))
  (unless (sct-started-p transport)
    (setf (sct-started-p transport) t)
    (let* ((command (cons (resolve-cli-path (sct-cli-path transport))
                          (sct-arguments transport)))
           (process (uiop:launch-program command :input :stream :output :stream :error-output :stream)))
      (setf (sct-process transport) process
            (sct-stdout transport) (uiop:process-info-output process))
      (emit-transport-log :client.cli.spawn :command command :arguments (sct-arguments transport))
      ;; Must start before client writes initialize: CLI may fill stderr while
      ;; waiting for stdin, otherwise creating a pipe deadlock.
      (setf (sct-stderr-thread transport)
            (sb-thread:make-thread
             (lambda ()
               (setf (sct-stderr transport)
                     (handler-case
                         (uiop:slurp-stream-string (uiop:process-info-error-output process))
                       (error () ""))))
             :name "sct-stderr-drain"))))
  transport)

(defmethod write-client-input ((transport subprocess-client-transport) input)
  (when (or (sct-closed-p transport) (not (sct-started-p transport)))
    (error 'cli-connection-error :message "Persistent CLI transport is not writable"))
  (let ((process (sct-process transport)))
    (when (and process (not (uiop:process-alive-p process)))
      (%sct-reap transport)
      (error 'process-error :message "Claude CLI exited before client write"
             :exit-code (or (sct-exit-code transport) 1) :stderr (sct-stderr transport)))
    (handler-case
        (let ((stream (uiop:process-info-input process)))
          (write-string input stream)
          (finish-output stream)
          (emit-transport-log :client.cli.stdin :input input)
          t)
      (error (condition)
        (error 'cli-connection-error :message (princ-to-string condition))))))

(defmethod read-client-chunk ((transport subprocess-client-transport))
  (when (sct-closed-p transport) (return-from read-client-chunk nil))
  ;; SBCL character-stream READ-SEQUENCE can wait for the full requested buffer
  ;; on an open pipe. Read one character (blocking only until stream progress),
  ;; then drain immediately available characters. This remains newline-agnostic:
  ;; the client's jsonl-framer, not this transport, owns record boundaries.
  (let* ((stream (sct-stdout transport))
         (first (read-char stream nil nil)))
    (if first
        (let ((chunk
                (with-output-to-string (output)
                  (write-char first output)
                  (loop while (listen stream)
                        for character = (read-char stream nil nil)
                        while character
                        do (write-char character output)))))
          (emit-transport-log :client.cli.stdout.chunk :chunk chunk)
          chunk)
        (progn
          (%sct-reap transport)
          (%sct-join-stderr transport)
          (let ((exit-code (or (sct-exit-code transport) 0)))
            (when (/= exit-code 0)
              (signal-process-error "Claude CLI client exited unsuccessfully" exit-code (sct-stderr transport))))
          nil))))

(defmethod close-client-transport ((transport subprocess-client-transport) &key reason)
  (unless (sct-closed-p transport)
    (setf (sct-closed-p transport) t)
    (let ((process (sct-process transport)))
      ;; Terminate first: that unblocks stdout/stderr readers before join/wait.
      (when (and process (uiop:process-alive-p process))
        (ignore-errors (uiop:terminate-process process)))
      (when process (%sct-reap transport))
      (%sct-join-stderr transport)
      (ignore-errors (close (uiop:process-info-input process)))
      (emit-transport-log :client.cli.close :reason reason
                          :exit-code (sct-exit-code transport)
                          :stderr (sct-stderr transport))))
  t)

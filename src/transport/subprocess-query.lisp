(in-package #:claude-agent-sdk-cl)

;;;; Subprocess-backed streaming `query-transport'.
;;;;
;;;; stdout is read synchronously, on demand, in arbitrary chunks. This preserves
;;;; `query' callback backpressure: a :cancel prevents any later stdout read.
;;;; stderr is drained in a thread and stdin is written in a thread, so a child
;;;; that writes output before consuming a large prompt cannot deadlock the parent.

(defclass subprocess-query-transport (query-transport)
  ((cli-path :initarg :cli-path :reader sqt-cli-path)
   (arguments :initarg :arguments :initform nil :reader sqt-arguments)
   (timeout :initarg :timeout :initform nil :reader sqt-timeout)
   (process :initform nil :accessor sqt-process)
   (stdout :initform nil :accessor sqt-stdout)
   (read-buffer :initform (make-string 8192) :reader sqt-read-buffer)
   (stderr-string :initform nil :accessor sqt-stderr-string)
   (stderr-thread :initform nil :accessor sqt-stderr-thread)
   (stdin-thread :initform nil :accessor sqt-stdin-thread)
   (timeout-thread :initform nil :accessor sqt-timeout-thread)
   (started-p :initform nil :accessor sqt-started-p)
   (eof-p :initform nil :accessor sqt-eof-p)
   (timed-out-p :initform nil :accessor sqt-timed-out-p)
   (waited-p :initform nil :accessor sqt-waited-p)
   (exit-code :initform nil :accessor sqt-exit-code)
   (closed-p :initform nil :accessor sqt-closed-p)))

(defun make-subprocess-query-transport (&key cli-path arguments timeout)
  "Construct a streaming subprocess transport. TIMEOUT is NIL or positive seconds."
  (validate-timeout timeout)
  (make-instance 'subprocess-query-transport
                 :cli-path cli-path :arguments arguments :timeout timeout))

(defun %sqt-reap (transport)
  "Wait for the child once, recording its exit status."
  (let ((process (sqt-process transport)))
    (when (and process (not (sqt-waited-p transport)))
      (setf (sqt-exit-code transport) (uiop:wait-process process)
            (sqt-waited-p transport) t)))
  (sqt-exit-code transport))

(defun %sqt-join-thread (thread)
  (when (and thread (sb-thread:thread-alive-p thread))
    (ignore-errors (sb-thread:join-thread thread))))

(defun %sqt-arm-timeout (transport)
  "Terminate a still-running child after its deadline.

A watchdog is used rather than `sb-ext:with-timeout': an asynchronous timeout
cannot reliably interrupt a blocked read(2), while terminating the child closes
its stdout pipe and unblocks the demand-driven read. The watchdog is deliberately
not joined during normal close; it observes CLOSED-P and exits after its sleep."
  (let ((timeout (sqt-timeout transport)))
    (when timeout
      (setf (sqt-timeout-thread transport)
            (sb-thread:make-thread
             (lambda ()
               (sleep timeout)
               (unless (or (sqt-closed-p transport) (sqt-eof-p transport))
                 (setf (sqt-timed-out-p transport) t)
                 (let ((process (sqt-process transport)))
                   (when (and process (uiop:process-alive-p process))
                     (ignore-errors (uiop:terminate-process process))))))
             :name "sqt-timeout-watchdog")))))

(defmethod start-query-transport ((transport subprocess-query-transport) prompt options)
  (declare (ignore options))
  (when (sqt-started-p transport)
    (return-from start-query-transport transport))
  (setf (sqt-started-p transport) t)
  (let* ((command (cons (resolve-cli-path (sqt-cli-path transport))
                        (sqt-arguments transport)))
         (process (uiop:launch-program command
                                       :input :stream :output :stream :error-output :stream)))
    (setf (sqt-process transport) process
          (sqt-stdout transport) (uiop:process-info-output process))
    (emit-transport-log :cli.spawn :command command :arguments (sqt-arguments transport))
    ;; Start stderr drain before any stdin write. Otherwise a child that fills
    ;; stderr while waiting for input can deadlock the streaming read loop.
    (setf (sqt-stderr-thread transport)
          (sb-thread:make-thread
           (lambda ()
             (setf (sqt-stderr-string transport)
                   (handler-case
                       (uiop:slurp-stream-string (uiop:process-info-error-output process))
                     (error () ""))))
           :name "sqt-stderr-drain"))
    ;; Start stdin writer before reading stdout, but never block the caller on it.
    ;; Input is exact: no implicit newline is appended.
    (setf (sqt-stdin-thread transport)
          (sb-thread:make-thread
           (lambda ()
             (let ((stream (uiop:process-info-input process)))
               (unwind-protect
                    (handler-case
                        (when prompt
                          (write-string prompt stream)
                          (finish-output stream))
                      (error () nil))
                 (ignore-errors (close stream))
                 (emit-transport-log :cli.stdin.closed :input prompt))))
           :name "sqt-stdin-writer"))
    (%sqt-arm-timeout transport)
    transport))

(defun %sqt-read-chunk (transport)
  "Read available stdout bytes. Returns a fresh string, or NIL at EOF.

`read-sequence' is intentional: unlike `read-line', it makes progress on large
unterminated output and lets the JSONL framer own record-boundary handling."
  (let* ((buffer (sqt-read-buffer transport))
         (count (read-sequence buffer (sqt-stdout transport))))
    (if (zerop count) nil (subseq buffer 0 count))))

(defmethod read-query-chunk ((transport subprocess-query-transport))
  (when (sqt-eof-p transport)
    (return-from read-query-chunk nil))
  (let ((chunk (%sqt-read-chunk transport)))
    (when (sqt-timed-out-p transport)
      (%sqt-reap transport)
      (%sqt-join-thread (sqt-stderr-thread transport))
      (emit-transport-log :cli.timeout :timeout (sqt-timeout transport)
                                       :stderr (sqt-stderr-string transport)
                                       :exit-code (sqt-exit-code transport))
      (signal-process-error "Claude CLI query timed out" 124 "timeout"))
    ;; Full unredacted diagnostic record for streaming output. Chunks may split
    ;; JSON records; the logger intentionally receives the raw transport bytes.
    (when chunk
      (emit-transport-log :cli.stdout.chunk :chunk chunk))
    (unless chunk
      (setf (sqt-eof-p transport) t)
      (%sqt-reap transport)
      ;; Joining here makes stderr complete before reporting a nonzero status.
      (%sqt-join-thread (sqt-stderr-thread transport))
      (let ((code (sqt-exit-code transport)))
        (emit-transport-log :cli.exit :exit-code code :stderr (sqt-stderr-string transport))
        (when (and code (not (zerop code)))
          (signal-process-error (format nil "Claude CLI exited with status ~A" code)
                                code (or (sqt-stderr-string transport) "")))))
    chunk))

(defmethod close-query-transport ((transport subprocess-query-transport) &key reason)
  (unless (sqt-closed-p transport)
    (setf (sqt-closed-p transport) t)
    (let ((process (sqt-process transport))
          (alive-before nil))
      (when process
        (setf alive-before (uiop:process-alive-p process))
        ;; Critical ordering: killing the child first breaks any blocked stdin
        ;; write. Joining first can hang forever on a full pipe.
        (when alive-before
          (ignore-errors (uiop:terminate-process process)))
        (%sqt-reap transport))
      (%sqt-join-thread (sqt-stdin-thread transport))
      (%sqt-join-thread (sqt-stderr-thread transport))
      (emit-transport-log :cli.close :reason reason
                                      :alive-before-close alive-before
                                      :exit-code (sqt-exit-code transport))))
  t)

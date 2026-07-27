(in-package #:sm-harness-web-ui)

;;;; Test/E2E-only deterministic SDK transport.  Never loaded by production UI.
(defclass e2e-fake-transport (claude-agent-sdk-cl:client-transport)
  ((chunks :initarg :chunks :accessor e2e-chunks)
   (writes :initform '() :accessor e2e-writes)
   (read-count :initform 0 :accessor e2e-read-count)
   (fail-writes-p :initarg :fail-writes-p :initform nil :accessor e2e-fail-writes-p)
   ;; Lets browser E2E observe the real busy/responding transition without
   ;; arbitrary test-side sleeps.
   (delay-before-second-read-seconds :initarg :delay-before-second-read-seconds
                                     :initform 1
                                     :accessor e2e-delay-before-second-read-seconds)))

(defparameter *e2e-retry-failure-available* t)

(defmethod claude-agent-sdk-cl:start-client-transport ((tport e2e-fake-transport) options)
  (declare (ignore options))
  tport)
(defmethod claude-agent-sdk-cl:read-client-chunk ((tport e2e-fake-transport))
  (when (= (incf (e2e-read-count tport)) 2)
    (sleep (e2e-delay-before-second-read-seconds tport)))
  (pop (e2e-chunks tport)))
(defmethod claude-agent-sdk-cl:write-client-input ((tport e2e-fake-transport) input)
  (push input (e2e-writes tport))
  (when (and *e2e-retry-failure-available*
             (e2e-fail-writes-p tport)
             (search "retry e2e" input))
    (setf *e2e-retry-failure-available* nil
          (e2e-fail-writes-p tport) nil)
    (error "fixture protocol secret: send failed"))
  t)
(defmethod claude-agent-sdk-cl:close-client-transport ((tport e2e-fake-transport) &key reason)
  (declare (ignore reason))
  t)

(defun %e2e-transport-factory (options)
  (declare (ignore options))
  (let ((nl (string #\Newline))
        (long-token (concatenate 'string "unbroken-" (make-string 512 :initial-element #\x))))
    (make-instance 'e2e-fake-transport
                   :fail-writes-p t
                   :chunks
                   (list
                    (concatenate 'string
                     "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"request-1\"}}"
                     nl)
                    (concatenate 'string
                     "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"e2e hello\"}],\"model\":\"fixture\"}}"
                     nl
                     "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"stream two: Unicode ✓\\nsecond line\"}],\"model\":\"fixture\"}}"
                     nl
                     (format nil "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"~A\"}],\"model\":\"fixture\"}}" long-token)
                     nl
                     "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"<script>e2e-xss</script> **not bold** [not-link](javascript:alert(1))\"}],\"model\":\"fixture\"}}"
                     nl
                     "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"session_id\":\"e2e-canon\",\"result\":\"ok\"}"
                     nl)))))

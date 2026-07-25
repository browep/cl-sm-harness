(in-package #:claude-agent-sdk-cl/tests)

(def-suite :claude-agent-sdk-cl/protocol :in :claude-agent-sdk-cl/tests)
(in-suite :claude-agent-sdk-cl/protocol)

(test jsonl-framer-preserves-partial-records
  (let ((framer (claude-agent-sdk-cl::make-jsonl-framer)))
    (is (null (claude-agent-sdk-cl::push-jsonl-chunk framer "{\"id\":\"a")))
    (is (equal '("{\"id\":\"a\"}")
               (claude-agent-sdk-cl::push-jsonl-chunk framer
                                                        (concatenate 'string "\"}" (string #\Newline)))))
    (is (equal '("{\"id\":\"b\"}")
               (claude-agent-sdk-cl::push-jsonl-chunk framer
                                                        (concatenate 'string "{\"id\":\"b\"}" (string #\Return) (string #\Newline)))))
    (is (null (claude-agent-sdk-cl::flush-jsonl-framer framer)))))

(test jsonl-framer-enforces-pending-record-limit-and-recovers
  (let ((framer (claude-agent-sdk-cl::make-jsonl-framer :max-pending-length 4)))
    (signals claude-agent-sdk-cl::cli-json-error
      (claude-agent-sdk-cl::push-jsonl-chunk framer "12345"))
    (is (equal '("{}")
               (claude-agent-sdk-cl::push-jsonl-chunk framer
                                                        (concatenate 'string "{}" (string #\Newline)))))))

(test protocol-router-allocates-and-routes-request-ids
  (let ((router (claude-agent-sdk-cl::make-protocol-router)))
    (is (string= "request-1" (claude-agent-sdk-cl::next-request-id router)))
    (is (string= "request-2" (claude-agent-sdk-cl::next-request-id router)))
    (claude-agent-sdk-cl::register-request router "request-2")
    (multiple-value-bind (record route)
        (claude-agent-sdk-cl::route-protocol-record router
                                                     (claude-agent-sdk-cl::decode-jsonl-record "{\"request_id\":\"request-2\",\"type\":\"result\"}"))
      (is (eq :response route))
      (is (string= "result" (gethash "type" record))))
    (multiple-value-bind (record route)
        (claude-agent-sdk-cl::route-protocol-record router
                                                     (claude-agent-sdk-cl::decode-jsonl-record "{\"type\":\"assistant\"}"))
      (is (eq :event route))
      (is (string= "assistant" (gethash "type" record))))))

(test protocol-logger-captures-full-record-and-route
  (let* ((events '())
         (claude-agent-sdk-cl::*transport-log-function*
           (lambda (event) (push event events)))
         (router (claude-agent-sdk-cl::make-protocol-router))
         (raw "{\"request_id\":\"request-9\",\"type\":\"result\",\"payload\":\"raw value\"}"))
    (claude-agent-sdk-cl::register-request router "request-9")
    (claude-agent-sdk-cl::route-protocol-record router
                                                 (claude-agent-sdk-cl::decode-jsonl-record raw))
    (setf events (nreverse events))
    (is (equal '(:jsonl.record :protocol.route)
               (mapcar (lambda (event) (getf event :event)) events)))
    (is (string= raw (getf (first events) :raw-record)))
    (is (eq :response (getf (second events) :route)))))

(test jsonl-decoder-allows-trailing-whitespace
  ;; Real tab/newline after valid JSON exercises the post-parse predicate,
  ;; not string-trim; guards the +jsonl-whitespace+ fix.
  (let ((record (claude-agent-sdk-cl::decode-jsonl-record
                 (concatenate 'string "{\"type\":\"ok\"}" (string #\Tab) (string #\Newline)))))
    (is (string= "ok" (gethash "type" record)))))

(test jsonl-decoder-rejects-trailing-or-nonobject-data
  (signals claude-agent-sdk-cl::cli-json-error
    (claude-agent-sdk-cl::decode-jsonl-record "{\"type\":\"result\"} trailing"))
  (signals claude-agent-sdk-cl::cli-json-error
    (claude-agent-sdk-cl::decode-jsonl-record "[\"not\",\"a\",\"record\"]")))

(test jsonl-decoder-skips-blank-and-signals-malformed-records
  (is (null (claude-agent-sdk-cl::decode-jsonl-record "  ")))
  (let ((record (claude-agent-sdk-cl::decode-jsonl-record "{\"type\":\"result\",\"ok\":true}")))
    (is (string= "result" (gethash "type" record)))
    (is (eq t (gethash "ok" record))))
  (signals claude-agent-sdk-cl::cli-json-error
    (claude-agent-sdk-cl::decode-jsonl-record "{bad")))

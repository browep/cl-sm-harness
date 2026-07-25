(in-package #:claude-agent-sdk-cl)

(defstruct (jsonl-framer
            (:constructor make-jsonl-framer (&key (max-pending-length 1048576))))
  (pending "" :type string)
  (max-pending-length 1048576 :type integer))

(defun push-jsonl-chunk (framer chunk)
  "Add arbitrary stdout text CHUNK and return its complete JSONL records.
Chunks are never trimmed before line assembly."
  (let ((text (concatenate 'string (jsonl-framer-pending framer) chunk))
        (records '())
        (start 0))
    (loop for newline = (position #\Newline text :start start)
          while newline
          do (let ((record (subseq text start newline)))
               (when (and (> (length record) 0)
                          (char= (char record (1- (length record))) #\Return))
                 (setf record (subseq record 0 (1- (length record)))))
               (push record records)
               (setf start (1+ newline))))
    (setf (jsonl-framer-pending framer) (subseq text start))
    (when (> (length (jsonl-framer-pending framer))
             (jsonl-framer-max-pending-length framer))
      (setf (jsonl-framer-pending framer) "")
      (signal-cli-json-error "unterminated JSONL record exceeded configured pending-record limit"))
    (nreverse records)))

(defun flush-jsonl-framer (framer)
  "Return a final unterminated record, or NIL, and clear FRAMER."
  (prog1 (unless (string= "" (jsonl-framer-pending framer))
           (jsonl-framer-pending framer))
    (setf (jsonl-framer-pending framer) "")))

(defstruct (protocol-router (:constructor make-protocol-router ()))
  (next-id 0 :type integer)
  (pending (make-hash-table :test #'equal)))

(defun next-request-id (router)
  (format nil "request-~D" (incf (protocol-router-next-id router))))

(defun register-request (router request-id)
  (setf (gethash request-id (protocol-router-pending router)) t)
  request-id)

(defun control-response-p (record)
  "True when RECORD is an upstream `control_response' control message."
  (equal "control_response" (gethash "type" record)))

(defun control-response-request-id (record)
  "Extract the nested request id from a control_response's `response' object."
  (let ((response (gethash "response" record)))
    (when (hash-table-p response)
      (gethash "request_id" response))))

(defun route-protocol-record (router record)
  "Classify RECORD and return (values record route). Route keywords:
  :response  matched pending control response (consumed from the router)
  :control   internal control traffic that must NOT be yielded as a user event
             (unmatched/duplicate/unknown control responses; upstream drops
             these with `continue')
  :event     user-visible SDK message
Control responses use upstream's nested `response.request_id' wire shape, not a
top-level `request_id'."
  (let* ((control-p (control-response-p record))
         (request-id (when control-p (control-response-request-id record)))
         (route (cond
                  ((and control-p request-id
                        (gethash request-id (protocol-router-pending router)))
                   (remhash request-id (protocol-router-pending router))
                   :response)
                  (control-p :control)
                  (t :event))))
    (emit-transport-log :protocol.route :record record :request-id request-id :route route)
    (values record route)))

(defparameter +jsonl-whitespace+ '(#\Space #\Tab #\Return #\Newline))

(defun decode-jsonl-record (record)
  "Decode a complete JSONL record; blank records are ignored."
  (when (every (lambda (character) (member character +jsonl-whitespace+)) record)
    (return-from decode-jsonl-record nil))
  (let ((decoded
          (handler-case
              (with-input-from-string (stream record)
                (let ((decoded (yason:parse stream))
                      (trailing (loop for character = (read-char stream nil :eof)
                                      unless (and (characterp character)
                                                  (member character +jsonl-whitespace+))
                                        return character)))
                  (unless (and (eq trailing :eof) (hash-table-p decoded))
                    (error "JSONL record must be one object with no trailing data"))
                  decoded))
            (error ()
              (emit-transport-log :jsonl.decode-error :raw-record record)
              (signal-cli-json-error record)))))
    (emit-transport-log :jsonl.record :raw-record record :record decoded)
    decoded))

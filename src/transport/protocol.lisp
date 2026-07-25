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

(defun route-protocol-record (router record)
  "Return RECORD and whether it is a registered response or an unsolicited event."
  (let ((request-id (gethash "request_id" record)))
    (let ((route (if (and request-id (gethash request-id (protocol-router-pending router)))
                     (progn (remhash request-id (protocol-router-pending router)) :response)
                     :event)))
      (emit-transport-log :protocol.route :record record :request-id request-id :route route)
      (values record route))))

(defun decode-jsonl-record (record)
  "Decode a complete JSONL record; blank records are ignored."
  (let ((trimmed (string-trim '(#\Space #\Tab #\Return) record)))
    (when (string= "" trimmed) (return-from decode-jsonl-record nil))
    (handler-case
        (with-input-from-string (stream trimmed)
          (let ((decoded (yason:parse stream))
                (trailing (loop for character = (read-char stream nil :eof)
                                unless (and (characterp character)
                                            (find character " \t\r\n"))
                                  return character)))
            (unless (and (eq trailing :eof) (hash-table-p decoded))
              (error "JSONL record must be one object with no trailing data"))
            (emit-transport-log :jsonl.record :raw-record record :record decoded)
            decoded))
      (error ()
        (emit-transport-log :jsonl.decode-error :raw-record record)
        (signal-cli-json-error record)))))

(in-package #:claude-agent-sdk-cl)

(defstruct (jsonl-framer (:constructor make-jsonl-framer ()))
  (pending "" :type string))

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
    (if (and request-id (gethash request-id (protocol-router-pending router)))
        (progn
          (remhash request-id (protocol-router-pending router))
          (values record :response))
        (values record :event))))

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
            decoded))
      (error () (signal-cli-json-error record)))))

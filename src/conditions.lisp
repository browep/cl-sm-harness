(in-package #:claude-agent-sdk-cl)

(define-condition sdk-error (error)
  ((message :initarg :message :reader sdk-error-message))
  (:report (lambda (condition stream) (write-string (sdk-error-message condition) stream))))

(define-condition sdk-input-error (sdk-error) ())
(define-condition cli-connection-error (sdk-error) ())
(define-condition cli-not-found-error (sdk-error) ())

(define-condition client-lifecycle-error (sdk-error)
  ((operation :initarg :operation :reader client-lifecycle-error-operation)
   (state :initarg :state :reader client-lifecycle-error-state))
  (:report (lambda (condition stream)
             (format stream "Cannot ~A while client is ~A."
                     (client-lifecycle-error-operation condition)
                     (client-lifecycle-error-state condition)))))

(defun signal-client-lifecycle-error (operation state)
  (error 'client-lifecycle-error
         :message (format nil "Invalid client lifecycle: ~A in ~A" operation state)
         :operation operation :state state))

(define-condition cli-json-error (sdk-error)
  ((line :initarg :line :reader cli-json-error-line))
  (:report (lambda (condition stream)
             (format stream "Failed to decode CLI JSON: ~A" (cli-json-error-line condition)))))

(define-condition process-error (sdk-error)
  ((exit-code :initarg :exit-code :reader process-error-exit-code)
   (stderr :initarg :stderr :reader process-error-stderr))
  (:report (lambda (condition stream)
             (format stream "~A (exit code: ~D)~@[~%~A~]"
                     (sdk-error-message condition)
                     (process-error-exit-code condition)
                     (process-error-stderr condition)))))

(defun signal-sdk-input-error (message)
  (error 'sdk-input-error :message message))

(defun signal-cli-json-error (line)
  (error 'cli-json-error :message "Failed to decode JSON" :line line))

(defun signal-process-error (message exit-code stderr)
  (error 'process-error :message message :exit-code exit-code :stderr stderr))

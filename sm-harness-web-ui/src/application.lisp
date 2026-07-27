(in-package #:sm-harness-web-ui)

(defun on-new-window (body)
  (clog:load-css (clog:html-document body) "/app.css")
  (render-home body))

(defun start-web-ui (&key harness config)
  "Start CLOG server. HARNESS must already be constructed."
  (setf *app-harness* harness
        *web-ui-config* (or config (make-web-ui-config)))
  (let ((cfg *web-ui-config*))
    (setf *clog-server*
          (clog:initialize #'on-new-window
                           :host (web-ui-config-host cfg)
                           :port (web-ui-config-port cfg)
                           :static-root (namestring (web-ui-config-static-root cfg))))
    (format t "sm-harness-web-ui listening on ~A:~A~%"
            (web-ui-config-host cfg)
            (web-ui-config-port cfg))
    *clog-server*))

(defun stop-web-ui ()
  (when *app-harness*
    (ignore-errors (sm-harness:close-harness *app-harness*))
    (setf *app-harness* nil))
  (setf *clog-server* nil)
  t)

(defclass e2e-fake-transport (claude-agent-sdk-cl:client-transport)
  ((chunks :initarg :chunks :accessor e2e-chunks)
   (writes :initform '() :accessor e2e-writes)))

(defmethod claude-agent-sdk-cl:start-client-transport ((tport e2e-fake-transport) options)
  (declare (ignore options))
  tport)
(defmethod claude-agent-sdk-cl:read-client-chunk ((tport e2e-fake-transport))
  (pop (e2e-chunks tport)))
(defmethod claude-agent-sdk-cl:write-client-input ((tport e2e-fake-transport) input)
  (push input (e2e-writes tport))
  t)
(defmethod claude-agent-sdk-cl:close-client-transport ((tport e2e-fake-transport) &key reason)
  (declare (ignore reason))
  t)

(defun %e2e-transport-factory (options)
  (declare (ignore options))
  (let ((nl (string #\Newline)))
    (make-instance 'e2e-fake-transport
                   :chunks
                   (list
                    (concatenate 'string
                     "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"request-1\"}}"
                     nl)
                    (concatenate 'string
                     "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"e2e hello\"}],\"model\":\"fixture\"}}"
                     nl
                     "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"session_id\":\"e2e-canon\",\"result\":\"ok\"}"
                     nl)))))

(defun main ()
  "Docker entrypoint helper."
  (let* ((data (or (uiop:getenv "SM_HARNESS_DATA") "/data"))
         (port (parse-integer (or (uiop:getenv "SM_HARNESS_PORT") "8080")))
         (host (or (uiop:getenv "SM_HARNESS_HOST") "0.0.0.0"))
         (fixture (equal (uiop:getenv "WEB_UI_E2E") "1"))
         (hcfg (sm-harness:make-harness-config
                :data-root data
                :project-key "web"
                :transport-factory (when fixture #'%e2e-transport-factory)))
         (harness (sm-harness:make-harness :config hcfg)))
    (start-web-ui :harness harness
                  :config (make-web-ui-config :host host :port port
                                              :static-root #P"/app/static/"))
    (loop (sleep 3600))))

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
                           :static-root (namestring (web-ui-config-static-root cfg))
                           :boot-file "/boot.html"))
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

(defun %fixture-transport-factory ()
  "Find the test-only E2E transport installed by sm-harness-web-ui/e2e."
  (let ((symbol (find-symbol "%E2E-TRANSPORT-FACTORY" :sm-harness-web-ui)))
    (unless (and symbol (fboundp symbol))
      (error "WEB_UI_E2E requires the sm-harness-web-ui/e2e ASDF system"))
    (symbol-function symbol)))

(defun main ()
  "Docker entrypoint helper."
  (let* ((data (or (uiop:getenv "SM_HARNESS_DATA") "/data"))
         (port (parse-integer (or (uiop:getenv "SM_HARNESS_PORT") "8080")))
         (host (or (uiop:getenv "SM_HARNESS_HOST") "0.0.0.0"))
         (fixture (equal (uiop:getenv "WEB_UI_E2E") "1"))
         (hcfg (sm-harness:make-harness-config
                :data-root data
                :project-key "web"
                :transport-factory (when fixture (%fixture-transport-factory))))
         (harness (sm-harness:make-harness :config hcfg)))
    (when fixture
      (let ((writer (find-symbol "WRITE-E2E-CONTRACT" :sm-harness-web-ui)))
        (unless (and writer (fboundp writer))
          (error "WEB_UI_E2E requires the sm-harness-web-ui/e2e-contract ASDF system"))
        (funcall (symbol-function writer))))
    (start-web-ui :harness harness
                  :config (make-web-ui-config :host host :port port
                                              :static-root #P"/app/static/"))
    (loop (sleep 3600))))

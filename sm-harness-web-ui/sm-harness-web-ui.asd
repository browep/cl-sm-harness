(asdf:defsystem #:sm-harness-web-ui
  :description "CLOG browser UI over sm-harness"
  :author "Paul Brower"
  :license "MIT"
  :version "0.1.0"
  :depends-on (#:sm-harness #:clog)
  :serial t
  :components ((:module "src"
                :components
                ((:file "packages")
                 (:file "config")
                 (:file "presenter")
                 (:file "harness-adapter")
                 (:file "ui/home")
                 (:file "ui/chat")
                 (:file "application")))))

(asdf:defsystem #:sm-harness-web-ui/presenter-tests
  :description "Presenter-only tests (no CLOG runtime required)"
  :depends-on (#:sm-harness #:fiveam)
  :serial t
  :components ((:file "src/packages")
               (:file "src/presenter")
               (:file "test/packages")
               (:file "test/ui-state"))
  :perform (asdf:test-op (op c)
             (declare (ignore op c))
             (unless (uiop:symbol-call '#:fiveam '#:run! :sm-harness-web-ui/tests)
               (error "presenter tests failed"))))

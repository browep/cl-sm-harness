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
                 (:file "shutdown")
                 (:file "harness-adapter")
                 (:file "connection-log")
                 (:file "browser-logs")
                 (:file "ui/log-export")
                 (:file "ui/session-info")
                 (:file "ui/upload")
                 (:file "ui/home")
                 (:file "ui/chat")
                 (:file "live-reload")
                 (:file "application")))))

(asdf:defsystem #:sm-harness-web-ui/e2e-contract
  :description "Pure Lisp browser-E2E contract, independent of CLOG"
  :depends-on (#:sm-harness)
  :serial t
  :components ((:file "src/packages")
               (:file "e2e/contract")
               (:module "e2e/scenarios"
                :components ((:file "home-health")
                             (:file "new-chat-composer")
                             (:file "turn-identity")
                             (:file "direct-session-routes")
                             (:file "direct-session-resume")
                             (:file "back-navigation")
                             (:file "streaming-layout")
                             (:file "errors-recovery")
                             (:file "connect-recovery")
                             (:file "read-recovery")
                             (:file "malformed-event-recovery")
                             (:file "tool-handler-failure")
                             (:file "safe-rendering")
                             (:file "accessibility")
                             (:file "stop-deadline")
                             (:file "custom-tool-lifecycle")
                             (:file "connection-lost-recovery")
                             (:file "connection-lost-fallback")
                             (:file "export-logs")
                             (:file "session-info")
                             (:file "title-live-update")
                             (:file "upload")))))

(asdf:defsystem #:sm-harness-web-ui/e2e
  :description "Test-only deterministic SDK transport for browser E2E"
  :depends-on (#:sm-harness-web-ui #:sm-harness-web-ui/e2e-contract)
  :serial t
  :components ((:file "e2e/fixture-transport")
               (:file "e2e/test-hooks")))

(asdf:defsystem #:sm-harness-web-ui/presenter-tests
  :description "Presenter-only tests (no CLOG runtime required)"
  :depends-on (#:sm-harness #:fiveam)
  :serial t
  :components ((:file "src/packages")
               (:file "src/config")
               (:file "src/presenter")
               (:file "src/shutdown")
               (:file "test/packages")
               (:file "test/ui-state"))
  :perform (asdf:test-op (op c)
             (declare (ignore op c))
             (unless (uiop:symbol-call '#:fiveam '#:run! :sm-harness-web-ui/tests)
               (error "presenter tests failed"))))

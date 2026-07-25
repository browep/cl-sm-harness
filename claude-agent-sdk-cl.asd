(asdf:defsystem #:claude-agent-sdk-cl
  :description "Common Lisp interface to the Claude Code CLI"
  :author "Paul Brower"
  :license "MIT"
  :version "0.1.0"
  :depends-on (#:yason)
  :serial t
  :components ((:file "src/packages")
               (:file "src/bootstrap")
               (:file "src/conditions")
               (:file "src/options")
               (:file "src/types")
               (:file "src/transport/logging")
               (:file "src/transport/protocol")
               (:file "src/transport/subprocess")))

(asdf:defsystem #:claude-agent-sdk-cl/tests
  :description "Tests for claude-agent-sdk-cl"
  :depends-on (#:claude-agent-sdk-cl #:fiveam #:yason)
  :serial t
  :components ((:file "test/packages")
               (:file "test/bootstrap")
               (:file "test/conditions")
               (:file "test/options")
               (:file "test/types")
               (:file "test/protocol")
               (:file "test/subprocess"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (uiop:symbol-call '#:fiveam '#:run! :claude-agent-sdk-cl/tests)
               (error "FiveAM test suite failed"))))

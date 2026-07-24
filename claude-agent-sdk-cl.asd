(asdf:defsystem #:claude-agent-sdk-cl
  :description "Common Lisp interface to the Claude Code CLI"
  :author "Paul Brower"
  :license "MIT"
  :version "0.1.0"
  :serial t
  :components ((:file "src/packages")
               (:file "src/bootstrap")))

(asdf:defsystem #:claude-agent-sdk-cl/tests
  :description "Tests for claude-agent-sdk-cl"
  :depends-on (#:claude-agent-sdk-cl #:fiveam)
  :serial t
  :components ((:file "test/packages")
               (:file "test/bootstrap"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (uiop:symbol-call '#:fiveam '#:run! :claude-agent-sdk-cl/tests)
               (error "FiveAM test suite failed"))))

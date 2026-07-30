(asdf:defsystem #:sm-harness
  :description "Headless reusable session/tool runtime over claude-agent-sdk-cl"
  :author "Paul Brower"
  :license "MIT"
  :version "0.1.0"
  ;; sb-posix: the bash tool's timeout kill uses killpg directly so it can
  ;; never silently no-op in an image that ships no kill binary (#79).
  ;; cl-ppcre: the bash tool's self-kill guard (#101) reads pkill/killall
  ;; patterns the way those tools would, to reject only commands that
  ;; would hit the harness's own process -- same no-external-binary
  ;; reasoning as #79, an in-image pgrep is not assumed either.
  :depends-on (#:claude-agent-sdk-cl #:yason #:cl-ppcre (:require #:sb-posix))
  :serial t
  :components ((:module "src"
                :components
                ((:file "packages")
                 (:file "config")
                 (:file "model")
                 (:file "events")
                 (:file "subscriptions")
                 (:file "tool-catalog")
                 (:file "tool-policy")
                 (:file "sdk-adapter")
                 (:file "session-repository")
                 (:file "runtime")
                 (:file "session-service")))))

(asdf:defsystem #:sm-harness/tests
  :description "Tests for sm-harness"
  :depends-on (#:sm-harness #:fiveam #:yason)
  :serial t
  :components ((:module "test"
                :components
                ((:file "packages")
                 (:file "fake-sdk-transport")
                 (:file "support")
                 (:file "session-repository")
                 (:file "session-service")
                 (:file "sdk-adapter")
                 (:file "tool-catalog")
                 (:file "reload-harness")
                 (:file "runtime"))))
  :perform (asdf:test-op (op c)
             (declare (ignore op c))
             (unless (uiop:symbol-call '#:fiveam '#:run! :sm-harness/tests)
               (error "sm-harness FiveAM suite failed"))))

(asdf:defsystem #:sm-harness/test-support
  :description "Test-only scripted transports for sm-harness (not a production dep)"
  :depends-on (#:sm-harness #:yason)
  :serial t
  :components ((:module "test"
                :components
                ((:file "packages")
                 (:file "fake-sdk-transport")
                 (:file "support")))))

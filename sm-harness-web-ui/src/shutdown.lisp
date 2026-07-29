(in-package #:sm-harness-web-ui)

(defun %install-shutdown-signal-handlers (request-shutdown)
  "Install SIGTERM/SIGINT handlers that call REQUEST-SHUTDOWN.
SB-SYS:ENABLE-INTERRUPT invokes a Unix signal handler with THREE arguments
(signal number, siginfo, ucontext).  The previous zero-argument lambdas
made every SIGTERM/SIGINT die with \"invalid number of arguments: 3\"
(#82): the process still exited, but as a crash, so UNWIND-PROTECT cleanup
never ran -- close-harness was skipped and (pre-#83) the leftover
data-root lock then blocked the next start entirely.  Kept CLOG-free on
purpose so the presenter test suite can exercise it with a real signal."
  (flet ((handler (signal info context)
           (declare (ignore signal info context))
           (funcall request-shutdown)))
    (sb-sys:enable-interrupt sb-unix:sigterm #'handler)
    (sb-sys:enable-interrupt sb-unix:sigint #'handler)))

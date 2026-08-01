;;;; Opt-in live termination smoke. Invoked only as `test.sh live-terminate`.
;;;; Cancels at the first public record; it prints only safe outcome evidence.

(require :asdf)
(asdf:load-system :claude-agent-sdk-cl)

(defparameter +live-terminate-prompt+
  "Reply with exactly: SDK termination smoke OK")

(let ((callback-count 0)
      (events '()))
  ;; Retain diagnostics in memory but never print raw events: they can contain
  ;; full prompt/response payloads. Only safe lifecycle fields become evidence.
  (let ((claude-agent-sdk-cl::*transport-log-function*
          (lambda (event) (push event events))))
    (let ((messages
            (claude-agent-sdk-cl:query
             +live-terminate-prompt+
             :timeout 120
             :on-message (lambda (message)
                           (declare (ignore message))
                           (incf callback-count)
                           :cancel))))
      (unless (= callback-count 1)
        (error "Live termination smoke expected exactly one callback, got ~D."
               callback-count))
      (unless (= (length messages) 1)
        (error "Live termination smoke expected exactly one public record, got ~D."
               (length messages)))
      (let ((close-event (find :cli.close events
                               :key (lambda (event) (getf event :event)))))
        (unless (and close-event
                     (eq :cancel (getf close-event :reason))
                     (getf close-event :alive-before-close))
          (error "Live termination did not close an active CLI for cancellation."))
        (format t "live-terminate: callback-count=~D messages=~D cancellation=clean active-child=true exit-code=~D~%"
                callback-count (length messages) (getf close-event :exit-code))))))

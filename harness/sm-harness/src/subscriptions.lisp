(in-package #:sm-harness)

(defstruct (listener (:constructor %make-listener))
  id
  session-id
  (queue '() :type list)
  capacity
  (overflowed-p nil)
  callback
  (closed-p nil)
  ;; When a closed listener still has queued (or drained-but-undelivered)
  ;; events, this decides their fate: NIL flushes them through the callback
  ;; before the dispatcher exits (graceful detach -- a test or the Back
  ;; button must observe everything already published), T abandons them
  ;; (eviction/teardown of a listener whose browser is likely gone, where
  ;; every delivery attempt would burn a dead-connection timeout).
  (discard-on-close-p nil)
  (lock (sb-thread:make-mutex :name "listener"))
  (waitqueue (sb-thread:make-waitqueue))
  ;; Dispatcher thread; NIL for callback-less (drain-only) listeners.
  (thread nil))

(defun %listener-dispatch-loop (listener)
  "Deliver queued events to the listener's callback, in publish order, on
this dedicated thread. Publishing (%PUBLISH) only ever enqueues: a callback
that blocks -- canonically a CLOG browser round-trip against a connection
whose peer silently died -- must never stall the session worker, which also
services the CLI's MCP control requests. (2026-07-30: a half-dead browser
tab starved a tools/call response for 40s; the CLI gave up and the turn
died as \"internal error\".)"
  (loop
    (multiple-value-bind (batch closed discard)
        (sb-thread:with-mutex ((listener-lock listener))
          (loop while (and (null (listener-queue listener))
                           (not (listener-closed-p listener)))
                do (sb-thread:condition-wait (listener-waitqueue listener)
                                             (listener-lock listener)))
          (let ((q (listener-queue listener)))
            (setf (listener-queue listener) '())
            (values q
                    (listener-closed-p listener)
                    (listener-discard-on-close-p listener))))
      (unless (and closed discard)
        (dolist (ev batch)
          ;; Unlocked peek: best-effort prompt abandonment when a discarding
          ;; close arrives mid-batch.
          (when (and (listener-closed-p listener)
                     (listener-discard-on-close-p listener))
            (return))
          (ignore-errors (funcall (listener-callback listener) ev))))
      (when closed (return)))))

(defun make-listener (session-id capacity callback)
  (let ((listener (%make-listener
                   :id (%new-id "lst")
                   :session-id session-id
                   :capacity capacity
                   :callback callback)))
    (when (functionp callback)
      (setf (listener-thread listener)
            (sb-thread:make-thread
             (lambda () (%listener-dispatch-loop listener))
             :name (format nil "sm-listener-~A" (listener-id listener)))))
    listener))

(defun listener-push (listener event)
  "Enqueue EVENT under lock. Overflow sets gap flag and drops oldest."
  (sb-thread:with-mutex ((listener-lock listener))
    (unless (listener-closed-p listener)
      (let ((q (listener-queue listener)))
        (when (>= (length q) (listener-capacity listener))
          (setf (listener-overflowed-p listener) t
                q (cdr q)))
        (setf (listener-queue listener) (append q (list event))))
      (sb-thread:condition-broadcast (listener-waitqueue listener)))))

(defun listener-drain (listener)
  (sb-thread:with-mutex ((listener-lock listener))
    (let ((q (listener-queue listener))
          (gap (listener-overflowed-p listener)))
      (setf (listener-queue listener) '()
            (listener-overflowed-p listener) nil)
      (values q gap))))

(defun listener-close (listener &key discard (join-timeout 5))
  "Stop LISTENER: refuse further pushes and end its dispatcher. Without
DISCARD, events already queued are still delivered first (see
DISCARD-ON-CLOSE-P). Joins the dispatcher (bounded by JOIN-TIMEOUT) so
callers -- tests above all -- observe a quiesced callback on return; skipped
when called from the dispatcher itself (a callback detaching its own
listener must not join its own thread)."
  (sb-thread:with-mutex ((listener-lock listener))
    (setf (listener-closed-p listener) t)
    (when discard
      (setf (listener-discard-on-close-p listener) t))
    (sb-thread:condition-broadcast (listener-waitqueue listener)))
  (let ((thread (listener-thread listener)))
    (when (and thread (not (eq thread sb-thread:*current-thread*)))
      (sb-thread:join-thread thread :timeout join-timeout :default nil)))
  t)

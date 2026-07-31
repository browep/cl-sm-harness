(in-package #:sm-harness-web-ui)

;;;; Durable connection-lifecycle logging (#122, following up on #110's
;;;; "instrument before iterating on detection again"). Both files below
;;;; are readable by an agent working inside this container without a
;;;; Docker socket (#61) -- unlike PID 1's stdout, a pipe to Docker, which
;;;; is where every one of these lines went before this and nowhere else
;;;; (see docs/sm-harness.md, "Operator diagnostics: per-session event
;;;; logging", for the existing, stdout-only precedent this fixes).
;;;;
;;;; Two files, both under the same durable web/ project directory
;;;; SM-HARNESS's own SESSION-REPOSITORY already uses (index.json,
;;;; sessions/*.json) -- no new Docker volume or image change needed,
;;;; /data is already a durable named volume, already writable (#89/#90):
;;;;
;;;; - CONNECTION-LOG.JSONL -- clean, first-party JSON lines this project
;;;;   writes itself: a new connection opening (ON-NEW-WINDOW, already
;;;;   first-party code, src/application.lisp) and ping-derived liveness,
;;;;   via CLOG-CONNECTION's own *MESSAGE-HANDLERS* extension point. That
;;;;   list is internal but a DEFVAR, not a DEFPARAMETER (confirmed by
;;;;   reading clog-connection-websockets.lisp), so pushing onto it once
;;;;   survives even a whole-CLOG re-evaluation the way a DEFPARAMETER
;;;;   global would not (#105's failure class) -- the same technique the
;;;;   reverted #110 prototype already used for its SMPROBE handler.
;;;; - CLOG-STDOUT.LOG -- a verbatim tee of *STANDARD-OUTPUT*, covering the
;;;;   connection-lifecycle lines CLOG's own private, non-exported
;;;;   HANDLE-NEW-CONNECTION already prints via plain (FORMAT T ...) with
;;;;   no handler-list hook of its own: "New connection id - ID - CONN",
;;;;   "Reconnection id - ID to CONN" (a stale connection's tab
;;;;   successfully resuming), and "Reconnection id ID not found. Closing
;;;;   the connection." (the terminal, unrecoverable case #100/#110 care
;;;;   about most). Monkeypatching that private DEFUN was rejected: unlike
;;;;   *MESSAGE-HANDLERS*, an ordinary DEFUN *is* clobbered by any
;;;;   re-evaluation of that file -- the same failure class as #105 and
;;;;   the invalidated #110 field test (see that issue's addendum).
;;;;   *STANDARD-OUTPUT* is a plain CL special variable nothing in this
;;;;   project's reload path ever resets, and a fresh BORDEAUX-THREADS
;;;;   thread (which is how CLOG spawns its own connection callbacks) was
;;;;   confirmed live, before writing this, to still observe a broadcast
;;;;   stream installed this way.
;;;;
;;;; Deliberately NOT captured: CLOG's "Connection id ID has closed" line
;;;; (HANDLE-CLOSE-CONNECTION) turns out to be gated behind
;;;; CLOG-CONNECTION:*VERBOSE-OUTPUT* (default NIL, confirmed by reading
;;;; the same file) -- and that flag also makes every ping, every UI event
;;;; dispatch, and every JS query round trip log a line, i.e. one line per
;;;; user interaction with the whole app. That is far too much durable
;;;; write volume for what this ticket needs and was deliberately not
;;;; enabled. The ping-derived "stale" event below (a connection gone
;;;; silent past *CONNECTION-STALE-AFTER-SECONDS*) is the substitute
;;;; signal for "this connection is effectively gone" -- and is a better
;;;; fit for #110's actual failure modes 2 and 3 anyway (an endless silent
;;;; reconnect retry loop, or a half-open socket) than a clean close event
;;;; would be, since neither of those ever reaches a real close at all.

(defvar *connection-log-lock* (sb-thread:make-mutex :name "connection-log")
  "Guards writes to *CONNECTION-LOG-STREAM* so concurrent connections'
threads cannot interleave a single JSON line -- same pattern as
SM-HARNESS's *SESSION-EVENT-LOG-LOCK* (runtime.lisp).")

(defvar *connection-log-stream* nil
  "Open output stream for web/connection-log.jsonl, or NIL before
%INSTALL-CONNECTION-LOG has run (e.g. a test/REPL image that never calls
START-WEB-UI, or presenter-only unit tests that never load this far).")

(defvar *clog-stdout-tee-stream* nil
  "Open output stream for web/clog-stdout.log -- the file half of the
*STANDARD-OUTPUT* broadcast stream. Tracked separately from
*STANDARD-OUTPUT* itself (which keeps changing, by design) purely so
%INSTALL-STDOUT-TEE and %STOP-CONNECTION-LOG can tell whether they have
already run.")

(defvar *stdout-before-connection-tee* nil
  "*STANDARD-OUTPUT*'s value from just before %INSTALL-STDOUT-TEE wrapped
it, so %STOP-CONNECTION-LOG can restore it -- closing
*CLOG-STDOUT-TEE-STREAM* without first un-broadcasting it would leave any
later FORMAT T writing into a closed stream and erroring.")

(defvar *connection-last-seen* (make-hash-table :test #'equal)
  "CONNECTION-ID (string) -> universal-time it was last known alive
(opened, or pinged). Populated by %NOTE-CONNECTION-SEEN; read by the
sweep thread below.")

(defvar *connection-flagged-stale* (make-hash-table :test #'equal)
  "CONNECTION-ID -> T once the sweep thread has already logged it silent,
so one lapse produces one \"stale\" line, not one per sweep tick for the
rest of the process's life. Cleared by %NOTE-CONNECTION-SEEN if the
connection is later heard from again, so a connection that recovers and
later goes silent a second time is reported again.")

(defvar *connection-last-seen-lock*
  (sb-thread:make-mutex :name "connection-last-seen"))

(defvar *connection-sweep-thread* nil)

(defvar *connection-sweep-stop-requested* nil
  "Cooperative stop flag for the sweep thread (checked once per
*CONNECTION-SWEEP-INTERVAL-SECONDS*), not SB-THREAD:TERMINATE-THREAD --
the sweep tick holds *CONNECTION-LAST-SEEN-LOCK* while it runs, and an
async thread kill mid-hold could leave that mutex permanently locked with
no owner ever able to release it, wedging every later ping. A cooperative
flag can lag by up to one sweep interval before the thread actually exits;
harmless, since %STOP-CONNECTION-LOG is only ever expected to run at
process shutdown or between test/REPL cycles, never on a path anything
else waits on.")

(defparameter *connection-stale-after-seconds* 30
  "How long a connection may go without being seen (opened, or pinged)
before the sweep thread logs it stale. CLOG's own boot.js pings every 10s
(Ping_ws, static-files/js/boot.js) so this is three missed pings, not one
unlucky poll tick.")

(defparameter *connection-sweep-interval-seconds* 15)

(defun %iso-now ()
  "UTC ISO-8601 timestamp, matching the format SM-HARNESS's own (private,
unexported) %NOW-ISO (sm-harness/src/model.lisp) and %LOG-SESSION-EVENT
(sm-harness/src/runtime.lisp) already use, so lines from both logs
compare directly as strings."
  (multiple-value-bind (s m h d mo y) (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ" y mo d h m s)))

(defun %connection-log-project-dir (data-root project-key)
  "The same PROJECT-KEY subdirectory of DATA-ROOT that
SM-HARNESS::SESSION-REPOSITORY (sm-harness/src/session-repository.lisp)
already writes index.json/sessions/*.json into -- reusing that layout
rather than inventing a parallel one."
  (merge-pathnames (make-pathname :directory (list :relative project-key))
                    (uiop:ensure-directory-pathname data-root)))

(defun %connection-log-path (data-root project-key)
  (merge-pathnames "connection-log.jsonl"
                    (%connection-log-project-dir data-root project-key)))

(defun %clog-stdout-log-path (data-root project-key)
  (merge-pathnames "clog-stdout.log"
                    (%connection-log-project-dir data-root project-key)))

(defun %open-append-stream (path)
  (ensure-directories-exist path)
  (open path :direction :output :if-exists :append :if-does-not-exist :create))

(defun %write-connection-log-line (object)
  (when *connection-log-stream*
    (let ((line (with-output-to-string (s) (yason:encode object s))))
      (sb-thread:with-mutex (*connection-log-lock*)
        (ignore-errors
         (format *connection-log-stream* "~&~A~%" line)
         (force-output *connection-log-stream*))))))

(defun %log-connection-event (event connection-id &rest plist)
  "Write one JSON line to web/connection-log.jsonl:
{\"ts\":..., \"connection_id\":..., \"event\":EVENT, ...PLIST}. Never
signals -- a diagnostic log must not be able to break the thing it is
diagnosing."
  (ignore-errors
   (let ((o (make-hash-table :test #'equal)))
     (setf (gethash "ts" o) (%iso-now)
           (gethash "connection_id" o) connection-id
           (gethash "event" o) event)
     (loop for (k v) on plist by #'cddr do
       (setf (gethash (string-downcase (symbol-name k)) o) v))
     (%write-connection-log-line o))))

(defun %note-connection-seen (connection-id)
  "Record CONNECTION-ID as alive right now -- called on open and on every
ping (the message handler below). Un-flags it from
*CONNECTION-FLAGGED-STALE* too, so a connection that recovers gets a fresh
\"stale\" line if it later goes silent again instead of staying silenced
for the rest of the process's life."
  (when connection-id
    (sb-thread:with-mutex (*connection-last-seen-lock*)
      (setf (gethash connection-id *connection-last-seen*) (get-universal-time))
      (remhash connection-id *connection-flagged-stale*))))

(defun %note-connection-opened (connection-id)
  "Called from ON-NEW-WINDOW (src/application.lisp) for every genuinely
new connection -- CLOG only invokes that for a brand-new connection id,
never for a reconnect (successful or rejected), so this is deliberately
not where those two are logged (see the tee above for those)."
  (%note-connection-seen connection-id)
  (%log-connection-event "opened" connection-id))

(defun %ping-message-handler (ml connection-id)
  "Registered on CLOG-CONNECTION::*MESSAGE-HANDLERS* (#122) -- recognizes
the bare \"0\" ping every open tab already sends every 10s
(static-files/js/boot.js's Ping_ws) and records CONNECTION-ID as alive,
so this project gets an authoritative \"last heard from this tab at T\"
with no client-side change at all. Always returns NIL so CLOG's own
built-in ping handling (clog-connection-websockets.lisp HANDLE-MESSAGE,
including the optional *BROWSER-GC-ON-PING* sweep) still runs afterward --
this only observes, it never intercepts or short-circuits."
  (ignore-errors
   (when (and connection-id (equal (first ml) "0"))
     (%note-connection-seen connection-id)))
  nil)

(defun %install-ping-message-handler ()
  "Idempotent: PUSHNEW by EQL onto CLOG-CONNECTION::*MESSAGE-HANDLERS*, an
internal (unexported) but DEFVAR (not DEFPARAMETER) list, confirmed by
reading clog-connection-websockets.lisp -- so this is not reset by a
stray whole-CLOG re-evaluation the way a DEFPARAMETER-backed global would
be (#105's failure class). The same extension point the reverted #110
prototype already used for its SMPROBE handler."
  (pushnew '%ping-message-handler clog-connection::*message-handlers*))

(defun %stale-connection-sweep-tick ()
  (let ((now (get-universal-time))
        (newly-stale '()))
    (sb-thread:with-mutex (*connection-last-seen-lock*)
      (maphash (lambda (connection-id last-seen)
                 (when (and (>= (- now last-seen) *connection-stale-after-seconds*)
                            (not (gethash connection-id *connection-flagged-stale*)))
                   (setf (gethash connection-id *connection-flagged-stale*) t)
                   (push (cons connection-id (- now last-seen)) newly-stale)))
               *connection-last-seen*))
    (dolist (entry newly-stale)
      (%log-connection-event "stale" (car entry) :silent_for_seconds (cdr entry)))))

(defun %flush-clog-stdout-tee ()
  "CLOG's own (FORMAT T ...) calls into the tee installed by
%INSTALL-STDOUT-TEE never FORCE-OUTPUT afterward (why would they -- they
were written against a plain console stream), so *CLOG-STDOUT-TEE-STREAM*
would otherwise sit in SBCL's internal buffer, undurable, until it
happened to fill or the stream closed. Piggybacked on the sweep thread's
own tick (below) rather than flushing on every write, since this is a
diagnostic log, not a real-time one -- worst case this is
*CONNECTION-SWEEP-INTERVAL-SECONDS* stale, and a clean process shutdown
(%STOP-CONNECTION-LOG closing the stream) flushes immediately regardless."
  (when *clog-stdout-tee-stream*
    (ignore-errors (force-output *clog-stdout-tee-stream*))))

(defun %install-connection-sweep-thread ()
  (unless (and *connection-sweep-thread*
               (sb-thread:thread-alive-p *connection-sweep-thread*))
    (setf *connection-sweep-stop-requested* nil)
    (setf *connection-sweep-thread*
          (sb-thread:make-thread
           (lambda ()
             (loop until *connection-sweep-stop-requested* do
               (sleep *connection-sweep-interval-seconds*)
               (unless *connection-sweep-stop-requested*
                 (ignore-errors (%stale-connection-sweep-tick))
                 (%flush-clog-stdout-tee))))
           :name "sm-harness-web-ui connection-log sweep"))))

(defun %install-stdout-tee (data-root project-key)
  "Reassign *STANDARD-OUTPUT* to a broadcast stream that also writes to
web/clog-stdout.log (#122) -- see the file-level comment above for why
(no handler-list hook for CLOG's own connection-lifecycle prints) and why
not by monkeypatching CLOG internals instead. Idempotent, checked via
*CLOG-STDOUT-TEE-STREAM* rather than inspecting *STANDARD-OUTPUT* itself,
which by design keeps changing. Must run before CLOG:INITIALIZE
(START-WEB-UI, application.lisp) or the very first connection's lifecycle
lines are missed."
  (unless *clog-stdout-tee-stream*
    (setf *clog-stdout-tee-stream*
          (%open-append-stream (%clog-stdout-log-path data-root project-key)))
    (setf *stdout-before-connection-tee* *standard-output*)
    (setf *standard-output*
          (make-broadcast-stream *standard-output* *clog-stdout-tee-stream*))))

(defun %install-connection-log (data-root project-key)
  "Entry point for #122. Call once, from START-WEB-UI, before
CLOG:INITIALIZE. Safe to call more than once -- every piece here is
independently idempotent -- and safe to call with the same DATA-ROOT/
PROJECT-KEY across a test/REPL's repeated START-WEB-UI/STOP-WEB-UI
cycles."
  (unless *connection-log-stream*
    (setf *connection-log-stream*
          (%open-append-stream (%connection-log-path data-root project-key))))
  (%install-stdout-tee data-root project-key)
  (%install-ping-message-handler)
  (%install-connection-sweep-thread))

(defun %stop-connection-log ()
  "Reverse of %INSTALL-CONNECTION-LOG, for test/REPL hygiene -- ordinary
production shutdown (%RUN-UNTIL-SHUTDOWN's UNWIND-PROTECT) calls this via
STOP-WEB-UI right before process exit, where it is mostly moot. Restores
*STANDARD-OUTPUT* before closing *CLOG-STDOUT-TEE-STREAM*, not after --
otherwise a FORMAT T racing this shutdown could write into an
already-closed stream and error. Leaves
CLOG-CONNECTION::*MESSAGE-HANDLERS* alone: removing our entry there is
unneeded complexity, since re-pushing it is idempotent and CLOG itself is
never torn down independently of this whole process."
  (%stop-connection-sweep-thread)
  (when *clog-stdout-tee-stream*
    (setf *standard-output* (or *stdout-before-connection-tee* *standard-output*))
    (ignore-errors (close *clog-stdout-tee-stream*))
    (setf *clog-stdout-tee-stream* nil)
    (setf *stdout-before-connection-tee* nil))
  (when *connection-log-stream*
    (ignore-errors (close *connection-log-stream*))
    (setf *connection-log-stream* nil))
  (clrhash *connection-last-seen*)
  (clrhash *connection-flagged-stale*)
  t)

(defun %stop-connection-sweep-thread ()
  (setf *connection-sweep-stop-requested* t)
  (setf *connection-sweep-thread* nil))

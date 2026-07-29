(in-package #:sm-harness)

;;;; Product-owned tool definitions.  These are deliberately SDK-free:
;;;; metadata crosses the adapter boundary; handler closures remain local.

(defstruct (tool-definition (:constructor make-tool-definition))
  (name "" :type string)
  (description "" :type string)
  input-schema
  handler)

(defstruct (tool-server-definition (:constructor make-tool-server-definition))
  (name "" :type string)
  (version "0.1.0" :type string)
  (tools '() :type list))

(defstruct (tool-catalog (:constructor make-tool-catalog))
  (servers '() :type list))

(defun %json-object (&rest pairs)
  (let ((o (make-hash-table :test #'equal)))
    (loop for (k v) on pairs by #'cddr do (setf (gethash k o) v))
    o))

(defun %echo-schema ()
  (let ((schema (%json-object "type" "object"))
        (props (%json-object))
        (field (%json-object "type" "string")))
    (setf (gethash "text" props) field
          (gethash "properties" schema) props
          (gethash "required" schema) (list "text"))
    schema))

(defun make-echo-tool-definition ()
  "Deterministic fixture-friendly tool definition used by the default catalog."
  (make-tool-definition
   :name "echo_text"
   :description "Echo the provided text argument."
   :input-schema (%echo-schema)
   :handler (lambda (arguments context)
              (declare (ignore context))
              (format nil "echo: ~A" (or (gethash "text" arguments) "")))))

(defparameter +read-tool-max-chars+ (* 2 1024 1024)
  "Cap on characters read from a file before line-slicing. Approximate for
multi-byte UTF-8 content (a character cap, not a strict byte cap) -- this
tool is not a precision file-size accounting mechanism, just a guard
against reading an unbounded file into memory.")

(defun %read-schema ()
  (let ((schema (%json-object "type" "object"))
        (props (%json-object))
        (path-field (%json-object "type" "string"))
        (offset-field (%json-object "type" "integer"))
        (limit-field (%json-object "type" "integer")))
    (setf (gethash "path" props) path-field
          (gethash "offset" props) offset-field
          (gethash "limit" props) limit-field
          (gethash "properties" schema) props
          (gethash "required" schema) (list "path"))
    schema))

(defun %split-lines (text)
  (let ((lines '()) (start 0) (len (length text)))
    (loop
      (let ((pos (position #\Newline text :start start)))
        (cond
          (pos (push (subseq text start pos) lines) (setf start (1+ pos)))
          (t (when (< start len) (push (subseq text start) lines))
             (return)))))
    (nreverse lines)))

(defun %file-byte-size (path)
  (with-open-file (in path :direction :input :element-type '(unsigned-byte 8))
    (file-length in)))

(defun %read-file-text (path)
  "Return (values text truncated-p) read as UTF-8 up to +READ-TOOL-MAX-CHARS+
characters, or NIL if PATH does not decode as UTF-8 text."
  (handler-case
      (with-open-file (in path :direction :input :external-format :utf-8)
        (let* ((buf (make-string +read-tool-max-chars+))
               (n (read-sequence buf in)))
          (values (subseq buf 0 n) (not (null (read-char in nil nil))))))
    (error () nil)))

(defun %read-file-tool-handler (arguments context)
  (declare (ignore context))
  (let ((path (gethash "path" arguments))
        (offset (gethash "offset" arguments))
        (limit (gethash "limit" arguments)))
    (cond
      ((not (and (stringp path) (plusp (length path))))
       (values "read_file requires a non-empty path" t))
      ((not (probe-file path))
       (values (format nil "file not found: ~A" path) t))
      (t
       (handler-case
           (multiple-value-bind (text truncated-p) (%read-file-text path)
             (if (null text)
                 (values (format nil "binary file, ~:D bytes" (%file-byte-size path)) nil)
                 (let* ((lines (%split-lines text))
                        (start (max 0 (1- (or offset 1))))
                        (end (if (and limit (< start (length lines)))
                                 (min (length lines) (+ start limit))
                                 (length lines)))
                        (selected (if (< start (length lines))
                                      (subseq lines start end)
                                      '())))
                   (values
                    (with-output-to-string (out)
                      (loop for line in selected
                            for n from (1+ start)
                            do (format out "~D~C~A~%" n #\Tab line))
                      (when truncated-p
                        (format out "[truncated: file exceeds ~:D characters]~%"
                                +read-tool-max-chars+)))
                    nil))))
         (error ()
           (values (format nil "unable to read file: ~A" path) t)))))))

(defun make-read-tool-definition ()
  "No sandboxing: any path the harness process can reach is readable (see
issue #61/#62). OFFSET/LIMIT select a 1-indexed line range; content beyond
+READ-TOOL-MAX-CHARS+ is truncated, not silently dropped without notice."
  (make-tool-definition
   :name "read_file"
   :description "Read a file's contents from the container's filesystem.
No sandboxing: any path the harness process can reach is readable, not
just a project directory. PATH is required. OFFSET (1-indexed) and LIMIT
select a line range. Output is line-numbered (\"<n>\\t<text>\"). Large
files are truncated with an explicit notice; binary/non-UTF-8 files
return a size summary instead of their content."
   :input-schema (%read-schema)
   :handler #'%read-file-tool-handler))

(defparameter +write-tool-max-chars+ (* 5 1024 1024)
  "Cap on write_file's content length, rejected outright rather than
truncated: a truncated write would silently corrupt the caller's intended
file content, which is worse than refusing the write entirely.")

(defun %write-schema ()
  (let ((schema (%json-object "type" "object"))
        (props (%json-object))
        (path-field (%json-object "type" "string"))
        (content-field (%json-object "type" "string")))
    (setf (gethash "path" props) path-field
          (gethash "content" props) content-field
          (gethash "properties" schema) props
          (gethash "required" schema) (list "path" "content"))
    schema))

(defun %write-file-atomic (path content)
  "Write CONTENT to PATH via temp-file-then-rename so a failure partway
through never leaves a partially-written file at PATH."
  (ensure-directories-exist path)
  (let ((tmp (make-pathname :defaults path :type "tmp")))
    (with-open-file (out tmp :direction :output :if-exists :supersede
                         :if-does-not-exist :create :external-format :utf-8)
      (write-string content out)
      (finish-output out))
    (uiop:rename-file-overwriting-target tmp path)))

(defun %write-file-tool-handler (arguments context)
  (declare (ignore context))
  (let ((path (gethash "path" arguments))
        (content (gethash "content" arguments)))
    (cond
      ((not (and (stringp path) (plusp (length path))))
       (values "write_file requires a non-empty path" t))
      ((not (stringp content))
       (values "write_file requires string content" t))
      ((> (length content) +write-tool-max-chars+)
       (values (format nil "content exceeds the ~:D character limit; write rejected, no file was changed"
                       +write-tool-max-chars+)
               t))
      (t
       (handler-case
           (progn
             (%write-file-atomic path content)
             (values (format nil "wrote ~:D bytes to ~A" (%file-byte-size path) path) nil))
         (error ()
           (values (format nil "unable to write file: ~A" path) t)))))))

(defun make-write-tool-definition ()
  "No sandboxing: any path the harness process can reach can be written or
overwritten (see issue #61/#63). Overwrites without confirmation, by
design -- every catalog tool executes with no approval gate. Writes
atomically (temp file + rename); content over +WRITE-TOOL-MAX-CHARS+ is
rejected outright rather than truncated, since a truncated write would
silently corrupt the caller's intended file content."
  (make-tool-definition
   :name "write_file"
   :description "Write (creating or overwriting) a file's contents on the
container's filesystem. No sandboxing: any path the harness process can
reach is writable, not just a project directory. Overwrites an existing
file without confirmation. PATH and CONTENT are both required. Creates
parent directories as needed. Content over 5MB is rejected outright (the
write does not happen) rather than truncated."
   :input-schema (%write-schema)
   :handler #'%write-file-tool-handler))

(defparameter +bash-tool-default-timeout-seconds+ 120)
(defparameter +bash-tool-max-timeout-seconds+ 600)
(defparameter +bash-tool-max-output-chars+ (* 200 1024)
  "Cap per stream (stdout, stderr independently), not one shared budget:
stdout and stderr are drained concurrently on separate threads to avoid the
classic pipe deadlock when a command fills both simultaneously, which makes
a single shared byte budget impractical to enforce precisely.")

(defun %bash-schema ()
  (let ((schema (%json-object "type" "object"))
        (props (%json-object))
        (command-field (%json-object "type" "string"))
        (timeout-field (%json-object "type" "integer"))
        (cwd-field (%json-object "type" "string")))
    (setf (gethash "command" props) command-field
          (gethash "timeout_seconds" props) timeout-field
          (gethash "cwd" props) cwd-field
          (gethash "properties" schema) props
          (gethash "required" schema) (list "command"))
    schema))

(defun %read-stream-capped (stream max-chars)
  "Return (values text truncated-p). Reads up to MAX-CHARS characters from
STREAM; TRUNCATED-P is true only if strictly more data remained after that."
  (if (<= max-chars 0)
      (values "" (not (null (read-char stream nil nil))))
      (let* ((buf (make-string max-chars))
             (n (read-sequence buf stream)))
        (values (subseq buf 0 n)
                (and (= n max-chars) (not (null (read-char stream nil nil))))))))

(defun %kill-process-group (pgid signal)
  "Signal every process in PGID's group via SB-POSIX:KILLPG, returning NIL
on success -- including ESRCH, since a group that is already gone is what
a kill is for -- or a short failure description string. This must never
shell out to an external kill binary: the production web-ui image ships
none, which made an earlier RUN-PROGRAM-based kill a silent no-op under
IGNORE-ERRORS and wedged the session worker forever (#79)."
  (handler-case
      (progn (sb-posix:killpg pgid signal) nil)
    (sb-posix:syscall-error (e)
      (if (= (sb-posix:syscall-errno e) sb-posix:esrch)
          nil
          (format nil "killpg(~D, ~D) failed: ~A" pgid signal e)))))

(defun %bash-timeout-result-text (timeout-seconds kill-failure)
  "A timeout whose kill failed must say so, not claim the command was
killed: the caller may need to know a runaway process is still alive."
  (if kill-failure
      (format nil "command timed out after ~D seconds but could not be killed (~A); it may still be running"
              timeout-seconds kill-failure)
      (format nil "command timed out after ~D seconds and was killed" timeout-seconds)))

(defun %bounded-process-status-wait (process seconds)
  "Poll PROCESS until it leaves :RUNNING or SECONDS elapse; true if it
exited. Replaces SB-EXT:PROCESS-WAIT, which blocks unboundedly and would
wedge the session worker if the child could not be killed (#79)."
  (loop repeat (max 1 (ceiling (* seconds 10)))
        do (unless (eq (sb-ext:process-status process) :running)
             (return t))
           (sleep 0.1)
        finally (return (not (eq (sb-ext:process-status process) :running)))))

(defun %run-bash-command (command cwd timeout-seconds)
  "Return (values stdout stderr exit-code timed-out-p kill-failure). Runs
COMMAND via a shell. SB-EXT:RUN-PROGRAM already places its child in a new
process group of its own (the shell's PID doubles as its PGID), so the
whole group -- not just the direct shell -- is signaled on timeout:
SIGTERM, a short grace period, then SIGKILL, via %KILL-PROCESS-GROUP
(sb-posix, deliberately no external kill binary -- see #79). This mirrors,
at the scale of a single tool call, this project's existing process-tree
supervision precedent for the long-lived CLI subprocess (#17,
sm-harness-web-ui/docker/claude-agent-sdk-cl-supervisor.c).
(An earlier version wrapped the shell in `setsid`, but `setsid` forks a
detached grandchild and exits immediately unless given `--wait`, which
made SB-EXT:RUN-PROGRAM's own child -- and thus its exit code and process
group -- the wrong process entirely.)
EXIT-CODE is NIL when the child outlived every bounded wait (a failed
kill): the handler reports that distinctly rather than blocking forever."
  (let* ((process (apply #'sb-ext:run-program "/bin/sh"
                         (list "-c" command)
                         :output :stream :error :stream :wait nil :search t
                         (when (and cwd (plusp (length cwd)))
                           (list :directory cwd))))
         (pid (sb-ext:process-pid process))
         (state-lock (sb-thread:make-mutex :name "bash-tool-timeout"))
         (timed-out-p nil)
         (kill-failure nil)
         ;; Captured as a lexical value, not read from inside the spawned
         ;; thread: a new SB-THREAD does not inherit the calling thread's
         ;; dynamic (LET-rebound) value of a special variable, only its
         ;; global value, which would silently ignore a caller's override.
         (max-output-chars +bash-tool-max-output-chars+))
    (sb-thread:make-thread
     (lambda ()
       (sleep timeout-seconds)
       (when (eq (sb-ext:process-status process) :running)
         (sb-thread:with-mutex (state-lock) (setf timed-out-p t))
         (%kill-process-group pid sb-posix:sigterm)
         (sleep 0.2)
         ;; SIGKILL is the authoritative attempt: a failed SIGTERM followed
         ;; by a SIGKILL that succeeded (or found the group already gone)
         ;; is still a successful kill.
         (let ((failure (%kill-process-group pid sb-posix:sigkill)))
           (when failure
             (sb-thread:with-mutex (state-lock) (setf kill-failure failure))))))
     :name "bash-tool-timeout-watchdog")
    (let (stdout-text stdout-truncated stderr-text stderr-truncated)
      (let* ((stdout-thread
               (sb-thread:make-thread
                (lambda ()
                  (multiple-value-setq (stdout-text stdout-truncated)
                    (%read-stream-capped (sb-ext:process-output process)
                                         max-output-chars)))
                :name "bash-tool-stdout-reader"))
             (stderr-thread
               (sb-thread:make-thread
                (lambda ()
                  (multiple-value-setq (stderr-text stderr-truncated)
                    (%read-stream-capped (sb-ext:process-error process)
                                         max-output-chars)))
                :name "bash-tool-stderr-reader"))
             ;; Reader threads end when the child's pipes hit EOF, normally
             ;; within moments of exit or of the timeout kill. If the kill
             ;; itself failed they may never end: bound every wait and
             ;; abandon the readers rather than block the session worker
             ;; forever -- the wedge, not the thread leak, is the
             ;; catastrophic outcome (#79).
             (grace (+ timeout-seconds 10))
             (abandoned-p nil))
        (when (eq :sm-reader-timeout
                  (sb-thread:join-thread stdout-thread :timeout grace
                                                      :default :sm-reader-timeout))
          (setf abandoned-p t))
        (when (eq :sm-reader-timeout
                  (sb-thread:join-thread stderr-thread :timeout grace
                                                      :default :sm-reader-timeout))
          (setf abandoned-p t))
        ;; EOF on both pipes does not imply exit (a child can close its own
        ;; fds and keep running), so the status wait stays bounded too.
        (unless (%bounded-process-status-wait process grace)
          (setf abandoned-p t))
        (multiple-value-bind (final-timed-out final-kill-failure)
            (sb-thread:with-mutex (state-lock)
              (values timed-out-p kill-failure))
          (values (if stdout-truncated
                      (concatenate 'string stdout-text (format nil "~%[stdout truncated]"))
                      (or stdout-text ""))
                  (if stderr-truncated
                      (concatenate 'string stderr-text (format nil "~%[stderr truncated]"))
                      (or stderr-text ""))
                  (unless abandoned-p (sb-ext:process-exit-code process))
                  final-timed-out
                  final-kill-failure))))))

(defun %bash-tool-handler (arguments context)
  (declare (ignore context))
  (let* ((command (gethash "command" arguments))
         (cwd (gethash "cwd" arguments))
         (timeout (or (gethash "timeout_seconds" arguments) +bash-tool-default-timeout-seconds+)))
    (cond
      ((not (and (stringp command) (plusp (length command))))
       (values "bash requires a non-empty command" t))
      ((not (and (integerp timeout) (plusp timeout)))
       (values "bash requires a positive integer timeout_seconds" t))
      ((> timeout +bash-tool-max-timeout-seconds+)
       (values (format nil "timeout_seconds exceeds the ~D second limit; command rejected, not run"
                       +bash-tool-max-timeout-seconds+)
               t))
      (t
       (handler-case
           (multiple-value-bind (stdout stderr exit-code timed-out-p kill-failure)
               (%run-bash-command command cwd timeout)
             (cond
               (timed-out-p
                (values (%bash-timeout-result-text timeout kill-failure) t))
               ((null exit-code)
                ;; The child outlived every bounded wait without a timeout
                ;; being declared (e.g. it closed its own pipes and lingered).
                (values "unable to determine command exit status; the command may still be running" t))
               (t
                (values
                 (format nil "exit code: ~D~%stdout:~%~A~%stderr:~%~A" exit-code stdout stderr)
                 nil))))
         (error ()
           (values "unable to run command" t)))))))

(defun make-bash-tool-definition ()
  "No sandboxing beyond the container's own non-root user and whatever its
filesystem/network permit (see issue #61/#64): no bubblewrap/firejail/
seccomp, no allow/denylist. The shell command runs in its own process
group (SB-EXT:RUN-PROGRAM's default), so the whole group is what gets
signaled on timeout, not just the direct shell."
  (make-tool-definition
   :name "bash"
   :description "Run a shell command on the container's filesystem via
/bin/sh -c. No sandboxing beyond the container's own non-root user and
whatever filesystem/network access it has -- there is no additional
process isolation. COMMAND is required. TIMEOUT_SECONDS defaults to 120,
capped at 600 (a larger request is rejected outright, not clamped). CWD
defaults to the harness process's own working directory. Output over
roughly 200KB per stream is truncated. A non-zero exit code is a normal
result, not a tool failure -- check the reported exit code."
   :input-schema (%bash-schema)
   :handler #'%bash-tool-handler))

(defparameter *reload-harness-system* :sm-harness
  "ASDF system RELOAD_HARNESS recompiles and reloads. Defaults to
:sm-harness itself so this tool (and its tests) work standalone: sm-harness
must load and run without CLOG (see docs/sm-harness.md), so it cannot
depend on sm-harness-web-ui to know its name. The web UI application layer
overrides this at startup to :sm-harness-web-ui, since ASDF's own
dependency graph then transitively covers sm-harness and
claude-agent-sdk-cl too in a single call.")

(defparameter *post-reload-hook* nil
  "Optional zero-argument function RELOAD_HARNESS calls (best-effort, never
allowed to turn a successful reload into a failure -- see #78) once
*RELOAD-HARNESS-SYSTEM* has finished reloading without error. Defaults to
nil so sm-harness stays usable standalone/headless. sm-harness-web-ui
installs one at startup to re-point CLOG's routing at the freshly reloaded
code and push a page refresh to every currently open browser tab, so a
successful reload is visible without a human noticing and hitting F5.")

(defun %reload-schema ()
  (let ((schema (%json-object "type" "object"))
        (props (%json-object))
        (force-field (%json-object "type" "boolean")))
    (setf (gethash "force" props) force-field
          (gethash "properties" schema) props)
    schema))

(defun %reload-harness-tool-handler (arguments context)
  (declare (ignore context))
  (let ((force (and (gethash "force" arguments) t))
        (warnings '()))
    (handler-case
        (handler-bind ((warning (lambda (w)
                                  (push (princ-to-string w) warnings)
                                  (muffle-warning w))))
          ;; :OVERRIDE T starts a fresh ASDF session: ASDF forbids :FORCE
          ;; disagreeing with an already-active session's own force setting
          ;; in a nested OPERATE call, which this would otherwise be if
          ;; invoked (e.g. in a test) from inside another ASDF operation.
          (asdf/session:call-with-asdf-session
           (lambda () (asdf:load-system *reload-harness-system* :force force))
           :override t :override-cache t))
      (error (c)
        (return-from %reload-harness-tool-handler
          (values
           (format nil "reload failed: ~A~%~
Compile/load errors from an incompatible structure or class redefinition ~
can leave this Lisp image permanently unable to reload that type again: ~
every further reload_harness call will fail identically, even after ~
reverting the source, until the container is restarted."
                   c)
           t))))
    ;; A successful reload is worth reporting even if the (optional, #78)
    ;; post-reload hook itself misbehaves -- e.g. a browser that vanished
    ;; mid-broadcast -- so a hook failure is folded into the warnings text
    ;; rather than escalated to IS-ERROR T.
    (when *post-reload-hook*
      (handler-case (funcall *post-reload-hook*)
        (error (c)
          (push (format nil "post-reload hook failed: ~A" c) warnings))))
    (let ((collected (nreverse warnings)))
      (values
       (format nil "reloaded ~(~A~)~:[~; (forced)~]~@[~%warnings:~%~{  ~A~%~}~]"
               *reload-harness-system* force collected collected)
       nil))))

(defun make-reload-tool-definition ()
  "No sandboxing beyond what ASDF/SBCL themselves provide (see issue #65).
An incompatible structure/class redefinition (e.g. changing a defstruct's
slots) can leave this Lisp image permanently unable to reload that type
again for the rest of the process's life, even after reverting the
source -- empirically confirmed, not theoretical; a container restart is
the only fix at that point."
  (make-tool-definition
   :name "reload_harness"
   :description "Recompile and reload changed Lisp source files into the
running harness image via ASDF, so an edit (e.g. made with write_file) to
this project's own source takes effect without a container restart. ASDF
only recompiles files that actually changed unless FORCE (boolean,
default false) is set, which bypasses that check and recompiles
everything. Ordinary compile/load errors are reported as a failed
result, not a crash -- but an incompatible structure/class redefinition
(e.g. changing a defstruct's slot list) can leave this image permanently
unable to reload that type again, even after reverting the source: if an
error mentions instance length or layout, only a container restart will
fix it, not another reload_harness call."
   :input-schema (%reload-schema)
   :handler #'%reload-harness-tool-handler))

(defun default-tool-catalog ()
  "Return product-owned tool metadata, not SDK objects."
  (make-tool-catalog
   :servers
   (list (make-tool-server-definition
          :name "sm_harness"
          :version "0.1.0"
          :tools (list (make-echo-tool-definition)
                       (make-read-tool-definition)
                       (make-write-tool-definition)
                       (make-bash-tool-definition)
                       (make-reload-tool-definition))))))

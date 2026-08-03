(in-package #:sm-harness)

;;;; Product-owned tool definitions.  These are deliberately SDK-free:
;;;; metadata crosses the adapter boundary; handler closures remain local.

(defstruct (tool-definition (:constructor make-tool-definition))
  (name "" :type string)
  (description "" :type string)
  input-schema
  ;; A function designator: a symbol naming a global function is strongly
  ;; preferred over a captured #'name function object (see #116). SBCL/ANSI
  ;; CL semantics: (function name), evaluated once when a *-TOOL-DEFINITION
  ;; constructor runs, freezes a snapshot of NAME's function cell as of that
  ;; moment -- a later (DEFUN NAME ...), e.g. from RELOAD_HARNESS, rebinds
  ;; the symbol's global function cell to a *new* function object but does
  ;; not mutate the already-captured one, so an already-open session's tool
  ;; call keeps running the pre-reload body forever. FUNCALLing a symbol
  ;; instead performs a fresh lookup every call, so a symbol handler's
  ;; *own* top-level body hot-reloads correctly mid-session, same as calls
  ;; it makes internally already did (ordinary, non-inlined function calls
  ;; are late-bound by default). %SDK-TOOL-FROM-DEFINITION (sdk-adapter.lisp)
  ;; already just FUNCALLs this slot's value, so either designator works;
  ;; only the symbol form gets the hot-reload property. An anonymous LAMBDA
  ;; (nothing else in this file needs one) has no symbol to late-bind and is
  ;; frozen the same way a captured #'name would be -- fine for a handler
  ;; that will never need a live edit, not otherwise.
  handler
  ;; NIL, or a plist of :READ-ONLY-P/:DESTRUCTIVE-P/:IDEMPOTENT-P/:OPEN-WORLD-P
  ;; booleans -- claude-agent-sdk-cl:make-sdk-tool's own MCP ToolAnnotations
  ;; shape (see mcp.lisp there), passed through verbatim by
  ;; %SDK-TOOL-FROM-DEFINITION (sdk-adapter.lisp). Every constructor below
  ;; sets this explicitly (see #123's table): no tool here defaults to
  ;; silently unannotated, since an absent :READ-ONLY-P T is what both the
  ;; real `claude` CLI and this SDK's own TOOL-EXECUTION-LOCK read as "not
  ;; safe to run concurrently" -- the conservative, always-correct default,
  ;; but one this file states on purpose per tool rather than leaves implicit.
  annotations)

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
   ;; #123: no side effects at all -- read-only and idempotent.
   :annotations '(:read-only-p t :destructive-p nil :idempotent-p t :open-world-p nil)
   :handler (lambda (arguments context)
              (declare (ignore context))
              (format nil "echo: ~A" (or (gethash "text" arguments) "")))))

(defparameter +tool-result-max-chars+ (* 32 1024)
  "Ceiling on the characters a single tool result hands back to the model.

Not a memory guard -- it is a client-side constraint. The CLI persists any
tool result above roughly 45KB to a file on disk and replaces it with a 2KB
preview whose wrapper text carries no instruction to go read the rest, so an
oversized result reaches the model as a short, plausible-looking answer that
is silently missing most of its content: a session asked to read a 959-line
doc received about 40 lines of it and reasoned from those alone (#126).
Handlers stay under that line and say where to resume instead.")

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

(defun %read-result-text (selected first-line file-truncated-p)
  "Render SELECTED lines, numbered from FIRST-LINE, as one tool result of
at most +TOOL-RESULT-MAX-CHARS+ characters. A result cut short by that cap
ends with a notice naming the offset to resume from, so paging through a
large file is an instruction the model receives rather than a convention it
has to infer (#126)."
  (let* ((cap +tool-result-max-chars+)
         (emitted 0)
         (cut-line nil)
         (body
           (with-output-to-string (out)
             (let ((used 0))
               (loop for line in selected
                     for number from first-line
                     do (let* ((chunk (format nil "~D~C~A~%" number #\Tab line))
                               (len (length chunk)))
                          (cond
                            ;; One line longer than the entire cap (minified
                            ;; JSON, a bundled .js, ...) is cut mid-line:
                            ;; emitting it whole would defeat the cap.
                            ((and (zerop emitted) (> len cap))
                             (write-string (subseq chunk 0 (max 1 (1- cap))) out)
                             (terpri out)
                             (setf cut-line number emitted 1)
                             (return))
                            ((> (+ used len) cap) (return))
                            (t (write-string chunk out)
                               (incf used len)
                               (incf emitted)))))))))
    (with-output-to-string (out)
      (write-string body out)
      (let ((remaining (- (length selected) emitted)))
        (cond
          (cut-line
           (format out "[truncated: line ~:D exceeds this tool's ~:D character result cap and was cut mid-line; ~:D further line~:P not shown -- read it in pieces with bash]~%"
                   cut-line cap remaining))
          ((plusp remaining)
           (format out "[truncated: ~:D more line~:P not shown, this result hit the ~:D character cap -- continue with read_file offset=~D]~%"
                   remaining cap (+ first-line emitted)))))
      (when file-truncated-p
        (format out "[truncated: file exceeds ~:D characters]~%" +read-tool-max-chars+)))))

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
                   (values (%read-result-text selected (1+ start) truncated-p)
                           nil))))
         (error ()
           (values (format nil "unable to read file: ~A" path) t)))))))

(defun make-read-tool-definition ()
  "No sandboxing: any path the harness process can reach is readable (see
issue #61/#62). OFFSET/LIMIT select a 1-indexed line range; content beyond
+READ-TOOL-MAX-CHARS+ (or beyond one result's +TOOL-RESULT-MAX-CHARS+) is
truncated, not silently dropped without notice."
  (make-tool-definition
   :name "read_file"
   :description "Read a file's contents from the container's filesystem.
No sandboxing: any path the harness process can reach is readable, not
just a project directory. PATH is required. OFFSET (1-indexed) and LIMIT
select a line range. Output is line-numbered (\"<n>\\t<text>\"). One
result is capped at roughly 32,000 characters: a read cut short by that
cap ends with a notice naming the offset to continue from, and reading a
large file whole therefore takes several calls. Binary/non-UTF-8 files
return a size summary instead of their content."
   :input-schema (%read-schema)
   ;; #123: a pure filesystem read, no mutation -- read-only and idempotent.
   :annotations '(:read-only-p t :destructive-p nil :idempotent-p t :open-world-p nil)
   :handler '%read-file-tool-handler))

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
through never leaves a partially-written file at PATH.

Renames via SB-POSIX:RENAME on native namestrings, deliberately bypassing
CL:RENAME-FILE (what UIOP:RENAME-FILE-OVERWRITING-TARGET wraps around).
For any PATH whose file name has no extension (\"Dockerfile\",
\"Makefile\", \"LICENSE\", ...), PATHNAME-TYPE is NIL, and per CLHS
19.2.3 RENAME-FILE merges components left unspecified (NIL) in its
new-name argument in from the pathname of the file actually being
renamed -- i.e. the TMP file, whose type is \"tmp\". That silently
rewrites the destination back onto TMP's own name, so the rename becomes
a no-op self-rename: PATH is left untouched, the .tmp file survives
renamed onto itself, and the caller is told the write succeeded (see
#96). SB-POSIX:RENAME is a thin syscall wrapper over raw strings with no
such pathname-merging semantics."
  (ensure-directories-exist path)
  (let ((tmp (make-pathname :defaults path :type "tmp")))
    (with-open-file (out tmp :direction :output :if-exists :supersede
                         :if-does-not-exist :create :external-format :utf-8)
      (write-string content out)
      (finish-output out))
    (sb-posix:rename (uiop:native-namestring tmp) (uiop:native-namestring path))))

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
   ;; #123: overwrites existing files with no confirmation -- two concurrent
   ;; writers to the same path is exactly the hazard to avoid, so this is
   ;; deliberately NOT read-only.
   :annotations '(:read-only-p nil :destructive-p t :idempotent-p nil :open-world-p nil)
   :handler '%write-file-tool-handler))

(defparameter +bash-tool-default-timeout-seconds+ 120)
(defparameter +bash-tool-max-timeout-seconds+ 600)
(defparameter +bash-tool-max-output-chars+ (floor +tool-result-max-chars+ 2)
  "Cap per stream (stdout, stderr independently), not one shared budget:
stdout and stderr are drained concurrently on separate threads to avoid the
classic pipe deadlock when a command fills both simultaneously, which makes
a single shared byte budget impractical to enforce precisely. Half of
+TOOL-RESULT-MAX-CHARS+ each, so even a command that fills both streams
still returns a result the client delivers intact instead of persisting to
disk behind a 2KB preview (#126).")

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

(defparameter *bash-guard-command-line*
  (format nil "~{~A~^ ~}" sb-ext:*posix-argv*)
  "Command line the bash tool's self-kill guard protects, in the
space-joined form pkill -f matches against /proc/<pid>/cmdline. Defaults
to this process's own argv. A special so tests can rebind it to a known
value instead of depending on how the test image was invoked.")

(defun %command-basename (token)
  "TOKEN's file-name component, or TOKEN itself when it is not a parsable
namestring. SBCL's pathname parser reads a backslash as an escape character,
so FILE-NAMESTRING signals NAMESTRING-PARSE-ERROR on any shell token ending
in one. The guard splits a command on the pipe character, so a grep pattern
using two or more escaped-pipe alternations produces exactly such a token as
a segment's head -- the escaped pipe before the second alternative becomes a
trailing backslash. That error escaped the handler as a bare JSON-RPC -32603
'SDK tool handler failed', rejecting an ordinary grep with no diagnosis and
no mention of the guard at all (#126). An unparsable token is by definition
not kill/pkill/killall, so reading it literally is also the right answer."
  (handler-case (file-namestring token)
    (error () token)))

(defun %bash-guard-process-name ()
  "Process name (comm) form of *BASH-GUARD-COMMAND-LINE*'s executable,
which is what pkill and killall match when -f is not given. The kernel
truncates comm to 15 characters, and the matchers compare against that."
  (let* ((cmdline *bash-guard-command-line*)
         (end (or (position #\Space cmdline) (length cmdline)))
         (name (%command-basename (subseq cmdline 0 end))))
    (if (> (length name) 15) (subseq name 0 15) name)))

(defun %strip-token-quotes (token)
  (let ((len (length token)))
    (if (and (>= len 2)
             (member (char token 0) '(#\' #\"))
             (char= (char token 0) (char token (1- len))))
        (subseq token 1 (1- len))
        token)))

(defun %pattern-matches-guarded-p (pattern subject)
  "True when PATTERN, read as the extended regex pkill/pgrep would use,
matches SUBJECT. An unparsable pattern counts as non-matching: pkill
itself would error out on it rather than kill anything."
  (handler-case (and (cl-ppcre:scan pattern subject) t)
    (error () nil)))

(defun %self-kill-command-p (command)
  "True when some shell segment of COMMAND would signal the harness's own
Lisp process: a kill targeting PID 1 (the harness under Docker) or this
process's PID, or a pkill/killall whose pattern matches the harness's own
command line or process name -- the same match those tools themselves
would make. Kills aimed at any other process, including scratch sbcl
servers a session starts to test its changes, are deliberately allowed:
the guard checks what a command would hit, not what tool it uses. A
best-effort static reading of the command string, not a sandbox (#61/#64
keep bash unsandboxed on purpose); its job is the reflexive
restart-the-server footgun (#101), not deliberate evasion."
  (dolist (segment (uiop:split-string command :separator '(#\; #\& #\| #\Newline)) nil)
    (let* ((tokens (mapcar #'%strip-token-quotes
                           (remove "" (uiop:split-string segment
                                                         :separator '(#\Space #\Tab))
                                   :test #'string=)))
           (head (and tokens (string-downcase (%command-basename (first tokens)))))
           (args (rest tokens))
           ;; Flag values (e.g. a -P parent pid) can land in here too; a
           ;; stray candidate only costs a spurious regex test.
           (candidates (remove-if (lambda (tok)
                                    (or (zerop (length tok)) (char= (char tok 0) #\-)))
                                  args)))
      (cond
        ((equal head "kill")
         (when (or (member "1" candidates :test #'string=)
                   (member (princ-to-string (sb-posix:getpid)) candidates
                           :test #'string=))
           (return t)))
        ((equal head "pkill")
         (let ((subject (if (or (member "-f" args :test #'string=)
                                (member "--full" args :test #'string=))
                            *bash-guard-command-line*
                            (%bash-guard-process-name))))
           (when (some (lambda (p) (%pattern-matches-guarded-p p subject)) candidates)
             (return t))))
        ((equal head "killall")
         ;; Exact name comparison, as killall does -- except under -r,
         ;; where it too matches by regex.
         (let ((name (%bash-guard-process-name)))
           (when (some (lambda (p)
                         (or (string= p name)
                             (and (member "-r" args :test #'string=)
                                  (%pattern-matches-guarded-p p name))))
                       candidates)
             (return t))))))))

(defun %bash-self-kill-rejection ()
  (format nil "command rejected, not run: it would signal the harness's own sbcl process -- the server running this very session -- whose command line is: ~A~%Stopping other processes is fine, including scratch sbcl servers started to test changes: kill their specific PID, or use a pkill pattern that cannot match the command line above. To make Lisp source edits take effect in this harness, call reload_harness."
          *bash-guard-command-line*))

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
      ((%self-kill-command-p command)
       (values (%bash-self-kill-rejection) t))
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
roughly 16KB per stream is truncated (pipe through head/grep, or write to
a file and read it back in ranges, when you need more). A non-zero exit
code is a normal result, not a tool failure -- check the reported exit
code. One guardrail: a kill/pkill/killall whose target or pattern would hit the
harness's own sbcl process -- the server running this session -- is
rejected outright. Kills aimed at any other process, including scratch
sbcl servers started to test changes, run normally; call reload_harness
when the goal is picking up Lisp source edits in this harness itself."
   :input-schema (%bash-schema)
   ;; #123: arbitrary shell -- deliberately NOT marked read-only-safe. Matches
   ;; the real `claude` CLI's own stated reason its built-in Bash tool isn't
   ;; parallel-safe either: a read-only `grep` and a destructive `git push`
   ;; both run through this one tool, and nothing here can tell them apart.
   :annotations '(:read-only-p nil :destructive-p t :idempotent-p nil :open-world-p t)
   :handler '%bash-tool-handler))

(defvar *reload-harness-system* :sm-harness
  "ASDF system RELOAD_HARNESS recompiles and reloads. Defaults to
:sm-harness itself so this tool (and its tests) work standalone: sm-harness
must load and run without CLOG (see docs/sm-harness.md), so it cannot
depend on sm-harness-web-ui to know its name. The web UI application layer
overrides this at startup to :sm-harness-web-ui, since ASDF's own
dependency graph then transitively covers sm-harness and
claude-agent-sdk-cl too in a single call.

MUST stay DEFVAR, not DEFPARAMETER (found while chasing #102): this very
file is part of :sm-harness, so it gets reloaded as a dependency on *every*
RELOAD_HARNESS call, including ones targeting :sm-harness-web-ui. A
DEFPARAMETER unconditionally reassigns on each load, which silently reset
this back to :sm-harness right after the web UI's startup override took
effect -- so only the very first reload of a process's life ever actually
touched sm-harness-web-ui; every one after that quietly reloaded
:sm-harness alone (still reported as success) while the running web UI's
own Lisp source went stale. DEFVAR only initializes when unbound, so
main's startup SETF (application.lisp) survives every later reload.")

(defvar *post-reload-hook* nil
  "Optional zero-argument function RELOAD_HARNESS calls (best-effort, never
allowed to turn a successful reload into a failure -- see #78) once
*RELOAD-HARNESS-SYSTEM* has finished reloading without error. Defaults to
nil so sm-harness stays usable standalone/headless. sm-harness-web-ui
installs one at startup to re-point CLOG's routing at the freshly reloaded
code and push a page refresh to every currently open browser tab, so a
successful reload is visible without a human noticing and hitting F5.

Also DEFVAR, not DEFPARAMETER, for the same reason as
*RELOAD-HARNESS-SYSTEM* above: this file reloads on every RELOAD_HARNESS
call, and a DEFPARAMETER here would silently drop the web UI's installed
hook (CLOG re-routing + live browser refresh, #78) after the first reload
of a process's life.")

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
      ;; ~@[str~] consumes COLLECTED only if it is NIL (the no-warnings
      ;; case); when non-NIL it is left in the argument list for the ~{~} that
      ;; follows inside str, so COLLECTED is passed exactly once here -- a
      ;; second copy would overrun this format string's directive count.
      (values
       (format nil "reloaded ~(~A~)~:[~; (forced)~]~@[~%warnings:~%~{  ~A~%~}~]"
               *reload-harness-system* force collected)
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
   ;; #123: mutates the running process/loaded code -- not read-only. Reloading
   ;; already-current source is a safe (ASDF timestamp-based) no-op, so this
   ;; is idempotent.
   :annotations '(:read-only-p nil :destructive-p nil :idempotent-p t :open-world-p nil)
   :handler '%reload-harness-tool-handler))

(defparameter +web-search-max-results-default+ 5
  "MAX_RESULTS when a caller omits it entirely.")

(defparameter +web-search-max-results-cap+ 10
  "Hard ceiling on MAX_RESULTS regardless of what a caller asks for --
clamped silently, not rejected: unlike write_file's oversized-content
guard (where truncating would corrupt the caller's data), a smaller
result set here is still a fully valid, honest answer to the same
query.")

(defparameter +web-search-timeout-seconds+ 20
  "Connection/request timeout for the Tavily HTTPS call. A hung upstream
must not wedge the session worker indefinitely (same concern as the bash
tool's own timeout, #79) -- this bounds it instead.")

(defvar *tavily-api-key-fn* (lambda () (uiop:getenv "TAVILY_API_KEY"))
  "Zero-argument function returning the Tavily API key configured in the
process environment, or NIL/empty if there isn't one. A function, not a
bare special holding the value, so: (1) tests can stub it without ever
touching the real process environment, and (2) a key set or rotated in
the environment before a session starts is always picked up at call
time, not frozen at image-load time the way a top-level (UIOP:GETENV
...) capture would be.")

(defun %web-search-schema ()
  (let ((schema (%json-object "type" "object"))
        (props (%json-object))
        (query-field (%json-object "type" "string"))
        (max-results-field (%json-object "type" "integer")))
    (setf (gethash "query" props) query-field
          (gethash "max_results" props) max-results-field
          (gethash "properties" schema) props
          (gethash "required" schema) (list "query"))
    schema))

(defun %tavily-search-request (api-key query max-results)
  "Perform the actual HTTPS POST to Tavily's /search endpoint (see
https://docs.tavily.com). Returns (values response-body-string
http-status); a transport failure (DNS, TLS, timeout, connection
refused, ...) signals a Lisp error rather than fabricating a status, so
%WEB-SEARCH-TOOL-HANDLER's own HANDLER-CASE is what turns that into a
safe tool-result error -- this function's job is only the HTTP call."
  (let ((body (with-output-to-string (s)
                (yason:encode (%json-object "api_key" api-key
                                             "query" query
                                             "max_results" max-results
                                             "search_depth" "basic")
                              s))))
    (multiple-value-bind (response-body status)
        (drakma:http-request "https://api.tavily.com/search"
                              :method :post
                              :content-type "application/json"
                              :content body
                              :connection-timeout +web-search-timeout-seconds+
                              :external-format-out :utf-8
                              :external-format-in :utf-8
                              :want-stream nil)
      (values (if (stringp response-body)
                  response-body
                  (map 'string #'code-char response-body))
              status))))

(defvar *web-search-request-fn* #'%tavily-search-request
  "(api-key query max-results) -> (values response-body-string
http-status). The tool handler's sole network seam: defaults to the real
Tavily HTTPS call, but tests rebind this to a stub so the suite never
makes a live network request or depends on a real TAVILY_API_KEY, the
same dependency-injection shape *BASH-GUARD-COMMAND-LINE* uses above for
the bash tool's self-kill guard.")

(defun %web-search-format-results (parsed)
  "PARSED is Tavily's JSON response, decoded by YASON into hash-tables
(objects) and lists (arrays) -- the same representation
%JSON-DECODE-FILE relies on elsewhere in this system. Renders the
\"results\" array as numbered, readable text; a missing or empty array
renders as an explicit \"no results\" line so an empty answer is never
mistaken for truncated or failed output."
  (let ((results (gethash "results" parsed)))
    (if (or (not (consp results)) (zerop (length results)))
        "no results"
        (with-output-to-string (out)
          (loop for r in results
                for n from 1
                do (let ((content (or (gethash "content" r) "")))
                     (format out "~D. ~A~%   ~A~%   ~A~%~%"
                             n
                             (or (gethash "title" r) "(untitled)")
                             (or (gethash "url" r) "")
                             (if (> (length content) 400)
                                 (concatenate 'string (subseq content 0 400) "...")
                                 content))))))))

(defun %web-search-tool-handler (arguments context)
  (declare (ignore context))
  (let* ((query (gethash "query" arguments))
         (max-results (or (gethash "max_results" arguments)
                          +web-search-max-results-default+))
         (api-key (funcall *tavily-api-key-fn*)))
    (cond
      ((not (and (stringp query) (plusp (length query))))
       (values "web_search requires a non-empty query" t))
      ((not (and (integerp max-results) (plusp max-results)))
       (values "web_search requires a positive integer max_results" t))
      ((not (and (stringp api-key) (plusp (length api-key))))
       (values "web_search is not configured: no TAVILY_API_KEY is set in the environment" t))
      (t
       (let ((capped (min max-results +web-search-max-results-cap+)))
         (handler-case
             (multiple-value-bind (body status)
                 (funcall *web-search-request-fn* api-key query capped)
               (if (eql status 200)
                   (handler-case
                       (values (%web-search-format-results (yason:parse body)) nil)
                     (error ()
                       (values "web search failed: could not parse the response" t)))
                   (values (format nil "web search failed: HTTP ~A~@[~%~A~]"
                                   status
                                   (and (stringp body) (plusp (length body)) body))
                           t)))
           (error (c)
             (values (format nil "web search failed: ~A" c) t))))))))

(defun make-web-search-tool-definition ()
  "Uses Tavily's HTTPS search API (docs.tavily.com), reading
TAVILY_API_KEY from the environment at call time via
*TAVILY-API-KEY-FN* -- not at catalog-build time -- so a key configured
before a session starts is always honored. An unconfigured key, an
upstream HTTP error, or a malformed response all report as a normal
(is-error t) tool result rather than a Lisp condition, matching every
other catalog tool's contract; only a genuine handler bug still escalates
to the SDK's generic crash path."
  (make-tool-definition
   :name "web_search"
   :description "Search the web via the Tavily API. QUERY is required.
MAX_RESULTS (default 5) is clamped to 10 regardless of what is
requested. Requires TAVILY_API_KEY to be configured in the environment;
if it is not, this returns a tool-result error rather than crashing.
Each result includes a title, URL, and a short content excerpt."
   :input-schema (%web-search-schema)
   ;; #123: never mutates local state, so read-only; hits an external network
   ;; API whose results can legitimately change between identical calls, so
   ;; not idempotent, and open-world.
   :annotations '(:read-only-p t :destructive-p nil :idempotent-p nil :open-world-p t)
   :handler '%web-search-tool-handler))

(defvar *tool-harness* nil
  "The live SM-HARNESS:HARNESS instance a tool handler may operate against,
e.g. to look up or mutate a *different* session's durable state than the
one the calling tool call is itself running inside. NIL by default so
this file keeps loading and running standalone (headless sm-harness, its
own test suite) with no application wired up -- a handler that needs it
reports a safe, clear tool-result error instead of crashing when it is
unset. sm-harness-web-ui's START-WEB-UI sets this to its own *APP-HARNESS*
singleton at startup (the same instance already used for every other
harness call), mirroring the *TAVILY-API-KEY-FN*/*BASH-GUARD-COMMAND-LINE*
dependency-injection points above: this file (:SM-HARNESS) must not
itself depend on :SM-HARNESS-WEB-UI, so the wiring happens in the other
direction, at application startup, not via an import here.")

(defvar *current-session-record* nil
  "The SESSION-RECORD (model.lisp) of the session whose client connection
is currently being (re)built -- NIL unless %ENSURE-CLIENT (runtime.lisp)
has it bound, which it does for the whole LET* that constructs that
connection's catalog and SDK options, precisely so this stays
authoritative rather than something a tool argument could misreport:
unlike SET-SESSION-TITLE's SESSION-ID (a plain, model-supplied argument,
fine for a rename a human can always correct), RUN_SUBAGENT (#142) needs
the *actual* calling session's id to stamp as a spawned child's
PARENT-SESSION-ID, and a confused or careless model asked to supply its
own id is exactly the failure mode that would corrupt that audit trail.

Only ever safe to read *synchronously*, during catalog/SDK-option
construction -- never from inside a running tool handler. Every MCP tool
call actually executes on a freshly spawned thread
(CLAUDE-AGENT-SDK-CL's %CLIENT-SPAWN-TOOL-THREAD) that was never inside
%ENSURE-CLIENT's dynamic extent, so a handler that reads this special
directly always sees NIL, no matter how correctly it was bound upstream --
a real bug this exact comment used to invite before #142 was first tested
live. DEFAULT-TOOL-CATALOG reads this once, synchronously, to omit
RUN_SUBAGENT's own tool definition when this session is itself a subagent
(#142's \"no recursive spawning\" decision) -- that use is fine as-is,
since it runs at catalog-construction time. %SDK-TOOL-FROM-DEFINITION
(sdk-adapter.lisp) also reads this once, synchronously, at the same time,
to capture the calling session's id into the per-connection SDK wrapper
closure it builds -- which then passes it down to the handler via
CONTEXT's :CALLING-SESSION-ID, a genuine argument that survives the
thread hop this special cannot. NIL by default so this file keeps loading
and running standalone with no runtime wired up, same reasoning as
*TOOL-HARNESS*.")

(defun %set-session-title-schema ()
  (let ((schema (%json-object "type" "object"))
        (props (%json-object))
        (session-id-field (%json-object "type" "string"))
        (title-field (%json-object "type" "string")))
    (setf (gethash "session_id" props) session-id-field
          (gethash "title" props) title-field
          (gethash "properties" schema) props
          (gethash "required" schema) (list "session_id" "title"))
    schema))

(defun %set-session-title-tool-handler (arguments context)
  (declare (ignore context))
  (let ((session-id (gethash "session_id" arguments))
        (title (gethash "title" arguments)))
    (cond
      ((not (and (stringp session-id) (plusp (length session-id))))
       (values "set_session_title requires a non-empty session_id" t))
      ((not (stringp title))
       (values "set_session_title requires a string title" t))
      ((null *tool-harness*)
       (values "set_session_title is unavailable: no harness is wired up for tool calls in this process" t))
      (t
       (handler-case
           (let ((summary (set-session-title *tool-harness* session-id title)))
             (values (format nil "session ~A title set to ~S"
                             session-id (session-summary-title summary))
                     nil))
         (harness-error (c)
           (values (format nil "set_session_title failed: ~A" (harness-error-message c)) t))
         (error (c)
           (values (format nil "unable to set session title: ~A" c) t)))))))

(defun make-set-session-title-tool-definition ()
  "Renames a session's stored TITLE -- the label shown on the home screen's
session chip and in a session's own Info panel. The DESCRIPTION text tells
the calling model to invoke this proactively -- once it knows what a
session is about, and again whenever that subject changes -- rather than
only on an explicit rename request; nothing on this side enforces that
(there is no way to), it is entirely a model-behavior instruction carried
in the tool metadata itself. SESSION_ID is required: it
is not inferred from which session is making the call, so a call always
says explicitly which session it is renaming (a session normally already
knows its own id -- it is named in this very agent's system prompt -- but
nothing stops one session from renaming another, consistent with every
other catalog tool's no-sandboxing stance, see #61 for read_file/write_file/
bash). TITLE is rejected outright, not truncated, if empty or over
+SESSION-TITLE-MAX-CHARS+ (200) characters -- a short display label has no
good silent-truncation behavior. Requires *TOOL-HARNESS* to be configured;
reports a safe tool-result error, not a crash, when it is not, or when
SESSION_ID names no known session."
  (make-tool-definition
   :name "set_session_title"
   :description "Rename a session: update its stored title, which is what
the home screen's session chip and a session's own Info panel display in
place of the default \"New session\". Call this proactively, not only
when explicitly asked to rename something: as soon as the user's message
makes clear what this session is actually about, call set_session_title
with a short, descriptive title summarizing that -- don't wait to be
asked, and don't ask permission first. If the subject of the session
changes substantially later in the conversation, call it again with a
new title reflecting the new subject; a title should describe what the
session is currently about, not necessarily what it started as. SESSION_ID
(required) is the id of the session to rename -- your own session id is
given to you at the start of your system prompt; a call always names the
session explicitly rather than assuming \"this one\", so pass it even when
renaming yourself. TITLE (required) is the new title: a short,
human-readable label, not a full description -- it renders as one line in
the chip and the info panel. Whitespace at the ends is trimmed. An empty
title or one over 200 characters is rejected outright (nothing is changed)
rather than silently truncated or blanked. The session need not be the one
currently running this tool call, and it does not need an open
connection -- an idle session already on disk is reopened automatically.
This does not change the session's id, its transcript, or anything else
about it -- only the display title."
   :input-schema (%set-session-title-schema)
   ;; #123: mutates a session's stored title -- not read-only. Setting the
   ;; same title twice leaves the same end state, so idempotent; no external
   ;; network/service involved. (Added after #123's own table was written;
   ;; classified here the same way, not left silently unannotated.)
   :annotations '(:read-only-p nil :destructive-p nil :idempotent-p t :open-world-p nil)
   :handler '%set-session-title-tool-handler))

(defparameter +run-subagent-max-requests+ 8
  "Handler-side cap on REQUESTS per RUN_SUBAGENT call (#142) -- the safety
boundary every catalog tool needs, since every catalog tool executes with
no approval gate (see the file-level note above the tool-definition
handlers). Recursive fan-out is already impossible by construction (a
subagent's own catalog omits RUN_SUBAGENT entirely, see
DEFAULT-TOOL-CATALOG below), so this only needs to bound *width*, not
depth: how many subagent turns one call can launch in parallel.")

(defun %run-subagent-schema ()
  (let ((schema (%json-object "type" "object"))
        (props (%json-object))
        (requests-field (%json-object "type" "array"))
        (item-schema (%json-object "type" "object"))
        (item-props (%json-object)))
    (setf (gethash "prompt" item-props) (%json-object "type" "string")
          (gethash "backend" item-props) (%json-object "type" "string")
          (gethash "model" item-props) (%json-object "type" "string")
          (gethash "properties" item-schema) item-props
          (gethash "required" item-schema) (list "prompt")
          (gethash "items" requests-field) item-schema
          (gethash "requests" props) requests-field
          (gethash "properties" schema) props
          (gethash "required" schema) (list "requests"))
    schema))

(defun %subagent-title (prompt)
  "A short home-screen/info-panel label for a spawned subagent session --
derived from its own prompt (truncated, never the full text) since a
subagent has no human present to name it via SET_SESSION_TITLE."
  (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) prompt)))
    (format nil "Subagent: ~A"
            (if (> (length trimmed) 60)
                (concatenate 'string (subseq trimmed 0 60) "...")
                trimmed))))

(defun %parse-subagent-request (req)
  "Validate one element of RUN_SUBAGENT's REQUESTS array. Returns (VALUES
SPEC NIL) on success -- SPEC a plist (:PROMPT :BACKEND :MODEL) -- or
(VALUES NIL ERROR-MESSAGE) otherwise. Deliberately does not re-validate
BACKEND/MODEL against the catalog here: START-SESSION is already the
single source of truth for what is legal (#106), so an invalid choice is
caught once, at spawn time, inside %RUN-ONE-SUBAGENT, not duplicated here."
  (cond
    ((not (hash-table-p req))
     (values nil "each request must be a JSON object with at least a \"prompt\" field"))
    (t
     (let ((prompt (gethash "prompt" req))
           (backend (gethash "backend" req))
           (model (gethash "model" req)))
       (cond
         ((not (and (stringp prompt)
                    (plusp (length (string-trim '(#\Space #\Tab #\Newline #\Return) prompt)))))
          (values nil "\"prompt\" must be a non-empty string"))
         ((and backend (not (stringp backend)))
          (values nil "\"backend\" must be a string"))
         ((and model (not (stringp model)))
          (values nil "\"model\" must be a string"))
         (t (values (list :prompt prompt :backend backend :model model) nil)))))))

(defun %run-one-subagent (harness parent-id index spec)
  "Runs one REQUESTS entry to completion and never signals -- every
failure mode (invalid backend/model, a HARNESS-ERROR from START-SESSION,
a turn that never completes) is captured as data instead, so one bad
request in a parallel batch can never take the others down via
SB-THREAD:JOIN-THREAD propagating a condition. Returns a plist:
(:INDEX :SESSION-ID :OK :TEXT).

Waits for completion via ATTACH-SESSION-LISTENER, attached *before*
SUBMIT-TURN, not by polling SESSION-STATUS: a brand-new session's status
defaults to :READY (model.lisp) before its turn has even started, so a
poll begun right after SUBMIT-TURN cannot tell \"not started yet\" apart
from \"already finished\" -- both read :READY. A listener attached first
cannot miss the terminating event no matter how fast or slow the turn
runs."
  (handler-case
      (let* ((prompt (getf spec :prompt))
             (backend (getf spec :backend))
             (model (getf spec :model))
             (snapshot (start-session harness
                                      :title (%subagent-title prompt)
                                      :backend backend
                                      :model model
                                      :parent-session-id parent-id))
             (child-id (session-snapshot-id snapshot))
             (deadline-seconds
               (harness-config-turn-deadline-seconds (harness-config harness)))
             (done (sb-thread:make-semaphore :count 0))
             (state-lock (sb-thread:make-mutex :name "run-subagent-wait"))
             (last-assistant-text nil)
             (terminal-text nil)
             (turn-is-error nil))
        (multiple-value-bind (initial-snapshot listener-id cursor)
            (attach-session-listener
             harness child-id
             :callback
             (lambda (ev)
               (sb-thread:with-mutex (state-lock)
                 (case (event-type ev)
                   (:assistant-text
                    (setf last-assistant-text (getf (event-payload ev) :text)))
                   (:terminal
                    (setf terminal-text (getf (event-payload ev) :text))
                    (sb-thread:signal-semaphore done))
                   (:error
                    (setf turn-is-error t)
                    (sb-thread:signal-semaphore done))))))
          (declare (ignore initial-snapshot cursor))
          (unwind-protect
               (progn
                 (submit-turn harness child-id prompt)
                 (if (sb-thread:wait-on-semaphore
                      done
                      ;; Generous grace beyond the turn's own deadline
                      ;; watchdog, so that watchdog gets the first chance to
                      ;; resolve a stalled subagent rather than this giving
                      ;; up first and leaving it to keep running orphaned.
                      :timeout (+ deadline-seconds 30))
                     (sb-thread:with-mutex (state-lock)
                       (list :index index :session-id child-id
                             :ok (not turn-is-error)
                             ;; LAST-ASSISTANT-TEXT first: that is the
                             ;; subagent's actual conversational answer,
                             ;; which is what a caller of RUN_SUBAGENT wants
                             ;; back. TERMINAL-TEXT is a fallback for a
                             ;; tool-only turn that produced no assistant
                             ;; text at all (runtime.lisp's own comment: "a
                             ;; tool-only turn with no assistant text still
                             ;; gets its own [terminal] entry") -- in the
                             ;; ordinary case the two already carry the same
                             ;; text (and %HANDLE-MAPPED-EVENT even nils
                             ;; TERMINAL-TEXT out then to avoid double-
                             ;; rendering it), so this order only matters
                             ;; when they genuinely differ.
                             :text (or last-assistant-text
                                      (and terminal-text (plusp (length terminal-text))
                                           terminal-text)
                                      "")))
                     (list :index index :session-id child-id :ok nil
                           :text "subagent did not finish within the turn-deadline budget; it may still be running")))
            (detach-session-listener harness child-id listener-id))))
    (harness-error (c)
      (list :index index :session-id nil :ok nil
            :text (format nil "run_subagent request failed: ~A" (harness-error-message c))))
    (error (c)
      (list :index index :session-id nil :ok nil
            :text (format nil "run_subagent request failed: ~A" c)))))

(defun %format-subagent-results (results total-count)
  "Renders every request's outcome into one tool result, each entry's TEXT
truncated to a fair per-request share of +TOOL-RESULT-MAX-CHARS+ (the same
never-silently-drop discipline as READ_FILE/#126, applied per item here
rather than to one shared blob) -- a truncated entry says so explicitly
rather than just stopping."
  (let ((per-item-cap (max 256 (floor +tool-result-max-chars+ (max 1 total-count)))))
    (with-output-to-string (out)
      (dolist (r results)
        (let* ((text (or (getf r :text) ""))
               (truncated-p (> (length text) per-item-cap))
               (shown (if truncated-p (subseq text 0 per-item-cap) text)))
          (format out "[~D] session ~A: ~:[FAILED~;ok~]~%~A~%"
                  (getf r :index) (or (getf r :session-id) "(none)")
                  (getf r :ok) shown)
          (when truncated-p
            (format out "[truncated: this request's output exceeds its ~:D character share of this tool result's cap]~%"
                    per-item-cap))
          (terpri out))))))

(defun %run-subagent-tool-handler (arguments context)
  "CONTEXT's :CALLING-SESSION-ID (not *CURRENT-SESSION-RECORD*) is this
handler's only trustworthy source for \"which session is calling\":
%SDK-TOOL-FROM-DEFINITION (sdk-adapter.lisp) captures that id from
*CURRENT-SESSION-RECORD* once, synchronously, at catalog-construction time,
then passes it down as a genuine argument -- because every MCP tool call
actually runs on a freshly spawned thread (CLAUDE-AGENT-SDK-CL's
%CLIENT-SPAWN-TOOL-THREAD), never inside %ENSURE-CLIENT's dynamic extent,
so reading the special directly here always sees NIL no matter how
correctly it was bound upstream."
  (let ((calling-session-id (getf context :calling-session-id)))
    (cond
      ((null *tool-harness*)
       (values "run_subagent is unavailable: no harness is wired up for tool calls in this process" t))
      ((null calling-session-id)
       (values "run_subagent is unavailable: no calling-session context for this tool invocation" t))
      (t
       (let ((requests (gethash "requests" arguments)))
       (cond
         ((not (and (listp requests) requests))
          (values "run_subagent requires a non-empty \"requests\" array" t))
         ((> (length requests) +run-subagent-max-requests+)
          (values (format nil "run_subagent supports at most ~D requests per call, got ~D"
                          +run-subagent-max-requests+ (length requests))
                  t))
         (t
          (let ((parse-error nil) (specs '()) (i 0))
            (dolist (req requests)
              (multiple-value-bind (spec err) (%parse-subagent-request req)
                (if err
                    (setf parse-error (or parse-error (format nil "request ~D: ~A" i err)))
                    (push spec specs)))
              (incf i))
            (if parse-error
                (values parse-error t)
                (let* ((harness *tool-harness*)
                       (parent-id calling-session-id)
                       (specs (nreverse specs))
                       (threads
                         (loop for spec in specs
                               for idx from 0
                               ;; LET rebinds SPEC/IDX fresh per iteration:
                               ;; LOOP's own SPEC/IDX bindings are reused
                               ;; (mutated), not fresh, across iterations in
                               ;; SBCL, so a LAMBDA closing over them
                               ;; directly would see only the *last*
                               ;; request/index by the time its thread
                               ;; actually ran -- every spawned thread
                               ;; processing the same, final request.
                               collect (let ((spec spec) (idx idx))
                                        (sb-thread:make-thread
                                         (lambda () (%run-one-subagent harness parent-id idx spec))
                                         :name (format nil "sm-subagent-~A-~D" parent-id idx))))))
                  (let ((results (mapcar #'sb-thread:join-thread threads)))
                    (values (%format-subagent-results results (length specs))
                            (some (lambda (r) (not (getf r :ok))) results)))))))))))))

(defun make-run-subagent-tool-definition ()
  "Spawns one or more subordinate agent sessions (#142), runs each to a
full turn's completion in parallel, and reports every outcome back in one
result. REQUESTS is a non-empty array (at most +RUN-SUBAGENT-MAX-REQUESTS+
per call) of {prompt (required), backend, model} -- BACKEND/MODEL validated
the same way START-SESSION already validates them (#106), defaulting the
same way when omitted. Each spawned session's PARENT-SESSION-ID is this
calling session's own id, reaching the handler via CONTEXT's
:CALLING-SESSION-ID -- captured authoritatively from
*CURRENT-SESSION-RECORD* by %SDK-TOOL-FROM-DEFINITION at catalog-
construction time (sdk-adapter.lisp), never trusted from a model-supplied
argument -- see *CURRENT-SESSION-RECORD*'s docstring for why a tool
argument or a directly-read special both fail here. A subagent gets the
full default catalog *except* RUN_SUBAGENT itself (DEFAULT-TOOL-CATALOG
omits it whenever *CURRENT-SESSION-RECORD* already has a non-NIL
PARENT-SESSION-ID), so recursive spawning is impossible by construction,
not by a depth counter. Interrupting the *calling* session's own turn does
not interrupt an in-flight subagent turn -- it keeps running to completion
independently, per #142's resolved decision; a subagent that outlives its
caller's interrupted turn is not otherwise marked as orphaned."
  (make-tool-definition
   :name "run_subagent"
   :description "Run one or more subordinate agent sessions in parallel and
return their results. REQUESTS is a required, non-empty array of objects,
each with a required PROMPT (string) and optional BACKEND/MODEL strings
(same catalog and defaults as session creation) -- at most 8 requests per
call. Each subagent runs the full tool catalog except run_subagent itself
(no recursive spawning) and to completion independently of this call's own
turn (interrupting this turn does not stop an in-flight subagent). Returns
one combined result reporting, per request, its spawned session id, whether
it succeeded, and its final answer text."
   :input-schema (%run-subagent-schema)
   ;; #123: definitely not read-only (creates new sessions and runs real
   ;; model turns, which may themselves run bash/write_file), not
   ;; idempotent (each call spawns brand-new sessions/side effects even
   ;; with identical arguments), open-world (drives an external CLI/model).
   :annotations '(:read-only-p nil :destructive-p t :idempotent-p nil :open-world-p t)
   :handler '%run-subagent-tool-handler))

(defun default-tool-catalog ()
  "Return product-owned tool metadata, not SDK objects. RUN_SUBAGENT (#142)
is included unless *CURRENT-SESSION-RECORD* shows this session is itself a
subagent (a non-NIL PARENT-SESSION-ID) -- the enforcement mechanism for
'a subagent cannot itself call run_subagent', not a separate depth
counter. A session with no bound *CURRENT-SESSION-RECORD* at all (headless
sm-harness with nothing wired up, most of this file's own test suite) is
treated as NOT a subagent, so RUN_SUBAGENT still appears -- consistent with
every other *TOOL-HARNESS*-gated tool here, which reports a safe result
error rather than being hidden when nothing is wired up."
  (make-tool-catalog
   :servers
   (list (make-tool-server-definition
          :name "sm_harness"
          :version "0.1.0"
          :tools (append (list (make-echo-tool-definition)
                               (make-read-tool-definition)
                               (make-write-tool-definition)
                               (make-bash-tool-definition)
                               (make-reload-tool-definition)
                               (make-web-search-tool-definition)
                               (make-set-session-title-tool-definition))
                         (unless (and *current-session-record*
                                      (session-record-parent-session-id
                                       *current-session-record*))
                           (list (make-run-subagent-tool-definition))))))))

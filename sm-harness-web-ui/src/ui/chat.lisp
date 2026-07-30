(in-package #:sm-harness-web-ui)

(defun clear-body (body)
  (setf (clog:inner-html body) ""))

(defun render-chat (body session-id)
  (clear-body body)
  (setf (clog:title (clog:html-document body)) "Chat — sm-harness")
  ;; Browser log capture (#92): tag this tab's captured entries with the
  ;; session id being opened, and record the navigation itself so exported
  ;; logs can be matched against which session was active when.
  (%log-set-session body session-id)
  (%log-nav body (format nil "chat ~A" session-id))
  (let* ((snap (ui-open-session session-id))
         (root (clog:create-div body :class "page chat" :html-id "chat-root"))
         (header (clog:create-div root :class "header"))
         (back (clog:create-button header :content "Back to home"
                                   :class "btn" :html-id "back-home"))
         (title-el (clog:create-div header :class "chat-title"
                                    :content (sm-harness:session-snapshot-title snap)))
         (status-el (clog:create-div header :class "status-chip" :html-id "status-chip"
                                     :content (status-label (sm-harness:session-snapshot-status snap))))
         ;; The harness session id doubles as the transcript file name under
         ;; <data>/<project>/sessions/, so it is the id to hand an agent (or a
         ;; human) for debugging. One click copies it to the system clipboard.
         (id-el (clog:create-button header :content session-id
                                    :class "session-id" :html-id "session-id"))
         (canon-el (clog:create-div header :class "canonical-id" :html-id "canonical-id"
                                    :content (or (sm-harness:session-snapshot-canonical-id snap)
                                                 "Pending…")))
         ;; Positioned here (#92) so the panel opens directly under the
         ;; header row that holds the button, above the transcript,
         ;; instead of appearing after everything at the bottom of the
         ;; page.
         (log-panel (install-log-export-panel body header root))
         (transcript (clog:create-div root :class "transcript" :html-id "transcript"))
         (composer-wrap (clog:create-div root :class "composer"))
         (input (clog:create-text-area composer-wrap :class "prompt" :html-id "prompt"))
         (send-btn (clog:create-button composer-wrap :content "Send"
                                       :class "btn primary" :html-id "send"))
         (stop-btn (clog:create-button composer-wrap :content "Stop"
                                       :class "btn danger" :html-id "stop"))
         (err (clog:create-div root :class "error" :html-id "chat-error"))
         (listener-id nil)
         (busy nil)
         (pending-prompt nil)
         ;; #69: the composer echoes a submitted prompt into the transcript
         ;; immediately (see SUBMIT-PROMPT below) rather than waiting on the
         ;; harness's own :USER-MESSAGE event to round-trip back over the
         ;; listener. This flag remembers that an optimistic echo is
         ;; outstanding so the *real* event, once it does arrive, updates
         ;; state without rendering that same line a second time.
         (awaiting-user-echo nil))
    (declare (ignore title-el log-panel))
    (setf (clog:attribute id-el "title") "Copy session id"
          (clog:attribute id-el "aria-label")
          (format nil "Copy session id ~A to clipboard" session-id))
    (setf (clog:attribute root "role") "main"
          (clog:attribute status-el "role") "status"
          (clog:attribute status-el "aria-live") "polite"
          (clog:attribute transcript "role") "log"
          (clog:attribute transcript "aria-label") "Conversation transcript"
          (clog:attribute transcript "aria-live") "polite"
          (clog:attribute err "role") "alert"
          (clog:attribute err "aria-live") "assertive"
          (clog:attribute input "aria-label") "Message")
    (labels ((scroll-transcript-to-bottom ()
               ;; New messages (#74) should keep the transcript pinned to its
               ;; latest content instead of leaving a reader scrolled up on a
               ;; stale line once the box overflows (max-height, app.css).
               (setf (clog:scroll-top transcript) (clog:scroll-height transcript)))
             (add-line (role text)
               ;; TEXT always arrives pre-rendered, safe HTML: assistant
               ;; lines via MARKDOWN-TO-HTML (#71, a restricted Markdown
               ;; subset over already-escaped input), every other role via
               ;; plain ESCAPE-TEXT. Both share this one inner-html path,
               ;; so no live tag can come from anywhere but those two
               ;; functions.
               (let ((line (clog:create-div transcript
                                            :class (format nil "msg msg-~A" role))))
                 (setf (clog:inner-html line) text)
                 (scroll-transcript-to-bottom)
                 line))
             (set-busy (v)
               (setf busy v)
               (setf (clog:disabledp send-btn) v)
               (setf (clog:disabledp stop-btn) (not v)))
             (submit-prompt (prompt)
               ;; Shared by the Send button and Enter-to-send (#97 logs both
               ;; the same way; #69 renders both the same way too): echo the
               ;; prompt into the transcript the moment submission succeeds,
               ;; instead of leaving the composer looking unresponsive until
               ;; the harness's own event round-trips back.
               (%log-send body prompt)
               (handler-case
                   (progn
                     (setf pending-prompt prompt)
                     ;; #69 follow-up: this flag MUST flip before calling
                     ;; UI-SUBMIT, not after. CLOG runs every incoming
                     ;; browser event in its own fresh thread, and once a
                     ;; session's SDK client is already connected (i.e. any
                     ;; turn past the first), the harness's dispatcher
                     ;; thread can publish this turn's :USER-MESSAGE event
                     ;; and have the *listener's own dispatcher thread*
                     ;; deliver it to ON-EVENT below fast enough to win a
                     ;; race against this thread's own ADD-LINE call, which
                     ;; needs a real round trip to the browser. Flipping the
                     ;; flag here, strictly before the call that can
                     ;; trigger that delivery, closes the race: program
                     ;; order on this one thread guarantees it is already
                     ;; true by the time any other thread could observe the
                     ;; enqueued turn (UI-SUBMIT's enqueue and the
                     ;; listener's own delivery queue are each mutex-guarded,
                     ;; so the happens-before edge carries all the way
                     ;; through). Setting it only after ADD-LINE (as a
                     ;; first cut of this fix did) left that race open and
                     ;; showed up as a duplicated user line in real usage.
                     (setf awaiting-user-echo t)
                     (ui-submit session-id prompt)
                     (add-line "user" (escape-text prompt))
                     (setf (clog:text-value input) "")
                     (setf (clog:text err) "")
                     (set-busy t))
                 (error (c)
                   ;; UI-SUBMIT never accepted this prompt (no turn was
                   ;; enqueued), so no :USER-MESSAGE event is coming for it;
                   ;; leaving the flag set would wrongly swallow the next,
                   ;; genuinely submitted turn's echo.
                   (setf awaiting-user-echo nil)
                   (setf (clog:text err) (format nil "~A" c)))))
             (on-event (ev)
               (let* ((d (event-display ev))
                      (role (car d))
                      (text (cdr d)))
                 (cond
                   ((eq (sm-harness:event-type ev) :status)
                    (setf (clog:text status-el) text))
                   ((and (eq (sm-harness:event-type ev) :user-message)
                         (string= role "user")
                         awaiting-user-echo)
                    ;; #69: this is the harness's own confirmation of the
                    ;; prompt already echoed optimistically on submit; drop
                    ;; it rather than rendering the same text twice. A
                    ;; harness-initiated synthetic follow-up (#76) has role
                    ;; "harness" instead, so it never matches here and still
                    ;; renders normally.
                    (setf awaiting-user-echo nil))
                   ((eq (sm-harness:event-type ev) :terminal)
                    ;; A blank terminal text means the harness already showed
                    ;; this exact response via the assistant stream; only a
                    ;; genuinely distinct outcome (error, interrupt, tool-only
                    ;; turn) gets its own line here.
                    (when (and text (plusp (length text)))
                      (add-line role text))
                    (let ((cid (getf (sm-harness:event-payload ev) :session-id)))
                      (when cid (setf (clog:text canon-el) cid)))
                    (setf pending-prompt nil)
                    (set-busy nil)
                    (clog:focus input))
                   ((eq (sm-harness:event-type ev) :error)
                    (setf (clog:text err) text)
                    (when pending-prompt
                      (setf (clog:text-value input) pending-prompt))
                    (setf pending-prompt nil)
                    ;; A turn that errors before its :user-message event
                    ;; round-trips must not leave this flag set, or the next
                    ;; turn's genuine event would be wrongly swallowed.
                    (setf awaiting-user-echo nil)
                    (set-busy nil))
                   (t (add-line role text))))))
      ;; Composer handlers are bound BEFORE the transcript replay below.
      ;; CLOG applies its messages in order over one websocket, so anything
      ;; that waits for replayed content (a reopening tab, an E2E runner)
      ;; is then guaranteed the composer is live; bound after the replay, a
      ;; long transcript leaves a visible-but-deaf composer whose first
      ;; Enter/click is silently dropped.
      (set-busy nil)
      (clog:set-on-click id-el
        (lambda (obj)
          (declare (ignore obj))
          ;; navigator.clipboard exists only in secure contexts (https or
          ;; localhost); this UI is typically served over plain http, so a
          ;; hidden-textarea execCommand fallback does the real work there.
          (clog:js-execute body (format nil "(function () {~
  var id = '~A';~
  var el = document.getElementById('session-id');~
  function done() {~
    el.textContent = 'Copied!';~
    window.setTimeout(function () { el.textContent = id; }, 1200);~
  }~
  function fallback() {~
    var ta = document.createElement('textarea');~
    ta.value = id;~
    ta.style.position = 'fixed';~
    ta.style.opacity = '0';~
    document.body.appendChild(ta);~
    ta.focus();~
    ta.select();~
    try { document.execCommand('copy'); } catch (e) {}~
    document.body.removeChild(ta);~
    done();~
  }~
  if (navigator.clipboard && window.isSecureContext) {~
    navigator.clipboard.writeText(id).then(done, fallback);~
  } else {~
    fallback();~
  }~
})()" session-id))))
      (clog:set-on-click back
        (lambda (obj)
          (declare (ignore obj))
          (when listener-id (ui-detach session-id listener-id))
          (clear-body body)
          (render-home body)
          (clog:js-execute body
                           "window.setTimeout(function () { document.getElementById('new-session').focus(); }, 0)")))
      (clog:set-on-click send-btn
        (lambda (obj)
          (declare (ignore obj))
          (unless busy
            (submit-prompt (clog:text-value input)))))
      (clog:set-on-click stop-btn
        (lambda (obj)
          (declare (ignore obj))
          (ui-interrupt session-id)
          (setf (clog:text status-el) "Stopping")))
      (clog:set-on-key-down input
        (lambda (obj data)
          (declare (ignore obj))
          (when (and (equal (getf data :key) "Enter")
                     (not (getf data :shift-key))
                     (not busy))
            (submit-prompt (clog:text-value input)))))
      (dolist (entry (sm-harness:session-snapshot-transcript snap))
        (let* ((kind (sm-harness:transcript-entry-kind entry))
               (role (cond
                       ((string= "tool" kind) "tool")
                       ;; A harness-initiated synthetic follow-up (#76) renders
                       ;; distinctly on reload/reopen too, matching the live path.
                       ((string= "synthetic" kind) "harness")
                       (t (sm-harness:transcript-entry-role entry))))
               (raw (sm-harness:transcript-entry-text entry)))
          (add-line role
                    (if (string= role "assistant")
                        (markdown-to-html raw)
                        (escape-text raw)))))
      (multiple-value-bind (snapshot lid cursor)
          (ui-attach session-id
                     (lambda (ev)
                       ;; Self-pruning: once this page's CLOG connection is
                       ;; gone (tab closed, laptop slept), every further
                       ;; delivery would only burn dead-connection timeouts
                       ;; on the listener's dispatcher thread, so detach on
                       ;; first sight. Deliveries run on that dispatcher, not
                       ;; the session worker, so a slow check costs no turn.
                       (if (clog:validp body)
                           (ignore-errors (on-event ev))
                           (when listener-id
                             (ignore-errors (ui-detach session-id listener-id))))))
        (declare (ignore snapshot cursor))
        (setf listener-id lid))
      (clog:js-execute body
                       "window.setTimeout(function () { document.getElementById('prompt').focus(); }, 0)"))))

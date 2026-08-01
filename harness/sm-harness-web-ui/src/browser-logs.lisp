(in-package #:sm-harness-web-ui)

;;;; Browser log capture (#92) — Lisp-side glue around the client-side
;;;; ring buffer in static/log-capture.js. Loaded before src/ui/*, which
;;;; call these to tag/record entries and to read the export back out.

(defun %js-string-literal (value)
  "A JSON string encoding of VALUE, valid as a JS string literal too."
  (with-output-to-string (s) (yason:encode value s)))

(defun %log-nav (body label)
  "Record a navigation entry in this tab's captured browser log, so
exported logs can be matched against navigation between home/chat and
between sessions, not just console/error output."
  (ignore-errors
   (clog:js-execute body
    (format nil "window.__smLog && window.__smLog('info', ~A);"
            (%js-string-literal (format nil "nav: ~A" label))))))

(defun %log-set-session (body session-id)
  "Tag subsequent captured browser log entries with SESSION-ID (or clear
the tag when SESSION-ID is NIL) until the tab navigates elsewhere."
  (ignore-errors
   (clog:js-execute body
    (format nil "window.__smSetSession && window.__smSetSession(~A);"
            (%js-string-literal session-id)))))

(defun %log-send (body prompt)
  "Record a submitted prompt in this tab's captured browser log (#97): the
generic click capture in static/log-capture.js only ever sees a bare
\"click: #send\", with no way to reach into the composer's value, which
is exactly the content most useful for diagnosis (\"did the turn that
looked stuck even send what the user thinks it sent\"). Called from the
Send button and Enter-to-send handlers in render-chat with the exact text
just handed to UI-SUBMIT. No redaction: that is handled elsewhere, same
as every other captured entry."
  (ignore-errors
   (clog:js-execute body
    (format nil "window.__smLog && window.__smLog('info', ~A);"
            (%js-string-literal (format nil "send: ~A" prompt))))))

(defun export-browser-logs (body)
  "Return this tab's captured browser log text, newest entries last."
  (or (ignore-errors (clog:js-query body "window.__smExportLogs && window.__smExportLogs()"))
      ""))

;;;; Connection-lost fallback (#100, fix A) ------------------------------
;;;
;;; CLOG click/form handlers all round-trip through this tab's websocket
;;; (literally `ws.send(...)`, generated client-side JS). If that
;;; connection ever reaches its terminal "Shutdown_ws already ran" state --
;;; e.g. a stale reconnect id rejected after a container/process restart,
;;; see docs/sm-harness-web-ui.md -- every button on the page silently
;;; throws `Cannot read properties of null (reading 'send')` in devtools,
;;; with the DOM otherwise looking fully alive. static/log-capture.js's own
;;; self-heal (fix B) already reloads the tab automatically in the common
;;; case, before a user is likely to see this at all; this is the backstop
;;; for whatever path reaches Shutdown_ws that B's poll has not yet caught
;;; (a backgrounded/throttled tab, for instance).
;;;
;;; CLOG:SET-HTML-ON-CLOSE sets the client-side clog['html_on_close'],
;;; which boot.js's own Shutdown_ws swaps document.body's innerHTML to
;;; (via jQuery .html(), not document.write, so this fires even long after
;;; initial page load). Its own ESCAPE-STRING is a "safe as a JS string
;;; literal" escaper (its docstring is explicit that it is not an
;;; XSS/HTML escaper) -- fine here since this is a static, developer-
;;; authored string, not user input.

(defparameter *connection-lost-html*
  "<div id=\"sm-connection-lost\" role=\"alert\" style=\"padding:2rem;font-family:sans-serif;\">
<p id=\"sm-connection-lost-message\">Connection lost. Reload to continue.</p>
<button id=\"sm-connection-lost-reload\" onclick=\"location.reload()\">Reload</button>
</div>"
  "Fallback body HTML installed once per connection via
%INSTALL-CONNECTION-LOST-FALLBACK. Carries stable ids so both a human and
e2e/scenarios/connection-lost-fallback.lisp can find it.")

(defun %install-connection-lost-fallback (body)
  (ignore-errors (clog:set-html-on-close body *connection-lost-html*)))

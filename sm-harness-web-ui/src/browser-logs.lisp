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

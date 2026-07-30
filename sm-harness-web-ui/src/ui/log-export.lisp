(in-package #:sm-harness-web-ui)

(defun install-log-export-panel (body header root)
  "Adds an 'Export logs' control (#92) to HEADER, opening a copyable panel
of this tab's captured browser log (console output, uncaught errors, and
navigation entries — see static/log-capture.js) appended to ROOT.
Shared by the home and chat screens so pre-session errors are exportable
too, not just in-session ones."
  (let* ((btn (clog:create-button header :content "Export logs"
                                  :class "btn" :html-id "export-logs"))
         (panel (clog:create-div root :class "logs-panel" :html-id "logs-panel"))
         (textarea (clog:create-text-area panel :class "logs-textarea"
                                          :html-id "logs-textarea"))
         (panel-actions (clog:create-div panel :class "logs-panel-actions"))
         (copy-btn (clog:create-button panel-actions :content "Copy"
                                       :class "btn" :html-id "logs-copy"))
         (close-btn (clog:create-button panel-actions :content "Close"
                                        :class "btn" :html-id "logs-close")))
    (setf (clog:hiddenp panel) t
          (clog:attribute textarea "readonly") "readonly"
          (clog:attribute textarea "aria-label") "Captured browser log"
          (clog:attribute btn "aria-label") "Export browser logs"
          (clog:attribute panel "role") "dialog"
          (clog:attribute panel "aria-label") "Exported browser logs")
    (clog:set-on-click btn
      (lambda (obj)
        (declare (ignore obj))
        (setf (clog:text-value textarea) (export-browser-logs body))
        (setf (clog:hiddenp panel) nil)))
    (clog:set-on-click close-btn
      (lambda (obj)
        (declare (ignore obj))
        (setf (clog:hiddenp panel) t)))
    (clog:set-on-click copy-btn
      (lambda (obj)
        (declare (ignore obj))
        ;; Same secure-context/execCommand-fallback idiom as the
        ;; session-id chip (chat.lisp): this UI is typically served over
        ;; plain http, where the async clipboard API does not exist.
        (clog:js-execute body
          "(function () {
  var ta = document.getElementById('logs-textarea');
  var btn = document.getElementById('logs-copy');
  function done() {
    var prev = btn.textContent;
    btn.textContent = 'Copied!';
    window.setTimeout(function () { btn.textContent = prev; }, 1200);
  }
  function fallback() {
    ta.focus();
    ta.select();
    try { document.execCommand('copy'); } catch (e) {}
    done();
  }
  if (navigator.clipboard && window.isSecureContext) {
    navigator.clipboard.writeText(ta.value).then(done, fallback);
  } else {
    fallback();
  }
})()")))
    (values btn panel textarea)))

// Tab-scoped browser log capture (#92).
//
// Loaded once per browser tab (see on-new-window, src/application.lisp).
// Home<->chat transitions in this app are in-place DOM rebuilds within the
// same JS realm (CLOG swaps innerHTML rather than navigating), so a single
// load here covers the whole tab lifetime, not just one screen.
//
// Captures console.log/info/warn/debug/error (still forwarding to the
// original console methods), uncaught errors, and unhandled promise
// rejections into a capped ring buffer. Lisp-side code can also append
// entries (e.g. navigation) via window.__smLog, and tag entries with the
// active harness session id via window.__smSetSession. No redaction is
// applied: this exports exactly what the browser logged in this tab.
(function () {
  if (window.__smLogCaptureInstalled) { return; }
  window.__smLogCaptureInstalled = true;

  var MAX_ENTRIES = 2000;
  var buffer = [];
  var currentSession = null;

  function isoNow() {
    return new Date().toISOString();
  }

  function stringifyArg(a) {
    if (typeof a === 'string') { return a; }
    try { return JSON.stringify(a); } catch (e) { return String(a); }
  }

  function stringifyArgs(args) {
    try {
      return Array.prototype.map.call(args, stringifyArg).join(' ');
    } catch (e) {
      return '[unserializable log arguments]';
    }
  }

  function push(level, message) {
    var line = isoNow() + ' [' + String(level).toUpperCase() + '] ' +
      '[session:' + (currentSession || 'none') + '] ' + message;
    buffer.push(line);
    if (buffer.length > MAX_ENTRIES) {
      buffer.shift();
    }
  }

  ['log', 'info', 'warn', 'debug', 'error'].forEach(function (level) {
    var original = (typeof console[level] === 'function')
      ? console[level].bind(console)
      : function () {};
    console[level] = function () {
      try {
        push(level === 'log' ? 'info' : level, stringifyArgs(arguments));
      } catch (e) {
        // Never let capture itself break the app.
      }
      return original.apply(console, arguments);
    };
  });

  window.addEventListener('error', function (event) {
    var where = event && event.filename
      ? (' @ ' + event.filename + ':' + event.lineno + ':' + event.colno)
      : '';
    push('error', 'window.onerror: ' + (event && event.message ? event.message : 'unknown error') + where);
  });

  window.addEventListener('unhandledrejection', function (event) {
    var reason = event && event.reason;
    var text = (reason && reason.message) ? reason.message : stringifyArg(reason);
    push('error', 'unhandledrejection: ' + text);
  });

  // Public hooks used by the Lisp side (src/ui/*.lisp).
  window.__smLog = function (level, message) { push(level || 'info', String(message)); };
  window.__smSetSession = function (id) { currentSession = id || null; };
  window.__smExportLogs = function () {
    return buffer.length ? buffer.join('\n') : '(no browser log entries captured yet)';
  };
})();

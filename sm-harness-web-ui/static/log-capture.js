// Tab-scoped browser log capture (#92, made more robust in #97).
//
// Loaded once per browser tab (see on-new-window, src/application.lisp).
// Home<->chat transitions in this app are in-place DOM rebuilds within the
// same JS realm (CLOG swaps innerHTML rather than navigating), so a single
// load here covers the whole tab lifetime, not just one screen.
//
// Captures: console.log/info/warn/debug/error (still forwarding to the
// original console methods -- this also includes CLOG's own /js/boot.js
// reconnect/error status, logged purely via console.log/error, for any
// reconnect that happens after this script has loaded; the very first
// "connecting"/"connection successful" pair happens slightly earlier,
// before on-new-window gets a chance to load this script, and so is not
// caught here), uncaught errors, unhandled promise rejections, every click
// on an interactive control, window focus/blur and tab visibility changes,
// and a "page load" marker recorded as the very first entry. Lisp-side
// code can also append entries (e.g. navigation) via window.__smLog, and
// tag entries with the active harness session id via
// window.__smSetSession. No redaction is applied: this exports exactly
// what the browser logged in this tab.
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

  // A short, stable-ish description of a clicked element: prefer its id
  // (matches the html-id CLOG assigns most interactive controls), then an
  // aria-label, then trimmed visible text, else just the tag name. Never
  // throws -- click capture must not be able to break the app.
  function describeTarget(el) {
    if (!el) { return 'unknown'; }
    if (el.id) { return '#' + el.id; }
    var label = el.getAttribute && el.getAttribute('aria-label');
    if (label) { return el.tagName.toLowerCase() + '[aria-label="' + label + '"]'; }
    var text = (el.textContent || '').trim().replace(/\s+/g, ' ');
    if (text) { return el.tagName.toLowerCase() + ' "' + text.slice(0, 40) + '"'; }
    return el.tagName.toLowerCase();
  }

  // Recorded before anything else so an exported log always shows when
  // this tab's JS realm started and on what screen (#97), even if
  // everything after this line somehow failed to install.
  push('info', 'page load: ' + window.location.pathname + window.location.search);

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

  // Every click on an interactive control (#97) -- a capturing-phase
  // document listener, not per-button instrumentation, so newly added
  // buttons are covered automatically instead of silently falling outside
  // capture until someone remembers to wire them up.
  document.addEventListener('click', function (event) {
    try {
      var el = event.target && event.target.closest
        ? event.target.closest('button, a, [role="button"], input[type="submit"], input[type="button"]')
        : null;
      if (el) {
        push('info', 'click: ' + describeTarget(el));
      }
    } catch (e) {
      // Never let capture itself break the app.
    }
  }, true);

  // Tab/window focus changes (#97): laptop sleep/lock, switching tabs, and
  // OS-level focus loss are common context for "why did this look stuck"
  // reports, and otherwise leave no trace in the captured log at all.
  window.addEventListener('focus', function () { push('info', 'window focus'); });
  window.addEventListener('blur', function () { push('info', 'window blur'); });
  document.addEventListener('visibilitychange', function () {
    push('info', 'visibility: ' + document.visibilityState);
  });

  // Self-heal (#100, fix B): boot.js's own reconnect logic can permanently
  // null out its global `ws` if a stale reconnect id (e.g. this
  // container/process restarted while this tab was still open) gets
  // rejected by the new process with a close code (1000, "normal
  // closure") the client treats as a deliberate, non-recoverable
  // shutdown -- see docs/sm-harness-web-ui.md for the full trace. `ws` is
  // a plain top-level `var` in boot.js (no module/IIFE wrapper), so it
  // really is `window.ws` here. Every CLOG click/form handler closes over
  // that same global by reference for the page's entire life, so once
  // this happens every button on the page throws
  // "Cannot read properties of null (reading 'send')" forever, with the
  // DOM otherwise looking fully alive -- reloading is the only recovery
  // (docs/sm-harness-web-ui.md, "Dead browser tabs and listener
  // delivery": CLOG never revives a connection id it no longer knows).
  //
  // The poll/reload-delay interval is overridable via a `smSelfHealPollMs`
  // query parameter purely for deterministic browser E2E coverage (#100,
  // e2e/scenarios/connection-lost-fallback.lisp sets it very high to
  // isolate fix A, the CLOG:SET-HTML-ON-CLOSE fallback, from this
  // self-heal racing it); production never sets this.
  var smSelfHealPollMs = (function () {
    var params = new URLSearchParams(window.location.search);
    var override = parseInt(params.get('smSelfHealPollMs'), 10);
    return (isFinite(override) && override > 0) ? override : 2000;
  })();
  var smSawLiveConnection = false;
  var smReloadScheduled = false;
  setInterval(function () {
    if (typeof window.ws === 'undefined') { return; }
    if (window.ws !== null) { smSawLiveConnection = true; return; }
    // The guard above is load-bearing, not decorative: `ws` also starts
    // out `null` before the *first* successful connect (e.g. during a
    // slow initial handshake), and without it this poll would misfire a
    // reload loop before the app ever got a chance to connect at all.
    if (smSawLiveConnection && !smReloadScheduled) {
      smReloadScheduled = true;
      push('error', 'connection lost (ws went null after a live connection) -- reloading');
      window.setTimeout(function () { window.location.reload(); }, smSelfHealPollMs);
    }
  }, smSelfHealPollMs);

  // Public hooks used by the Lisp side (src/ui/*.lisp).
  window.__smLog = function (level, message) { push(level || 'info', String(message)); };
  window.__smSetSession = function (id) { currentSession = id || null; };
  window.__smExportLogs = function () {
    return buffer.length ? buffer.join('\n') : '(no browser log entries captured yet)';
  };
})();

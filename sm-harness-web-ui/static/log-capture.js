// Tab-scoped browser log capture (#92, made more robust in #97, persisted
// to durable storage and shared across tabs in #120).
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
// on an interactive control, window focus/blur, tab visibility changes,
// and page hide/show (bfcache/mobile backgrounding, #120), and a
// "page load" marker recorded as the very first entry. Lisp-side code can
// also append entries (e.g. navigation) via window.__smLog, and tag
// entries with the active harness session id via window.__smSetSession.
// No redaction is applied: this exports exactly what the browser logged.
//
// Storage (#120): entries are written to window.localStorage, not just an
// in-memory array, under STORAGE_KEY below. localStorage is per-origin,
// not per-tab, so every tab open on this app reads and appends to the
// *same* underlying log -- a reload no longer loses history, and a report
// exported from one tab can include what happened in another tab of the
// same session. Each push() does a read-modify-write of the whole stored
// array; log volume here is low (user actions, not a hot loop), so the
// lack of any cross-tab locking is an acceptable, occasionally-interleaved
// tradeoff, not a correctness requirement. If localStorage is unavailable
// or disabled (private browsing quirks, a sandboxed iframe throwing on
// access, etc.) capture still works, just falls back to an in-memory
// array scoped to this tab only, same as before #120.
(function () {
  if (window.__smLogCaptureInstalled) { return; }
  window.__smLogCaptureInstalled = true;

  var STORAGE_KEY = 'smBrowserLog';
  var MAX_STORED_ENTRIES = 2000;
  var EXPORT_LIMIT = 500;
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

  // Probed once at load: some browsers/contexts (older Safari private
  // browsing, a sandboxed iframe without storage access, etc.) throw on
  // any localStorage access at all, not just when full. Capture must
  // never let that take the whole tab down with it.
  var storageAvailable = (function () {
    try {
      var probeKey = '__smLogCaptureProbe__';
      window.localStorage.setItem(probeKey, '1');
      window.localStorage.removeItem(probeKey);
      return true;
    } catch (e) {
      return false;
    }
  })();
  var memoryFallback = [];

  function readStored() {
    if (!storageAvailable) { return memoryFallback.slice(); }
    try {
      var raw = window.localStorage.getItem(STORAGE_KEY);
      if (!raw) { return []; }
      var parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed : [];
    } catch (e) {
      // Corrupt/foreign value under this key -- start clean rather than
      // ever throwing out of capture.
      return [];
    }
  }

  function writeStored(lines) {
    if (!storageAvailable) {
      memoryFallback = lines;
      return;
    }
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(lines));
    } catch (e) {
      // Most likely quota exceeded (e.g. another tab/site sharing the
      // origin's storage budget). Drop older entries hard and retry once
      // rather than silently losing this entry, and every entry after it,
      // forever.
      try {
        var trimmed = lines.slice(Math.max(0, lines.length - Math.floor(MAX_STORED_ENTRIES / 4)));
        window.localStorage.setItem(STORAGE_KEY, JSON.stringify(trimmed));
      } catch (e2) {
        // Give up quietly -- log capture must never throw into app code.
      }
    }
  }

  function push(level, message) {
    var line = isoNow() + ' [' + String(level).toUpperCase() + '] ' +
      '[session:' + (currentSession || 'none') + '] ' + message;
    try {
      var lines = readStored();
      lines.push(line);
      if (lines.length > MAX_STORED_ENTRIES) {
        lines = lines.slice(lines.length - MAX_STORED_ENTRIES);
      }
      writeStored(lines);
    } catch (e) {
      // Never let capture itself break the app.
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
  // capture until someone remembers to wire them up. This is entirely
  // local (push() only ever touches localStorage/memory, never the
  // network), so clicks are captured even while the websocket connection
  // this tab's buttons round-trip through is closed (#120) -- there is
  // nothing here that depends on it being open.
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

  // Mobile backgrounding (#120): visibilitychange above already fires when
  // a tab is backgrounded on most modern mobile browsers, but it is not
  // the event the Page Lifecycle API (web.dev) recommends relying on for
  // "this page may be about to be frozen or discarded" -- that is
  // `pagehide`, paired with `pageshow` on return. Unlike `unload`/
  // `beforeunload` (unreliable on mobile: a backgrounded tab is often
  // frozen or its process killed outright without ever firing them),
  // `pagehide` is the one event mobile browsers are expected to fire
  // before suspending a page, which is exactly why it is also the right
  // place to make sure a pending write of the buffered log has already
  // happened rather than racing an eviction -- push() here always writes
  // synchronously, so there is nothing to flush, but the entry itself
  // gives an exported log a clear "the tab was about to be
  // backgrounded/evicted here" marker that focus/blur/visibilitychange
  // alone do not: those can lag or be skipped entirely on some mobile
  // WebViews when the OS suspends a tab abruptly. `event.persisted`
  // distinguishes an actual teardown from a bfcache freeze likely to
  // resume via `pageshow` with the same flag.
  window.addEventListener('pagehide', function (event) {
    push('info', 'pagehide' + (event && event.persisted ? ' (bfcache)' : ''));
  });
  window.addEventListener('pageshow', function (event) {
    push('info', 'pageshow' + (event && event.persisted ? ' (from bfcache)' : ''));
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
    var lines = readStored();
    if (!lines.length) { return '(no browser log entries captured yet)'; }
    // Only the most recent EXPORT_LIMIT entries (#120) -- the stored
    // buffer, shared across every tab on this origin, can hold up to
    // MAX_STORED_ENTRIES, more than is useful (or comfortable to paste
    // into a bug report) at export time.
    var latest = lines.length > EXPORT_LIMIT ? lines.slice(lines.length - EXPORT_LIMIT) : lines;
    return latest.join('\n');
  };
})();

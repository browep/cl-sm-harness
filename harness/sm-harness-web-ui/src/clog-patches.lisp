(in-package #:sm-harness-web-ui)

;;;; #121: CLOG's connection-id generator dies permanently after ~128
;;;; connections. `clog-connection::random-hex-string` draws from cl-isaac's
;;;; shared `clog-connection::*isaac-ctx*`, and cl-isaac's RAND64 decrements
;;;; its (unsigned-byte 64) RANDCNT slot *before* the block-exhaustion check
;;;; -- when the 256-draw block runs out, the decf stores -1 into the typed
;;;; slot, signals under default safety, and leaves RANDCNT at 0 so every
;;;; later draw fails the same way. Each connection id draws twice, so one
;;;; long-lived image wedges on roughly its 128th connection and can never
;;;; accept another. (The isaac context is also mutated with no lock, so
;;;; even a fixed RAND64 would race under concurrent connections.)
;;;;
;;;; Replace it with the ironclad OS-PRNG implementation CLOG already uses
;;;; on Windows, serialized through a mutex because ironclad's default
;;;; *PRNG* holds one shared /dev/urandom stream. Installed via FDEFINITION
;;;; from this system's own load so every RELOAD_HARNESS re-applies it,
;;;; including after a reload that re-evaluated CLOG itself (#105).

(defvar *random-hex-lock* (sb-thread:make-mutex :name "clog random-hex #121"))

(defun crypto-random-hex-string ()
  "32 lowercase hex chars from the OS PRNG -- same shape as the isaac
version's (format nil \"~(~32,'0x~)\" ...), so reconnect ids and the
boot.js handshake are unaffected."
  (sb-thread:with-mutex (*random-hex-lock*)
    (ironclad:byte-array-to-hex-string (ironclad:random-data 16))))

(setf (fdefinition 'clog-connection::random-hex-string)
      #'crypto-random-hex-string)

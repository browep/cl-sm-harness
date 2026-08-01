(in-package #:sm-harness-web-ui/tests)
(def-suite :sm-harness-web-ui/clog-patch-tests)
(in-suite :sm-harness-web-ui/clog-patch-tests)

;;;; #121 -- these run against the patched CLOG-CONNECTION::RANDOM-HEX-STRING
;;;; (src/clog-patches.lisp), through the same symbol CLOG's
;;;; HANDLE-NEW-CONNECTION calls, so they cover both the replacement's own
;;;; behavior and the fact that it is actually installed.

(test random-hex-string-is-installed-121
  "The system's load must have replaced CLOG's isaac-backed generator; a
CLOG reload that re-evaluates clog-connection.lisp (#105) would silently
restore the broken one, so assert identity, not just behavior."
  (is (eq (fdefinition 'clog-connection::random-hex-string)
          (fdefinition 'sm-harness-web-ui::crypto-random-hex-string))))

(test random-hex-string-shape-121
  (let ((id (clog-connection::random-hex-string)))
    (is (= 32 (length id)))
    (is (every (lambda (c) (find c "0123456789abcdef")) id))))

(test random-hex-string-survives-block-exhaustion-121
  "600 draws crosses two of cl-isaac's 256-draw block boundaries -- the
exact point where the old generator stored -1 into an (unsigned-byte 64)
slot and permanently wedged. Also checks uniqueness: 600 collision-free
128-bit ids is the least a working PRNG must manage."
  (let ((seen (make-hash-table :test #'equal)))
    (dotimes (i 600)
      (setf (gethash (clog-connection::random-hex-string) seen) t))
    (is (= 600 (hash-table-count seen)))))

(test random-hex-string-concurrent-draws-121
  "The old generator shared an unlocked isaac context across connection
threads; the replacement serializes one shared /dev/urandom stream. 8
threads x 100 draws must produce 800 distinct ids and no conditions."
  (let ((results (make-array 8))
        (threads '()))
    (dotimes (i 8)
      (let ((slot i))
        (push (sb-thread:make-thread
               (lambda ()
                 (setf (aref results slot)
                       (loop repeat 100
                             collect (clog-connection::random-hex-string))))
               :name (format nil "clog-patch-test-~D" slot))
              threads)))
    (mapc #'sb-thread:join-thread threads)
    (let ((seen (make-hash-table :test #'equal)))
      (loop for ids across results
            do (dolist (id ids) (setf (gethash id seen) t)))
      (is (= 800 (hash-table-count seen))))))

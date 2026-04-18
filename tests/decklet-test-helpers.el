;;; decklet-test-helpers.el --- Shared test infrastructure for Decklet -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'decklet)

;; `cl-letf' on C primitives triggers native-compilation of a
;; trampoline on first use, which costs ~500 ms per primitive and
;; dominates the entire test suite wall clock.  Disabling trampolines
;; falls back to a cheap interpreted wrapper; this cuts the suite
;; from ~5.6 s to ~0.65 s with no behavioral change.
(setq native-comp-enable-subr-trampolines nil)

(defmacro decklet-test--with-temp-db (&rest body)
  "Run BODY with an isolated temporary Decklet database.
Binds a fresh SQLite file, a fresh review log file, resets all UI
state variables and id counters, and cleans up the temp directory
on exit."
  (declare (indent 0) (debug t))
  `(let* ((tmp-dir (make-temp-file "decklet-test-" t))
          (decklet-directory (file-name-as-directory tmp-dir))
          (decklet-db-file (expand-file-name "decklet.sqlite" tmp-dir))
          (decklet-backup-directory (expand-file-name "backups" tmp-dir))
          (decklet-review-log-file
           (expand-file-name "review-log.jsonl" tmp-dir))
          (decklet-db--conn nil)
          (decklet--fsrs-scheduler nil)
          ;; Shadow tuner-installed weights so scheduler tests can
          ;; toggle the override without leaking the global default.
          (decklet-fsrs-parameters nil)
          ;; Reset id counters so each test mints from a fresh state.
          (decklet-db--last-card-id nil)
          (decklet-review-log--next-record-id nil)
          ;; Use the real production default so config regressions are caught.
          (decklet-review-order (default-value 'decklet-review-order))
          ;; Reset UI state to prevent cross-test pollution.
          (decklet-current-card-id nil)
          (decklet-last-added-word nil)
          (decklet-due-card-ids nil)
          (decklet--counter '(:reviewed 0 :due-review 0 :due-learning 0 :new 0)))
     (unwind-protect
         (progn ,@body)
       (when (and (boundp 'decklet-db--conn) decklet-db--conn)
         (sqlite-close decklet-db--conn)
         (setq decklet-db--conn nil))
       (delete-directory tmp-dir t))))

(defun decklet-test--ts (time)
  "Convert TIME to Decklet timestamp string."
  (decklet--time->fsrs-timestamp time))

(cl-defun decklet-test--make-card-meta (&rest args
                                              &key
                                              (state :review)
                                              (timestamp nil)
                                              &allow-other-keys)
  "Return a `decklet-card-meta' pre-populated with scheduled-card defaults.
STATE defaults to `:review'.  TIMESTAMP, when provided, is used for
`:added-date', `:last-review', and `:due' unless those keys appear
explicitly in ARGS.  When TIMESTAMP is nil, the current time is
used.  Any additional keys in ARGS override the defaults."
  (let* ((ts (or timestamp (decklet-test--ts (current-time))))
         (defaults (list :added-date ts :last-review ts :due ts :state state))
         (merged (copy-sequence defaults)))
    ;; Strip our own keyword args so we don't forward :timestamp to
    ;; `make-decklet-card-meta' (which would signal).
    (let ((clean args))
      (while clean
        (let ((k (car clean))
              (v (cadr clean)))
          (unless (eq k :timestamp)
            (setq merged (plist-put merged k v))))
        (setq clean (cddr clean))))
    (apply #'make-decklet-card-meta merged)))

(defmacro decklet-test--with-silent-review-ui (&rest body)
  "Run BODY with review-mode UI side effects stubbed to no-ops.
Stubs `decklet-review--reset-ui-state', `decklet-review--render-buffer',
and `run-hooks' so unit tests can exercise review logic without
touching a real buffer or firing user hooks."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'decklet-review--reset-ui-state)
              (lambda (&rest _) nil))
             ((symbol-function 'decklet-review--render-buffer)
              (lambda (&rest _) nil))
             ((symbol-function 'run-hooks)
              (lambda (&rest _) nil)))
     ,@body))

(provide 'decklet-test-helpers)
;;; decklet-test-helpers.el ends here

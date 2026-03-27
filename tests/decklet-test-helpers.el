;;; decklet-test-helpers.el --- Shared test infrastructure for Decklet -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'decklet)

(defmacro decklet-test--with-temp-db (&rest body)
  "Run BODY with an isolated temporary Decklet database.
Binds a fresh SQLite file, resets all UI state variables, and
cleans up the temp directory on exit."
  (declare (indent 0) (debug t))
  `(let* ((tmp-dir (make-temp-file "decklet-test-" t))
          (decklet-directory (file-name-as-directory tmp-dir))
          (decklet-db-file (expand-file-name "decklet.sqlite" tmp-dir))
          (decklet-backup-directory (expand-file-name "backups" tmp-dir))
          (decklet-db--conn nil)
          (decklet--fsrs-scheduler nil)
          ;; Use the real production default so config regressions are caught.
          (decklet-review-order (default-value 'decklet-review-order))
          ;; Reset UI state to prevent cross-test pollution.
          (decklet-current-word nil)
          (decklet-last-added-word nil)
          (decklet-due-words nil)
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

(provide 'decklet-test-helpers)
;;; decklet-test-helpers.el ends here

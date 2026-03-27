;;; decklet-backup-test.el --- Tests for decklet backup functionality -*- lexical-binding: t; -*-

(require 'decklet-test-helpers)

;; ---------------------------------------------------------------------------
;; Backup naming + list ordering
;; ---------------------------------------------------------------------------
;; These tests target backup file conventions:
;; - suffix collision resolution,
;; - newest-first ordering by embedded UTC timestamp,
;; - timestamp extraction from suffixed filenames.

(ert-deftest decklet-test-backup-target-adds-numeric-suffix ()
  (decklet-test--with-temp-db
    (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
           (base (file-name-base decklet-db-file))
           (timestamp "20260206T120000Z")
           (existing (expand-file-name
                      (format "%s-%s.sqlite" base timestamp)
                      backup-dir)))
      (make-directory backup-dir t)
      (with-temp-file existing (insert "dummy"))
      (should (string= (decklet-db--backup-target backup-dir base timestamp)
                       (expand-file-name
                        (format "%s-%s-1.sqlite" base timestamp)
                        backup-dir))))))

(ert-deftest decklet-test-backup-files-sorted-by-timestamp-desc ()
  (decklet-test--with-temp-db
    (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
           (base (file-name-base decklet-db-file))
           (older (expand-file-name
                   (format "%s-20250101T010101Z.sqlite" base)
                   backup-dir))
           (middle (expand-file-name
                    (format "%s-20250102T010101Z.sqlite" base)
                    backup-dir))
           (newest (expand-file-name
                    (format "%s-20250103T010101Z.sqlite" base)
                    backup-dir)))
      (make-directory backup-dir t)
      (dolist (f (list middle newest older))
        (with-temp-file f (insert "dummy")))
      (should (equal (decklet-db--backup-files)
                     (list newest middle older))))))

(ert-deftest decklet-test-backup-timestamp-parses-suffixed-filenames ()
  (decklet-test--with-temp-db
    (let* ((base (file-name-base decklet-db-file))
           (file (expand-file-name
                  (format "%s-20260101T123456Z-2.sqlite" base)
                  temporary-file-directory))
           (parsed (decklet-db--backup-timestamp file)))
      (should parsed)
      (should (string= (format-time-string "%Y%m%dT%H%M%SZ" parsed "UTC0")
                       "20260101T123456Z")))))

;; ---------------------------------------------------------------------------
;; Backup prune behavior
;; ---------------------------------------------------------------------------
;; Here we test both non-interactive prune by max-count, and interactive
;; confirmation refusal.

(ert-deftest decklet-test-backup-prune-max-count-without-confirm ()
  (decklet-test--with-temp-db
    (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
           (base (file-name-base decklet-db-file))
           (decklet-backup-retain-days 365)
           (decklet-backup-prune-min-count 999)
           (decklet-backup-prune-max-count 2)
           (decklet-backup-prune-confirm nil)
           (files (list
                   (expand-file-name (format "%s-20250101T010101Z.sqlite" base) backup-dir)
                   (expand-file-name (format "%s-20250102T010101Z.sqlite" base) backup-dir)
                   (expand-file-name (format "%s-20250103T010101Z.sqlite" base) backup-dir)
                   (expand-file-name (format "%s-20250104T010101Z.sqlite" base) backup-dir))))
      (make-directory backup-dir t)
      (cl-loop for f in files
               for idx from 0
               do (with-temp-file f (insert "dummy"))
               do (set-file-times f (time-subtract (current-time)
                                                   (days-to-time (+ 10 idx)))))
      (decklet-db--backup-prune backup-dir base)
      (let ((remaining (sort (directory-files backup-dir t "\\.sqlite\\'") #'string<)))
        (should (= 2 (length remaining)))
        ;; Should keep the two newest by file mtime.
        ;; In this fixture, 20250101/20250102 were given newer mtimes.
        (should (equal (mapcar #'file-name-nondirectory remaining)
                       (list (format "%s-20250101T010101Z.sqlite" base)
                             (format "%s-20250102T010101Z.sqlite" base))))))))

(ert-deftest decklet-test-backup-prune-age-and-max-count-union ()
  ;; When both age and max-count conditions apply, files qualifying under
  ;; either criterion should be deleted (union, not override).
  (decklet-test--with-temp-db
    (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
           (base (file-name-base decklet-db-file))
           (decklet-backup-retain-days 30)
           (decklet-backup-prune-min-count 2)
           (decklet-backup-prune-max-count 3)
           (decklet-backup-prune-confirm nil)
           ;; 4 files: two old (60 days), two recent (1 day).
           ;; max-count=3 would only push out 1 file by count alone,
           ;; but the two old files should also be deleted by age.
           (old-1 (expand-file-name (format "%s-20250101T000000Z.sqlite" base) backup-dir))
           (old-2 (expand-file-name (format "%s-20250102T000000Z.sqlite" base) backup-dir))
           (new-1 (expand-file-name (format "%s-20250103T000000Z.sqlite" base) backup-dir))
           (new-2 (expand-file-name (format "%s-20250104T000000Z.sqlite" base) backup-dir)))
      (make-directory backup-dir t)
      (dolist (f (list old-1 old-2 new-1 new-2))
        (with-temp-file f (insert "dummy")))
      (set-file-times old-1 (time-subtract (current-time) (days-to-time 62)))
      (set-file-times old-2 (time-subtract (current-time) (days-to-time 61)))
      (set-file-times new-1 (time-subtract (current-time) (days-to-time 2)))
      (set-file-times new-2 (time-subtract (current-time) (days-to-time 1)))
      (decklet-db--backup-prune backup-dir base)
      ;; old-1 and old-2 qualify by age; old-1 also qualifies by max-count.
      ;; Both should be deleted, leaving only new-1 and new-2.
      (let ((remaining (sort (mapcar #'file-name-nondirectory
                                     (directory-files backup-dir t "\\.sqlite\\'"))
                             #'string<)))
        (should (= 2 (length remaining)))
        (should (equal remaining
                       (list (format "%s-20250103T000000Z.sqlite" base)
                             (format "%s-20250104T000000Z.sqlite" base))))))))

(ert-deftest decklet-test-backup-prune-respects-confirm-no ()
  (decklet-test--with-temp-db
    (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
           (base (file-name-base decklet-db-file))
           (decklet-backup-retain-days 365)
           (decklet-backup-prune-min-count 1)
           (decklet-backup-prune-max-count 1)
           (decklet-backup-prune-confirm t)
           (files (list
                   (expand-file-name (format "%s-20250101T010101Z.sqlite" base) backup-dir)
                   (expand-file-name (format "%s-20250102T010101Z.sqlite" base) backup-dir))))
      (make-directory backup-dir t)
      (dolist (f files)
        (with-temp-file f (insert "dummy")))
      ;; Mock confirmation prompt: user declines, so nothing should be deleted.
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil)))
        (decklet-db--backup-prune backup-dir base))
      (should (= 2 (length (directory-files backup-dir t "\\.sqlite\\'")))))))

(ert-deftest decklet-test-backup-prune-age-deletes-old-files ()
  (decklet-test--with-temp-db
    (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
           (base (file-name-base decklet-db-file))
           (decklet-backup-retain-days 30)
           (decklet-backup-prune-min-count 2)
           (decklet-backup-prune-max-count nil)
           (decklet-backup-prune-confirm nil)
           ;; One file older than retain-days, one recent.
           (old-file (expand-file-name (format "%s-20250101T010101Z.sqlite" base) backup-dir))
           (new-file (expand-file-name (format "%s-20250102T010101Z.sqlite" base) backup-dir)))
      (make-directory backup-dir t)
      (dolist (f (list old-file new-file))
        (with-temp-file f (insert "dummy")))
      ;; old-file: 60 days ago; new-file: 1 day ago.
      (set-file-times old-file (time-subtract (current-time) (days-to-time 60)))
      (set-file-times new-file (time-subtract (current-time) (days-to-time 1)))
      (decklet-db--backup-prune backup-dir base)
      (let ((remaining (directory-files backup-dir t "\\.sqlite\\'")))
        (should (= 1 (length remaining)))
        (should (string= (file-name-nondirectory (car remaining))
                         (format "%s-20250102T010101Z.sqlite" base)))))))

(ert-deftest decklet-test-backup-prune-age-skips-when-below-min-count ()
  (decklet-test--with-temp-db
    (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
           (base (file-name-base decklet-db-file))
           (decklet-backup-retain-days 30)
           (decklet-backup-prune-min-count 5)
           (decklet-backup-prune-max-count nil)
           (decklet-backup-prune-confirm nil)
           ;; Two files, both older than retain-days.
           (files (list
                   (expand-file-name (format "%s-20250101T010101Z.sqlite" base) backup-dir)
                   (expand-file-name (format "%s-20250102T010101Z.sqlite" base) backup-dir))))
      (make-directory backup-dir t)
      (dolist (f files)
        (with-temp-file f (insert "dummy"))
        (set-file-times f (time-subtract (current-time) (days-to-time 60))))
      ;; Count (2) < min-count (5): prune should not run.
      (decklet-db--backup-prune backup-dir base)
      (should (= 2 (length (directory-files backup-dir t "\\.sqlite\\'")))))))

;; ---------------------------------------------------------------------------
;; Backup idempotency
;; ---------------------------------------------------------------------------
;; Calling interactive backup twice without DB changes should create exactly one
;; backup file.

(ert-deftest decklet-test-db-backup-skip-when-unchanged ()
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    ;; Create a real DB change so first backup has content.
    (let* ((now (decklet-test--ts (current-time)))
           (meta (make-decklet-card-meta
                  :added-date now :last-review now :due now :state :review)))
      (decklet-db--upsert-card "backup-word" meta))
    (decklet-db-backup)
    (let ((count-1 (length (decklet-db--backup-files))))
      (should (= 1 count-1))
      ;; No DB writes between backups; second call should not add files.
      (decklet-db-backup)
      (should (= count-1 (length (decklet-db--backup-files)))))))

;; ---------------------------------------------------------------------------
;; Completion binding hook behavior
;; ---------------------------------------------------------------------------
;; The restore completion wrapper supports dynamic var bindings for completion
;; UIs (e.g., vertico sorting override).  We mock `completing-read' to prove
;; those bindings are in effect.

(ert-deftest decklet-test-read-backup-choice-binds-completion-vars ()
  (let ((decklet-backup-restore-completion-setup
         (lambda () '((decklet-test--temp-binding . 42))))
        (captured nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt choices &optional predicate require-match initial-input hist def)
                 (setq captured (list :prompt prompt
                                      :choices choices
                                      :predicate predicate
                                      :require-match require-match
                                      :initial-input initial-input
                                      :hist hist
                                      :default def))
                 ;; Read from dynamic binding explicitly.
                 (number-to-string (symbol-value 'decklet-test--temp-binding)))))
      (should (string= (decklet-db--read-backup-choice '("a" "b") "a") "42"))
      ;; Assert important completion contract was preserved.
      (should (equal (plist-get captured :choices) '("a" "b")))
      (should (equal (plist-get captured :default) "a"))
      (should (eq (plist-get captured :require-match) t)))))

(provide 'decklet-backup-test)
;;; decklet-backup-test.el ends here

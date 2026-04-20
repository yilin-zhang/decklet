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
     (should (string= (decklet-db--backup-target backup-dir base "sqlite" timestamp)
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
;; Retention is a single knob: keep the newest `decklet-backup-prune-max-count'
;; files (ordered by embedded UTC timestamp in the filename); delete the rest.

(ert-deftest decklet-test-backup-prune-keeps-newest-max-count ()
  (decklet-test--with-temp-db
   (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
          (base (file-name-base decklet-db-file))
          (decklet-backup-prune-max-count 2)
          (files (list
                  (expand-file-name (format "%s-20250101T010101Z.sqlite" base) backup-dir)
                  (expand-file-name (format "%s-20250102T010101Z.sqlite" base) backup-dir)
                  (expand-file-name (format "%s-20250103T010101Z.sqlite" base) backup-dir)
                  (expand-file-name (format "%s-20250104T010101Z.sqlite" base) backup-dir))))
     (make-directory backup-dir t)
     (dolist (f files) (with-temp-file f (insert "dummy")))
     (decklet-db--backup-prune backup-dir base "sqlite")
     (let ((remaining (sort (mapcar #'file-name-nondirectory
                                    (directory-files backup-dir t "\\.sqlite\\'"))
                            #'string<)))
       (should (= 2 (length remaining)))
       (should (equal remaining
                      (list (format "%s-20250103T010101Z.sqlite" base)
                            (format "%s-20250104T010101Z.sqlite" base))))))))

(ert-deftest decklet-test-backup-prune-noop-when-under-limit ()
  (decklet-test--with-temp-db
   (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
          (base (file-name-base decklet-db-file))
          (decklet-backup-prune-max-count 5)
          (files (list
                  (expand-file-name (format "%s-20250101T010101Z.sqlite" base) backup-dir)
                  (expand-file-name (format "%s-20250102T010101Z.sqlite" base) backup-dir))))
     (make-directory backup-dir t)
     (dolist (f files) (with-temp-file f (insert "dummy")))
     (decklet-db--backup-prune backup-dir base "sqlite")
     (should (= 2 (length (directory-files backup-dir t "\\.sqlite\\'")))))))

(ert-deftest decklet-test-backup-prune-noop-when-disabled ()
  (decklet-test--with-temp-db
   (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
          (base (file-name-base decklet-db-file))
          (decklet-backup-prune-max-count nil)
          (files (list
                  (expand-file-name (format "%s-20250101T010101Z.sqlite" base) backup-dir)
                  (expand-file-name (format "%s-20250102T010101Z.sqlite" base) backup-dir)
                  (expand-file-name (format "%s-20250103T010101Z.sqlite" base) backup-dir))))
     (make-directory backup-dir t)
     (dolist (f files) (with-temp-file f (insert "dummy")))
     (decklet-db--backup-prune backup-dir base "sqlite")
     (should (= 3 (length (directory-files backup-dir t "\\.sqlite\\'")))))))

;; ---------------------------------------------------------------------------
;; Backup idempotency
;; ---------------------------------------------------------------------------
;; Calling interactive backup twice without DB changes should create exactly one
;; backup file.

(ert-deftest decklet-test-db-backup-skip-when-unchanged ()
  (decklet-test--with-temp-db
   (decklet-db--ensure)
   ;; Create a real DB change so first backup has content.
   (decklet-db--upsert-card "backup-word" (decklet-test--make-card-meta))
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

;; ---------------------------------------------------------------------------
;; Post-backup hook + auxiliary-file backup
;; ---------------------------------------------------------------------------
;; `decklet-db-post-backup-functions' is an abnormal hook that
;; extensions/core modules use to back up their own files alongside
;; the SQLite snapshot.  The review log subscribes to it on load so
;; `review-log.jsonl' rides in the same backup rotation.

(ert-deftest decklet-test-db-post-backup-hook-fires-after-backup ()
  "`decklet-db-post-backup-functions' runs after a successful backup.
Handlers receive (BACKUP-DIR TIMESTAMP) where TIMESTAMP matches
the `YYYYMMDDTHHMMSSZ' form used by the backup filenames."
  (decklet-test--with-temp-db
   (decklet-db--ensure)
   (decklet-db--upsert-card "hook-probe" (decklet-test--make-card-meta))
   (let* ((captured nil)
          ;; Shadow the global hook so only our probe runs.  `let*'
          ;; is required so the lambda closes over `captured'.
          (decklet-db-post-backup-functions
           (list (lambda (backup-dir timestamp)
                   (setq captured (list :dir backup-dir :ts timestamp))))))
     (decklet-db-backup)
     (should captured)
     (should (stringp (plist-get captured :dir)))
     (should (file-directory-p (plist-get captured :dir)))
     (should (string-match-p "\\`[0-9]\\{8\\}T[0-9]\\{6\\}Z\\'"
                             (plist-get captured :ts))))))

(ert-deftest decklet-test-backup-auxiliary-file-copies-with-timestamp ()
  "`decklet-db-backup-auxiliary-file' writes a timestamped sibling."
  (decklet-test--with-temp-db
   (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
          (source-file (expand-file-name "extra.jsonl" tmp-dir))
          (timestamp "20260410T120000Z")
          (expected (expand-file-name
                     (format "extra-%s.jsonl" timestamp) backup-dir)))
     (with-temp-file source-file (insert "line-one\n"))
     (make-directory backup-dir t)
     (decklet-db-backup-auxiliary-file source-file backup-dir timestamp)
     (should (file-exists-p expected))
     (should (equal (with-temp-buffer
                      (insert-file-contents expected)
                      (buffer-string))
                    "line-one\n")))))

(ert-deftest decklet-test-backup-auxiliary-file-missing-source-noop ()
  "`decklet-db-backup-auxiliary-file' is a silent no-op on missing source."
  (decklet-test--with-temp-db
   (let ((backup-dir (file-name-as-directory decklet-backup-directory))
         (missing (expand-file-name "absent.jsonl" tmp-dir))
         (timestamp "20260410T120000Z"))
     (make-directory backup-dir t)
     (decklet-db-backup-auxiliary-file missing backup-dir timestamp)
     (should-not (file-exists-p
                  (expand-file-name (format "absent-%s.jsonl" timestamp)
                                    backup-dir)))
     ;; Nothing else should have been created either.
     (should-not (directory-files backup-dir nil "absent")))))

(ert-deftest decklet-test-review-log-backed-up-with-db ()
  "`decklet-db-backup' fires the post-backup hook and the review log
subscriber copies `review-log.jsonl' into the backup directory
with a matching timestamp."
  (decklet-test--with-temp-db
   (decklet-db--ensure)
   (decklet-db--upsert-card "backed-up" (decklet-test--make-card-meta))
   (decklet-review-log-append-void 42)
   (should (file-exists-p decklet-review-log-file))
   (decklet-db-backup)
   (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
          (log-backups (directory-files backup-dir t
                                        "\\`review-log-[0-9]+T[0-9]+Z\\(-[0-9]+\\)?\\.jsonl\\'")))
     (should (= 1 (length log-backups)))
     ;; Content matches the source.
     (should (equal (with-temp-buffer
                      (insert-file-contents (car log-backups))
                      (buffer-string))
                    (with-temp-buffer
                      (insert-file-contents decklet-review-log-file)
                      (buffer-string)))))))

(provide 'decklet-backup-test)
;;; decklet-backup-test.el ends here

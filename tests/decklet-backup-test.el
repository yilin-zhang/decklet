;;; decklet-backup-test.el --- Tests for decklet backup functionality -*- lexical-binding: t; -*-

(require 'decklet-test-helpers)

;;; Backup naming and ordering

(ert-deftest decklet-test-backup-target-adds-numeric-suffix ()
  "A backup-name collision gets a numeric suffix."
  (decklet-test--with-temp-db
   (decklet-test--with-backup-dir
    (let ((timestamp "20260206T120000Z"))
      (decklet-test--touch
       (expand-file-name (format "%s-%s.sqlite" base timestamp) backup-dir))
      (should (string= (decklet-db--backup-target backup-dir base "sqlite" timestamp)
                       (expand-file-name (format "%s-%s-1.sqlite" base timestamp)
                                         backup-dir)))))))

(ert-deftest decklet-test-backup-files-sorted-newest-first ()
  "`decklet-db--backup-files' lists backups newest-first by embedded timestamp."
  (decklet-test--with-temp-db
   (decklet-test--with-backup-dir
    (let ((older  (expand-file-name (format "%s-20250101T010101Z.sqlite" base) backup-dir))
          (middle (expand-file-name (format "%s-20250102T010101Z.sqlite" base) backup-dir))
          (newest (expand-file-name (format "%s-20250103T010101Z.sqlite" base) backup-dir)))
      (mapc #'decklet-test--touch (list middle newest older))
      (should (equal (decklet-db--backup-files) (list newest middle older)))))))

(ert-deftest decklet-test-backup-timestamp-parses-suffixed-filename ()
  "Backup timestamps parse out of names carrying a collision suffix."
  (decklet-test--with-temp-db
   (let* ((base (file-name-base decklet-db-file))
          (file (expand-file-name (format "%s-20260101T123456Z-2.sqlite" base)
                                  temporary-file-directory))
          (parsed (decklet-db--backup-timestamp file)))
     (should parsed)
     (should (string= (format-time-string "%Y%m%dT%H%M%SZ" parsed "UTC0")
                      "20260101T123456Z")))))

;;; Pruning

(ert-deftest decklet-test-backup-prune-keeps-newest-max-count ()
  "Pruning keeps the newest `decklet-backup-prune-max-count' backups."
  (decklet-test--with-temp-db
   (decklet-test--with-backup-dir
    (let ((decklet-backup-prune-max-count 2))
      (dolist (day '("01" "02" "03" "04"))
        (decklet-test--touch
         (expand-file-name (format "%s-202501%sT010101Z.sqlite" base day) backup-dir)))
      (decklet-db--backup-prune backup-dir base "sqlite")
      (should (equal (sort (mapcar #'file-name-nondirectory
                                   (directory-files backup-dir t "\\.sqlite\\'"))
                           #'string<)
                     (list (format "%s-20250103T010101Z.sqlite" base)
                           (format "%s-20250104T010101Z.sqlite" base))))))))

(ert-deftest decklet-test-backup-prune-noop-under-limit-or-disabled ()
  "Pruning is a no-op when the count is under the limit or pruning is disabled."
  (decklet-test--with-temp-db
   (decklet-test--with-backup-dir
    (dolist (day '("01" "02" "03"))
      (decklet-test--touch
       (expand-file-name (format "%s-202501%sT010101Z.sqlite" base day) backup-dir)))
    (let ((decklet-backup-prune-max-count 5))
      (decklet-db--backup-prune backup-dir base "sqlite")
      (should (= 3 (length (directory-files backup-dir t "\\.sqlite\\'")))))
    (let ((decklet-backup-prune-max-count nil))
      (decklet-db--backup-prune backup-dir base "sqlite")
      (should (= 3 (length (directory-files backup-dir t "\\.sqlite\\'"))))))))

;;; Interactive backup

(ert-deftest decklet-test-backup-skips-when-unchanged ()
  "A second backup with no intervening DB change adds no new file."
  (decklet-test--with-temp-db
   (decklet-test--add-card-meta "backup-word")
   (decklet-db-backup)
   (should (= 1 (length (decklet-db--backup-files))))
   (decklet-db-backup)
   (should (= 1 (length (decklet-db--backup-files))))))

;;; Restore

(ert-deftest decklet-test-backup-restore-errors-with-session-buffers-open ()
  "Restore refuses while a session buffer is open, leaving the DB connected."
  (decklet-test--with-temp-db
   (decklet-db--ensure)
   (let ((backup-file (expand-file-name "decklet-20260101T010101Z.sqlite" tmp-dir)))
     (decklet-test--touch backup-file "backup")
     (decklet-test--with-temp-buffers (buf)
				      (with-current-buffer buf (decklet-db-register-dependent-buffer))
				      (cl-letf (((symbol-function 'decklet-db--backup-files)
						 (lambda () (list backup-file)))
						((symbol-function 'decklet-db--read-backup-choice)
						 (lambda (_choices default) default)))
					(should-error (decklet-db-restore) :type 'user-error))
				      (should decklet-db--conn)))))

(ert-deftest decklet-test-backup-restore-auto-disconnects-without-session ()
  "With no session buffers open, restore disconnects and overwrites the DB."
  (decklet-test--with-temp-db
   (decklet-db--ensure)
   (let ((backup-file (expand-file-name
                       "decklet-20260101T010101Z.sqlite"
                       decklet-backup-directory))
         (log-backup (expand-file-name
                      "review-log-20260101T010101Z.jsonl"
                      decklet-backup-directory)))
     (make-directory decklet-backup-directory t)
     (decklet-test--touch backup-file "backup-payload")
     (decklet-test--touch log-backup "log-payload")
     (cl-letf (((symbol-function 'decklet-db--backup-files)
                (lambda () (list backup-file)))
               ((symbol-function 'decklet-db--read-backup-choice)
                (lambda (_choices default) default))
               ((symbol-function 'yes-or-no-p) (lambda (_p) t)))
       (decklet-db-restore))
     (should-not decklet-db--conn)
     (should (string= (decklet-test--file-string decklet-db-file) "backup-payload"))
     (should (string= (decklet-test--file-string decklet-review-log-file)
                      "log-payload")))))

(ert-deftest decklet-test-backup-restore-requires-matching-review-log ()
  "Restore refuses a database backup whose paired review log is missing."
  (decklet-test--with-temp-db
   (let ((backup-file (expand-file-name
                       "decklet-20260101T010101Z.sqlite"
                       decklet-backup-directory)))
     (make-directory decklet-backup-directory t)
     (decklet-test--touch backup-file "backup-payload")
     (cl-letf (((symbol-function 'decklet-db--backup-files)
                (lambda () (list backup-file)))
               ((symbol-function 'decklet-db--read-backup-choice)
                (lambda (_choices default) default)))
       (should-error (decklet-db-restore) :type 'user-error))
     (should-not (file-exists-p decklet-db-file)))))

(ert-deftest decklet-test-backup-read-choice-binds-completion-vars ()
  "The restore completer applies the dynamic bindings from
`decklet-backup-restore-completion-setup' and preserves the completion contract."
  (let ((decklet-backup-restore-completion-setup
         (lambda () '((decklet-test--temp-binding . 42))))
        (captured nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &optional _pred require-match _init _hist def)
                 (setq captured (list :choices choices :require-match require-match
                                      :default def))
                 (number-to-string (symbol-value 'decklet-test--temp-binding)))))
      (should (string= (decklet-db--read-backup-choice '("a" "b") "a") "42"))
      (should (equal (plist-get captured :choices) '("a" "b")))
      (should (equal (plist-get captured :default) "a"))
      (should (eq (plist-get captured :require-match) t)))))

;;; Post-backup hook and auxiliary-file backup
;; The review log subscribes to `decklet-db-post-backup-functions' so it rides
;; in the same backup rotation as the SQLite snapshot.

(ert-deftest decklet-test-backup-post-backup-hook-fires ()
  "`decklet-db-post-backup-functions' runs after a backup with (BACKUP-DIR
TIMESTAMP), where TIMESTAMP is the compact UTC form."
  (decklet-test--with-temp-db
   (decklet-test--add-card-meta "hook-probe")
   (let* ((captured nil)
          (decklet-db-post-backup-functions
           (list (lambda (dir ts) (setq captured (list :dir dir :ts ts))))))
     (decklet-db-backup)
     (should (file-directory-p (plist-get captured :dir)))
     (should (string-match-p "\\`[0-9]\\{8\\}T[0-9]\\{6\\}Z\\'"
                             (plist-get captured :ts))))))

(ert-deftest decklet-test-backup-auxiliary-file-copies-with-timestamp ()
  "`decklet-db-backup-auxiliary-file' writes a timestamped sibling copy."
  (decklet-test--with-temp-db
   (decklet-test--with-backup-dir
    (let ((source (expand-file-name "extra.jsonl" tmp-dir))
          (timestamp "20260410T120000Z"))
      (decklet-test--touch source "line-one\n")
      (decklet-db-backup-auxiliary-file source backup-dir timestamp)
      (let ((expected (expand-file-name (format "extra-%s.jsonl" timestamp) backup-dir)))
        (should (file-exists-p expected))
        (should (string= (decklet-test--file-string expected) "line-one\n")))))))

(ert-deftest decklet-test-backup-auxiliary-file-missing-source-noop ()
  "`decklet-db-backup-auxiliary-file' is a silent no-op for an absent source."
  (decklet-test--with-temp-db
   (decklet-test--with-backup-dir
    (decklet-db-backup-auxiliary-file
     (expand-file-name "absent.jsonl" tmp-dir) backup-dir "20260410T120000Z")
    (should-not (directory-files backup-dir nil "absent")))))

(ert-deftest decklet-test-backup-review-log-rides-with-db ()
  "Backing up the DB also copies the review log into the backup directory via
the post-backup hook subscriber, with matching content."
  (decklet-test--with-temp-db
   (decklet-test--add-card-meta "backed-up")
   (decklet-review-log-append-void 42)
   (should (file-exists-p decklet-review-log-file))
   (decklet-db-backup)
   (let ((log-backups (directory-files
                       (file-name-as-directory decklet-backup-directory) t
                       "\\`review-log-[0-9]+T[0-9]+Z\\(-[0-9]+\\)?\\.jsonl\\'")))
     (should (= 1 (length log-backups)))
     (should (string= (decklet-test--file-string (car log-backups))
                      (decklet-test--file-string decklet-review-log-file))))))

(provide 'decklet-backup-test)
;;; decklet-backup-test.el ends here

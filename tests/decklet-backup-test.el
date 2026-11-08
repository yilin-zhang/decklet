;;; decklet-backup-test.el --- This file tests Decklet backup functionality. -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

;;; Pruning

(ert-deftest decklet-test-backup-prune-keeps-newest-max-count ()
  "Pruning keeps the newest `decklet-backup-prune-max-count' backups.
A nil limit disables pruning and keeps every file."
  (decklet-test--with-temp-db
    (let ((backup-dir (file-name-as-directory decklet-backup-directory))
          (base (file-name-base decklet-db-file)))
      (make-directory backup-dir t)
      (dolist (day '("01" "02" "03" "04"))
        (decklet-test--touch
         (expand-file-name (format "%s-202501%sT010101Z.sqlite" base day) backup-dir)))
      (cl-flet ((names ()
                  (sort (mapcar #'file-name-nondirectory
                                (directory-files backup-dir t "\\.sqlite\\'"))
                        #'string<)))
        (let ((decklet-backup-prune-max-count nil))
          (decklet-backup--backup-prune backup-dir base "sqlite")
          (should (= 4 (length (names)))))
        (let ((decklet-backup-prune-max-count 2))
          (decklet-backup--backup-prune backup-dir base "sqlite")
          (should (equal (names)
                         (list (format "%s-20250103T010101Z.sqlite" base)
                               (format "%s-20250104T010101Z.sqlite" base)))))))))

;;; Backup

(ert-deftest decklet-test-backup-skips-when-unchanged ()
  "A backup with no DB change since the last one adds no new file.
Each backup gets its own timestamp, so a backup that was not skipped
would show up as a new file instead of overwriting the last one."
  (decklet-test--with-temp-db
    (let ((stamps '("20260101T000001Z" "20260101T000002Z" "20260101T000003Z")))
      (cl-letf (((symbol-function 'decklet--timestamp-utc)
                 (lambda (&optional _time) (pop stamps))))
        (decklet--add-card "backup-word")
        (decklet-db-backup)
        (decklet-db-backup)
        (should (= 1 (length (decklet-backup--backup-files))))
        (decklet--add-card "another-word")
        (decklet-db-backup)
        (should (= 2 (length (decklet-backup--backup-files))))))))

(ert-deftest decklet-test-backup-pairs-database-with-review-log ()
  "Every backup writes the database together with a copy of the review log.
A deck with no review history still gets an empty log copy, so the
backup can be restored."
  (decklet-test--with-temp-db
    (decklet--add-card "unrated")
    (decklet-db-backup)
    (should (string-empty-p
             (decklet-test--file-string
              (decklet-backup--matching-review-log-backup
               (car (decklet-backup--backup-files))))))
    (decklet-rate-card (decklet-test--card-id "unrated") 3)
    (decklet-db-backup)
    (should (string= (decklet-test--file-string
                      (decklet-backup--matching-review-log-backup
                       (car (decklet-backup--backup-files))))
                     (decklet-test--file-string decklet-review-log-file)))))

(ert-deftest decklet-test-backup-hook-backs-up-auxiliary-files ()
  "Extensions back up their own files from `decklet-db-post-backup-functions'.
The hook receives the backup directory and timestamp, and
`decklet-backup-auxiliary-file' copies a file there under that timestamp."
  (decklet-test--with-temp-db
    (decklet-test--add-card-meta "hook-probe")
    (let* ((source (expand-file-name "extra.jsonl" tmp-dir))
           (decklet-db-post-backup-functions
            (list (lambda (dir timestamp)
                    (decklet-backup-auxiliary-file source dir timestamp)))))
      (decklet-test--touch source "line-one\n")
      (decklet-db-backup)
      (let ((copies (directory-files decklet-backup-directory t
                                     "\\`extra-[0-9]\\{8\\}T[0-9]\\{6\\}Z\\.jsonl\\'")))
        (should (= 1 (length copies)))
        (should (string= "line-one\n" (decklet-test--file-string (car copies))))))))

;;; Restore

(ert-deftest decklet-test-backup-restore-errors-with-session-buffers-open ()
  "Restore refuses while a session buffer is open, leaving the DB connected."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (let ((backup-file (expand-file-name "decklet-20260101T010101Z.sqlite" tmp-dir)))
      (decklet-test--touch backup-file "backup")
      (decklet-test--with-temp-buffers (buf)
	(with-current-buffer buf (decklet-db-register-session-buffer))
	(cl-letf (((symbol-function 'decklet-backup--backup-files)
		   (lambda () (list backup-file)))
		  ((symbol-function 'decklet-backup--read-backup-choice)
		   (lambda (_choices default) default)))
	  (should-error (decklet-db-restore) :type 'user-error))
	(should decklet-db--conn)))))

(ert-deftest decklet-test-backup-restore-auto-disconnects-without-session ()
  "With no session buffers open, restore disconnects and overwrites the DB."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (let ((database-payload "backup-payload")
          (log-payload "log-payload")
          (backup-file (expand-file-name
                        "decklet-20260101T010101Z.sqlite"
                        decklet-backup-directory))
          (log-backup (expand-file-name
                       "review-log-20260101T010101Z.jsonl"
                       decklet-backup-directory)))
      (make-directory decklet-backup-directory t)
      (decklet-test--touch backup-file database-payload)
      (decklet-test--touch log-backup log-payload)
      (cl-letf (((symbol-function 'decklet-backup--backup-files)
                 (lambda () (list backup-file)))
                ((symbol-function 'decklet-backup--read-backup-choice)
                 (lambda (_choices default) default))
                ((symbol-function 'yes-or-no-p) (lambda (_p) t)))
        (decklet-db-restore))
      (should-not decklet-db--conn)
      (should (string= (decklet-test--file-string decklet-db-file)
                       database-payload))
      (should (string= (decklet-test--file-string decklet-review-log-file)
                       log-payload)))))

(ert-deftest decklet-test-backup-restore-requires-matching-review-log ()
  "Restore refuses a database backup whose paired review log is missing."
  (decklet-test--with-temp-db
    (let ((backup-file (expand-file-name
                        "decklet-20260101T010101Z.sqlite"
                        decklet-backup-directory)))
      (make-directory decklet-backup-directory t)
      (decklet-test--touch backup-file "backup-payload")
      (cl-letf (((symbol-function 'decklet-backup--backup-files)
                 (lambda () (list backup-file)))
                ((symbol-function 'decklet-backup--read-backup-choice)
                 (lambda (_choices default) default)))
        (should-error (decklet-db-restore) :type 'user-error))
      (should-not (file-exists-p decklet-db-file)))))

(provide 'decklet-backup-test)
;;; decklet-backup-test.el ends here

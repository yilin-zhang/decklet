;;; decklet-backup-test.el --- This file tests Decklet backup functionality. -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

;;; Pruning

(ert-deftest decklet-test-backup-prune-keeps-newest-max-count ()
  "Pruning keeps the newest `decklet-backup-prune-max-count' backup pairs.
Each pruned database backup takes its review-log backup with it.  A nil
limit disables pruning and keeps every file."
  (decklet-test--with-temp-db
    (make-directory decklet-backup-directory t)
    (dolist (day '("01" "02" "03"))
      (dolist (name '("decklet-202501%sT010101Z.sqlite"
                      "review-log-202501%sT010101Z.jsonl"))
        (decklet-test--touch
         (expand-file-name (format name day) decklet-backup-directory))))
    (let ((decklet-backup-prune-max-count nil))
      (decklet-backup--prune-pairs)
      (should (= 6 (length (directory-files decklet-backup-directory nil
                                            "\\`[^.]")))))
    (let ((decklet-backup-prune-max-count 2))
      (decklet-backup--prune-pairs)
      (should (equal (directory-files decklet-backup-directory nil "\\`[^.]")
                     '("decklet-20250102T010101Z.sqlite"
                       "decklet-20250103T010101Z.sqlite"
                       "review-log-20250102T010101Z.jsonl"
                       "review-log-20250103T010101Z.jsonl"))))))

;;; Backup

(ert-deftest decklet-test-backup-skips-when-unchanged ()
  "A backup with no DB change since the last one adds no new file.
Each backup gets its own timestamp, so a backup that was not skipped
would show up as a new file instead of overwriting the last one."
  (decklet-test--with-temp-db
    (let ((stamps '("20260101T000001Z" "20260101T000002Z" "20260101T000003Z")))
      (cl-letf (((symbol-function 'decklet-backup--timestamp)
                 (lambda () (pop stamps))))
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

;;; Restore

(ert-deftest decklet-test-backup-restore-errors-with-session-buffers-open ()
  "Restore refuses while a session buffer is open, leaving the DB connected."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (let ((backup-file (expand-file-name "decklet-20260101T010101Z.sqlite" tmp-dir)))
      (decklet-test--touch backup-file "backup")
      (decklet-test--with-temp-buffers (buf)
        (with-current-buffer buf (decklet-db--acquire-session-buffer))
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

(ert-deftest decklet-test-backup-restore-refuses-with-modified-card-back ()
  "Restore refuses while a card back has unsaved edits, leaving the DB as is.
Saving that edit later would write it into the restored database."
  (decklet-test--with-temp-db
    (decklet--add-card "kept")
    (decklet-db--disconnect)
    (let ((backup-file (expand-file-name "decklet-20260101T010101Z.sqlite"
                                         decklet-backup-directory))
          (before (decklet-test--file-string decklet-db-file)))
      (make-directory decklet-backup-directory t)
      (decklet-test--touch backup-file "backup-payload")
      (decklet-test--touch (expand-file-name "review-log-20260101T010101Z.jsonl"
                                             decklet-backup-directory))
      (decklet-test--with-temp-buffers (popup)
        (with-current-buffer popup
          (decklet-card-back-mode 1)
          (insert "unsaved"))
        (cl-letf (((symbol-function 'decklet-backup--backup-files)
                   (lambda () (list backup-file)))
                  ((symbol-function 'decklet-backup--read-backup-choice)
                   (lambda (_choices default) default))
                  ((symbol-function 'yes-or-no-p) (lambda (_p) t)))
          (should-error (decklet-db-restore) :type 'user-error)))
      (should (string= before (decklet-test--file-string decklet-db-file))))))

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

(ert-deftest decklet-test-backup-restore-failure-keeps-current-files ()
  "If the review log cannot be restored, the database is not restored either."
  (decklet-test--with-temp-db
    (let ((db-backup (expand-file-name "db-backup" tmp-dir)))
      (decklet-test--touch decklet-db-file "current-db")
      (decklet-test--touch decklet-review-log-file "current-log")
      (decklet-test--touch db-backup "backup-db")
      (should-error (decklet-backup--replace-db-and-log
                     db-backup (expand-file-name "no-such-log" tmp-dir))
                    :type 'file-missing)
      (should (string= "current-db" (decklet-test--file-string decklet-db-file)))
      (should (string= "current-log"
                       (decklet-test--file-string decklet-review-log-file))))))

(provide 'decklet-backup-test)
;;; decklet-backup-test.el ends here

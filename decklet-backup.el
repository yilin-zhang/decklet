;;; decklet-backup.el --- Backup and restore for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yilin Zhang

;;; Commentary:

;; Paired database and review-log backup, pruning, and restore support.

;;; Code:


(require 'decklet-core)
(require 'decklet-db)
(require 'decklet-review-log)

;; Backups

(defcustom decklet-backup-directory
  (expand-file-name "backups" decklet-directory)
  "Directory for Decklet database backups."
  :type 'file
  :group 'decklet-db)

(defcustom decklet-backup-automatic t
  "Whether Decklet backs up the database around review and edit sessions.
When non-nil, `decklet-db-backup' runs from the review and edit
start and quit hooks, so every session begins and ends with a current
snapshot pair.  Set to nil to back up only by hand."
  :type 'boolean
  :group 'decklet-db)

(defcustom decklet-backup-prune-max-count 20
  "Maximum number of backups to retain.
When the count exceeds this, oldest backups are deleted silently.
Set to nil to disable pruning."
  :type '(choice (const :tag "Disabled" nil) integer)
  :group 'decklet-db)

(defconst decklet-backup--backup-timestamp-re "[0-9]\\{8\\}T[0-9]\\{6\\}Z"
  "Regex matching the UTC timestamp produced by `decklet--timestamp-utc'.")

(defun decklet-backup--backup-file-pattern (base ext)
  "Return a regexp matching timestamped backup files for BASE.EXT."
  (format "\\`%s-\\(%s\\)\\.%s\\'"
          (regexp-quote base)
          decklet-backup--backup-timestamp-re
          (regexp-quote ext)))

(defun decklet-backup--backup-name (base ext timestamp)
  "Return the backup file name for BASE.EXT at TIMESTAMP."
  (format "%s-%s.%s" base timestamp ext))

(defun decklet-backup--backup-token (file base ext)
  "Return FILE's timestamp token for BASE.EXT, or nil."
  (let ((name (file-name-nondirectory file))
        (pattern (decklet-backup--backup-file-pattern base ext)))
    (when (string-match pattern name)
      (match-string 1 name))))

(defun decklet-backup--backup ()
  "Create a paired database/review-log backup and prune old backup pairs.
A second backup within the same second overwrites the first; both
are snapshots of the same state."
  (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
         (base (file-name-base decklet-db-file))
         (timestamp (decklet--timestamp-utc))
         (backup-file (expand-file-name
                       (decklet-backup--backup-name base "sqlite" timestamp)
                       backup-dir))
         (log-backup (expand-file-name
                      (decklet-backup--backup-name
                       (file-name-base decklet-review-log-file)
                       (file-name-extension decklet-review-log-file)
                       timestamp)
                      backup-dir))
         (created nil))
    (make-directory backup-dir t)
    (condition-case err
        (progn
          ;; Track only files this attempt creates, so the error
          ;; cleanup never deletes a backup that already existed
          ;; (e.g. the same-second pair being overwritten).
          (unless (file-exists-p backup-file)
            (push backup-file created))
          (copy-file decklet-db-file backup-file t t t)
          (unless (file-exists-p log-backup)
            (push log-backup created))
          (if (file-exists-p decklet-review-log-file)
              (copy-file decklet-review-log-file log-backup t t t)
            (let ((coding-system-for-write 'utf-8-unix))
              (with-temp-file log-backup))))
      (error
       (dolist (file created)
         (when (file-exists-p file)
           (delete-file file)))
       (signal (car err) (cdr err))))
    (decklet-backup--prune-pairs)))

(defun decklet-backup--matching-review-log-backup (database-backup)
  "Return the review-log backup paired with DATABASE-BACKUP, or nil."
  (let* ((token (decklet-backup--backup-token
                 database-backup (file-name-base decklet-db-file) "sqlite"))
         (log-base (file-name-base decklet-review-log-file))
         (log-ext (file-name-extension decklet-review-log-file))
         (candidate (and token
                         (expand-file-name
                          (format "%s-%s.%s" log-base token log-ext)
                          decklet-backup-directory))))
    (and candidate (file-exists-p candidate) candidate)))

(defun decklet-backup--prune-pairs ()
  "Prune old database backups and their matching review-log backups."
  (when (and (integerp decklet-backup-prune-max-count)
             (> decklet-backup-prune-max-count 0))
    (dolist (database-backup
             (nthcdr decklet-backup-prune-max-count
                     (decklet-backup--backup-files)))
      (let ((review-log-backup
             (decklet-backup--matching-review-log-backup database-backup)))
        (condition-case err
            (progn
              (when review-log-backup
                (delete-file review-log-backup))
              (delete-file database-backup))
          (error
           (message "Decklet: backup pair prune failed for %s: %s"
                    (abbreviate-file-name database-backup)
                    (error-message-string err))))))))

(defun decklet-backup--temp-file-beside (file)
  "Create an empty temporary file in FILE's directory and return its name."
  (let ((dir (file-name-directory (expand-file-name file))))
    (make-directory dir t)
    (make-temp-file (expand-file-name ".decklet-restore-" dir))))

(defun decklet-backup--replace-db-and-log (db-backup log-backup)
  "Replace the database and review log with DB-BACKUP and LOG-BACKUP.
If either copy fails, neither file is changed."
  (let ((db-tmp (decklet-backup--temp-file-beside decklet-db-file))
        (log-tmp (decklet-backup--temp-file-beside decklet-review-log-file)))
    (unwind-protect
        (progn
          ;; Keeping the mtime lets `decklet-db-backup' skip backing up
          ;; a database that was just restored.
          (copy-file db-backup db-tmp 'overwrite 'keep-time)
          (copy-file log-backup log-tmp 'overwrite 'keep-time)
          (rename-file db-tmp decklet-db-file 'overwrite)
          (rename-file log-tmp decklet-review-log-file 'overwrite))
      (delete-file db-tmp)
      (delete-file log-tmp))))

(defun decklet-backup--backup-files ()
  "Return backup files sorted by newest first.
Filenames embed a UTC timestamp, so lexicographic order is
chronological order."
  (let ((backup-dir (file-name-as-directory decklet-backup-directory))
        (pattern (decklet-backup--backup-file-pattern
                  (file-name-base decklet-db-file) "sqlite")))
    (when (file-directory-p backup-dir)
      (sort (directory-files backup-dir t pattern) #'string>))))

(defun decklet-backup--read-backup-choice (choices default)
  "Read backup choice from CHOICES with DEFAULT using completion.
CHOICES arrive newest-first; `display-sort-function' metadata keeps
the completion UI from re-sorting them."
  (let ((table (lambda (string pred action)
                 (if (eq action 'metadata)
                     '(metadata (display-sort-function . identity)
                                (cycle-sort-function . identity))
                   (complete-with-action action choices string pred)))))
    (completing-read "Restore backup: " table nil t nil nil default)))

;;;###autoload
(defun decklet-db-backup ()
  "Create a database backup if the DB has changed since the last backup."
  (interactive)
  (if (not (file-exists-p decklet-db-file))
      (when (called-interactively-p 'any)
        (message "No database file found; skipping backup"))
    (let* ((attrs (file-attributes decklet-db-file))
           (mtime (file-attribute-modification-time attrs))
           (latest-backup (car (decklet-backup--backup-files)))
           (latest-mtime (when latest-backup
                           (file-attribute-modification-time
                            (file-attributes latest-backup)))))
      (if (and (equal mtime latest-mtime)
               (decklet-backup--matching-review-log-backup latest-backup))
          (when (called-interactively-p 'any)
            (message "Backup not needed; database unchanged"))
        (decklet-backup--backup)
        (when (called-interactively-p 'any)
          (message "Backup created"))))))

(defun decklet-backup-session ()
  "Back up the database when `decklet-backup-automatic' is non-nil.
Registered by the review and edit modules on their session hooks."
  (when decklet-backup-automatic
    (decklet-db-backup)))

;;;###autoload
(defun decklet-db-restore ()
  "Restore the database from a selected backup file."
  (interactive)
  (let* ((files (decklet-backup--backup-files)))
    (unless files
      (user-error "No backups found in %s" decklet-backup-directory))
    (let* ((choices (mapcar (lambda (file)
                              (cons (format-time-string
                                     "%Y-%m-%d %H:%M:%S"
                                     (file-attribute-modification-time
                                      (file-attributes file)))
                                    file))
                            files))
           (default (caar choices))
           (selection (decklet-backup--read-backup-choice choices default))
           (backup-file (cdr (assoc selection choices)))
           (review-log-backup
            (and backup-file
                 (decklet-backup--matching-review-log-backup backup-file))))
      (unless backup-file
        (user-error "No backup selected"))
      (unless review-log-backup
        (user-error "The selected database backup has no matching review log"))
      (when (decklet-db--session-buffers)
        (user-error
         "Please disconnect Decklet before restore; use `decklet-disconnect'"))
      (when (yes-or-no-p (format "Restore %s to %s? "
                                 (file-name-nondirectory backup-file)
                                 decklet-db-file))
        ;; Replacing the DB file is only unsafe when a live SQLite connection
        ;; still holds the file handle.  If no session buffers are open, we
        ;; can drop the handle internally and proceed.
        (when decklet-db--conn
          (decklet-db--disconnect))
        (decklet-backup--replace-db-and-log backup-file review-log-backup)
        (message "Restored database and review log from %s"
                 (file-name-nondirectory backup-file))))))


(provide 'decklet-backup)
;;; decklet-backup.el ends here

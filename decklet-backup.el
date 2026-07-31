;;; decklet-backup.el --- Backup and restore for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Paired database and review-log backup, pruning, and restore support.

;;; Code:

(require 'cl-lib)

(require 'decklet-core)
(require 'decklet-db)
(require 'decklet-review-log)

;; Backups

(defvar decklet-db-post-backup-functions nil
  "Abnormal hook called after a successful database backup.
Each function is called with two arguments: BACKUP-DIR and TIMESTAMP.
Intended for modules that want to back up auxiliary files such as the
review log JSONL alongside the DB snapshot.")

(defcustom decklet-backup-directory
  (expand-file-name "backups" decklet-directory)
  "Directory for Decklet database backups."
  :type 'file
  :group 'decklet-db)

(defcustom decklet-backup-prune-max-count 20
  "Maximum number of backups to retain.
When the count exceeds this, oldest backups are deleted silently.
Set to nil to disable pruning."
  :type '(choice (const :tag "Disabled" nil) integer)
  :group 'decklet-db)

(defcustom decklet-backup-restore-completion-setup
  (lambda ()
    '((vertico-sort-override-function . identity)))
  "Function returning temporary completion bindings for backup restore.
When non-nil, it is called with no arguments inside
`decklet-db-restore' and should return an alist of
\(SYMBOL . VALUE) pairs to bind dynamically around `completing-read'."
  :type 'function
  :group 'decklet-db)

(defconst decklet-backup--backup-timestamp-re "[0-9]\\{8\\}T[0-9]\\{6\\}Z"
  "Regex matching the UTC timestamp produced by `decklet--timestamp-utc'.")

(defun decklet-backup--backup-file-pattern (base ext)
  "Return a regexp matching timestamped backup files for BASE.EXT.
Includes an optional collision suffix (e.g. `-1', `-2')."
  (format "\\`%s-\\(%s\\(?:-[0-9]+\\)?\\)\\.%s\\'"
          (regexp-quote base)
          decklet-backup--backup-timestamp-re
          (regexp-quote ext)))

(defun decklet-backup--backup-target (backup-dir base ext timestamp)
  "Return a unique backup filename in BACKUP-DIR using BASE, EXT, TIMESTAMP."
  (let ((suffix 0))
    (cl-loop for candidate = (expand-file-name
                              (format "%s-%s%s.%s"
                                      base
                                      timestamp
                                      (if (zerop suffix) "" (format "-%d" suffix))
                                      ext)
                              backup-dir)
             while (file-exists-p candidate)
             do (cl-incf suffix)
             finally return candidate)))

(defun decklet-backup--backup-prune (backup-dir base ext)
  "Prune old backup files in BACKUP-DIR matching BASE.EXT.
Keeps the newest `decklet-backup-prune-max-count' files and
deletes the rest.  Filenames carry a UTC timestamp, so
lexicographic order matches chronological order."
  (when (and (integerp decklet-backup-prune-max-count)
             (> decklet-backup-prune-max-count 0))
    (let* ((pattern (decklet-backup--backup-file-pattern base ext))
           (files (sort (directory-files backup-dir t pattern) #'string<))
           (to-delete (butlast files decklet-backup-prune-max-count)))
      (dolist (file to-delete)
        (condition-case err
            (delete-file file)
          (error
           (message "Decklet: backup prune failed for %s: %s"
                    (abbreviate-file-name file)
                    (error-message-string err))))))))

(defun decklet-backup--backup ()
  "Create a database backup, fire the post-backup hook, and prune old backups."
  (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
         (base (file-name-base decklet-db-file))
         (timestamp (decklet--timestamp-utc))
         (backup-file (decklet-backup--backup-target backup-dir base "sqlite" timestamp)))
    (make-directory backup-dir t)
    (copy-file decklet-db-file backup-file t t t)
    (decklet-backup--backup-prune backup-dir base "sqlite")
    (decklet-db-backup-auxiliary-file
     decklet-review-log-file backup-dir timestamp)
    (run-hook-with-args 'decklet-db-post-backup-functions backup-dir timestamp)))

(defun decklet-db-backup-auxiliary-file (source-file backup-dir timestamp)
  "Copy SOURCE-FILE to BACKUP-DIR as a timestamped backup and prune old copies.
Uses the same retention policy as the main DB backup.  The backup
name is derived from SOURCE-FILE's base name and extension plus
TIMESTAMP.  No-op when SOURCE-FILE does not exist.

Intended for modules that maintain files alongside the DB and want
their backups to ride in the same rotation; register a handler on
`decklet-db-post-backup-functions' and call this from it."
  (when (file-exists-p source-file)
    (let* ((base (file-name-base source-file))
           (ext (file-name-extension source-file))
           (target (decklet-backup--backup-target backup-dir base ext timestamp)))
      (copy-file source-file target t t t)
      (decklet-backup--backup-prune backup-dir base ext))))

(defun decklet-backup--backup-timestamp (file)
  "Return the backup timestamp for FILE, or nil if unavailable."
  (let ((pattern (format "\\`%s-\\(%s\\)"
                         (regexp-quote (file-name-base decklet-db-file))
                         decklet-backup--backup-timestamp-re))
        (filename (file-name-base file)))
    (when (string-match pattern filename)
      (condition-case nil
          (date-to-time (match-string 1 filename))
        (error nil)))))

(defun decklet-backup--matching-review-log-backup (database-backup)
  "Return the review-log backup paired with DATABASE-BACKUP, or nil."
  (let* ((pattern (decklet-backup--backup-file-pattern
                   (file-name-base decklet-db-file) "sqlite"))
         (name (file-name-nondirectory database-backup))
         (token (and (string-match pattern name) (match-string 1 name)))
         (log-base (file-name-base decklet-review-log-file))
         (log-ext (file-name-extension decklet-review-log-file))
         (candidate (and token
                         (expand-file-name
                          (format "%s-%s.%s" log-base token log-ext)
                          decklet-backup-directory))))
    (and candidate (file-exists-p candidate) candidate)))

(defun decklet-backup--restore-file-pairs (pairs)
  "Restore source/target PAIRS, rolling back all targets on failure."
  (let ((saved nil))
    (unwind-protect
        (condition-case err
            (progn
              (dolist (pair pairs)
                (pcase-let* ((`(,_source ,target) pair)
                             (target-dir (file-name-directory target)))
                  (when target-dir
                    (make-directory target-dir t))
                  (if (file-exists-p target)
                      (let ((copy (make-temp-file
                                   (expand-file-name ".decklet-restore-"
                                                     target-dir))))
                        (copy-file target copy t t t)
                        (push (cons target copy) saved))
                    (push (cons target nil) saved))))
              (dolist (pair pairs)
                (copy-file (car pair) (cadr pair) t t t)))
          (error
           (dolist (entry saved)
             (if (cdr entry)
                 (copy-file (cdr entry) (car entry) t t t)
               (when (file-exists-p (car entry))
                 (delete-file (car entry)))))
           (signal (car err) (cdr err))))
      (dolist (entry saved)
        (when (and (cdr entry) (file-exists-p (cdr entry)))
          (delete-file (cdr entry)))))))

(defun decklet-backup--backup-files ()
  "Return backup files sorted by newest timestamp first."
  (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
         (base (file-name-base decklet-db-file))
         (pattern (decklet-backup--backup-file-pattern base "sqlite"))
         (files (when (file-directory-p backup-dir)
                  (directory-files backup-dir t pattern))))
    (sort files
          (lambda (a b)
            (let ((ta (or (decklet-backup--backup-timestamp a)
                          (file-attribute-modification-time (file-attributes a))))
                  (tb (or (decklet-backup--backup-timestamp b)
                          (file-attribute-modification-time (file-attributes b)))))
              (time-less-p tb ta))))))

(defun decklet-backup--read-backup-choice (choices default)
  "Read backup choice from CHOICES with DEFAULT using completion."
  (let* ((bindings (when (functionp decklet-backup-restore-completion-setup)
                     (funcall decklet-backup-restore-completion-setup)))
         (symbols (mapcar #'car bindings))
         (values (mapcar #'cdr bindings)))
    (cl-progv symbols values
      (completing-read "Restore backup: " choices nil t nil nil default))))

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
      (if (equal mtime latest-mtime)
          (when (called-interactively-p 'any)
            (message "Backup not needed; database unchanged"))
        (decklet-backup--backup)
        (when (called-interactively-p 'any)
          (message "Backup created"))))))

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
      (when (decklet-db--session-buffer-live-p)
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
        (decklet-backup--restore-file-pairs
         (list (list backup-file decklet-db-file)
               (list review-log-backup decklet-review-log-file)))
        (message "Restored database and review log from %s"
                 (file-name-nondirectory backup-file))))))


(provide 'decklet-backup)
;;; decklet-backup.el ends here

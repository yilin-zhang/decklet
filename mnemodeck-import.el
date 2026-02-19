;;; mnemodeck-import.el --- E-reader import for MnemoDeck -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Kindle and Kobo vocabulary import.

;;; Code:

(require 'seq)
(require 'subr-x)

(require 'mnemodeck-deck)

(defgroup mnemodeck-import nil
  "E-reader vocabulary import for MnemoDeck."
  :group 'mnemodeck)

(defcustom mnemodeck-import-sqlite-command "sqlite3"
  "SQLite command used for e-reader vocab extraction."
  :type 'string
  :group 'mnemodeck-import)

(defvar mnemodeck-import-kindle-buffer-name "*MnemoDeck Import Kindle*"
  "Buffer name for Kindle vocab import.")

(defvar mnemodeck-import-kobo-buffer-name "*MnemoDeck Import Kobo*"
  "Buffer name for Kobo vocab import.")

(defun mnemodeck-import--ensure-sqlite ()
  "Ensure sqlite command is available."
  (unless (executable-find mnemodeck-import-sqlite-command)
    (error "%s command not found.  Please install SQLite3" mnemodeck-import-sqlite-command)))

(defun mnemodeck-import--sqlite-call (db-file sql context)
  "Run SQL against DB-FILE and return command output.
CONTEXT is used as the error message prefix when command execution fails."
  (with-temp-buffer
    (unless (zerop (call-process mnemodeck-import-sqlite-command nil t nil db-file sql))
      (error "%s: %s" context (string-trim (buffer-string))))
    (buffer-string)))

(defun mnemodeck-import-kindle--read-words (db-file)
  "Return a list of unique words from Kindle DB-FILE."
  ;; Use stems instead of words in their original forms.
  (split-string (mnemodeck-import--sqlite-call
                 db-file
                 "SELECT stem FROM WORDS ORDER BY rowid;"
                 "Failed to query database")
                "\n" t))

(defun mnemodeck-import-kindle--maybe-clear-db (db-file)
  "Prompt to clear DB-FILE after a successful import."
  (when (yes-or-no-p (format "Clear all data from %s? "
                             (file-name-nondirectory db-file)))
    (mnemodeck-import--sqlite-call
     db-file
     "DELETE FROM LOOKUPS; DELETE FROM WORDS; DELETE FROM BOOK_INFO; VACUUM;"
     "Failed to clear database")
    (message "Database cleared successfully")))

(defun mnemodeck-import-kobo--normalize-word (word)
  "Normalize WORD captured by Kobo."
  ;; Sometimes Kobo doesn't remove the trailing comma.
  (if (string-suffix-p "," word)
      (substring word 0 -1)
    word))

(defun mnemodeck-import-kobo--read-words (db-file)
  "Return a list of unique normalized words from Kobo DB-FILE."
  ;; We need to deduplicate after normalization
  (seq-uniq
   (mapcar #'mnemodeck-import-kobo--normalize-word
           (split-string (mnemodeck-import--sqlite-call
                          db-file
                          "SELECT Text FROM WordList ORDER BY rowid;"
                          "Failed to query database")
                         "\n" t))))

(defun mnemodeck-import-kobo--maybe-clear-db (db-file)
  "Prompt to clear imported word rows from Kobo DB-FILE."
  (when (yes-or-no-p (format "Clear all words from %s? "
                             (file-name-nondirectory db-file)))
    (mnemodeck-import--sqlite-call
     db-file
     "DELETE FROM WordList; VACUUM;"
     "Failed to clear database")
    (message "WordList cleared successfully")))

;;;###autoload
(defun mnemodeck-import-kindle (db-file)
  "Extract words from Kindle vocab DB-FILE and open a batch add buffer."
  (interactive "fKindle vocab.db file: ")
  (setq db-file (expand-file-name db-file))
  (unless (file-exists-p db-file)
    (error "Database file does not exist: %s" db-file))
  (mnemodeck-import--ensure-sqlite)
  (let* ((words (mnemodeck-import-kindle--read-words db-file))
         (message-prefix (format "Extracted %d unique words." (length words))))
    (mnemodeck-add-card-batch
     words
     :buffer-name mnemodeck-import-kindle-buffer-name
     :title "MnemoDeck Kindle Vocab Import"
     :message-prefix message-prefix
     :on-confirm (lambda (_words)
                   (mnemodeck-import-kindle--maybe-clear-db db-file)))))

;;;###autoload
(defun mnemodeck-import-kobo (db-file)
  "Extract words from KoboReader DB-FILE and open a batch add buffer."
  (interactive "fKoboReader.sqlite file: ")
  (setq db-file (expand-file-name db-file))
  (unless (file-exists-p db-file)
    (error "Database file does not exist: %s" db-file))
  (mnemodeck-import--ensure-sqlite)
  (let* ((words (mnemodeck-import-kobo--read-words db-file))
         (message-prefix (format "Extracted %d unique words." (length words))))
    (mnemodeck-add-card-batch
     words
     :buffer-name mnemodeck-import-kobo-buffer-name
     :title "MnemoDeck Kobo Vocab Import"
     :message-prefix message-prefix
     :on-confirm (lambda (_words)
                   (mnemodeck-import-kobo--maybe-clear-db db-file)))))

(provide 'mnemodeck-import)
;;; mnemodeck-import.el ends here

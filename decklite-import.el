;;; decklite-import.el --- E-reader import for DeckLite -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Kindle and Kobo vocabulary import.

;;; Code:

(require 'seq)
(require 'subr-x)

(require 'decklite-deck)

(defgroup decklite-import nil
  "E-reader vocabulary import for DeckLite."
  :group 'decklite)

(defcustom decklite-import-sqlite-command "sqlite3"
  "SQLite command used for e-reader vocab extraction."
  :type 'string
  :group 'decklite-import)

(defvar decklite-import-kindle-buffer-name "*DeckLite Import Kindle*"
  "Buffer name for Kindle vocab import.")

(defvar decklite-import-kobo-buffer-name "*DeckLite Import Kobo*"
  "Buffer name for Kobo vocab import.")

(defun decklite-import--ensure-sqlite ()
  "Ensure sqlite command is available."
  (unless (executable-find decklite-import-sqlite-command)
    (error "%s command not found.  Please install SQLite3" decklite-import-sqlite-command)))

(defun decklite-import--sqlite-call (db-file sql context)
  "Run SQL against DB-FILE and return command output.
CONTEXT is used as the error message prefix when command execution fails."
  (with-temp-buffer
    (unless (zerop (call-process decklite-import-sqlite-command nil t nil db-file sql))
      (error "%s: %s" context (string-trim (buffer-string))))
    (buffer-string)))

(defun decklite-import-kindle--read-words (db-file)
  "Return a list of unique words from Kindle DB-FILE."
  ;; Use stems instead of words in their original forms.
  (split-string (decklite-import--sqlite-call
                 db-file
                 "SELECT stem FROM WORDS ORDER BY rowid;"
                 "Failed to query database")
                "\n" t))

(defun decklite-import-kindle--maybe-clear-db (db-file)
  "Prompt to clear DB-FILE after a successful import."
  (when (yes-or-no-p (format "Clear all data from %s? "
                             (file-name-nondirectory db-file)))
    (decklite-import--sqlite-call
     db-file
     "DELETE FROM LOOKUPS; DELETE FROM WORDS; DELETE FROM BOOK_INFO; VACUUM;"
     "Failed to clear database")
    (message "Database cleared successfully")))

(defun decklite-import-kobo--normalize-word (word)
  "Normalize WORD captured by Kobo."
  ;; Sometimes Kobo doesn't remove the trailing comma.
  (if (string-suffix-p "," word)
      (substring word 0 -1)
    word))

(defun decklite-import-kobo--read-words (db-file)
  "Return a list of unique normalized words from Kobo DB-FILE."
  ;; We need to deduplicate after normalization
  (seq-uniq
   (mapcar #'decklite-import-kobo--normalize-word
           (split-string (decklite-import--sqlite-call
                          db-file
                          "SELECT Text FROM WordList ORDER BY rowid;"
                          "Failed to query database")
                         "\n" t))))

(defun decklite-import-kobo--maybe-clear-db (db-file)
  "Prompt to clear imported word rows from Kobo DB-FILE."
  (when (yes-or-no-p (format "Clear all words from %s? "
                             (file-name-nondirectory db-file)))
    (decklite-import--sqlite-call
     db-file
     "DELETE FROM WordList; VACUUM;"
     "Failed to clear database")
    (message "WordList cleared successfully")))

;;;###autoload
(defun decklite-import-kindle (db-file)
  "Extract words from Kindle vocab DB-FILE and open a batch add buffer."
  (interactive "fKindle vocab.db file: ")
  (setq db-file (expand-file-name db-file))
  (unless (file-exists-p db-file)
    (error "Database file does not exist: %s" db-file))
  (decklite-import--ensure-sqlite)
  (let* ((words (decklite-import-kindle--read-words db-file))
         (message-prefix (format "Extracted %d unique words." (length words))))
    (decklite-add-card-batch
     words
     :buffer-name decklite-import-kindle-buffer-name
     :title "DeckLite Kindle Vocab Import"
     :message-prefix message-prefix
     :on-confirm (lambda (_words)
                   (decklite-import-kindle--maybe-clear-db db-file)))))

;;;###autoload
(defun decklite-import-kobo (db-file)
  "Extract words from KoboReader DB-FILE and open a batch add buffer."
  (interactive "fKoboReader.sqlite file: ")
  (setq db-file (expand-file-name db-file))
  (unless (file-exists-p db-file)
    (error "Database file does not exist: %s" db-file))
  (decklite-import--ensure-sqlite)
  (let* ((words (decklite-import-kobo--read-words db-file))
         (message-prefix (format "Extracted %d unique words." (length words))))
    (decklite-add-card-batch
     words
     :buffer-name decklite-import-kobo-buffer-name
     :title "DeckLite Kobo Vocab Import"
     :message-prefix message-prefix
     :on-confirm (lambda (_words)
                   (decklite-import-kobo--maybe-clear-db db-file)))))

(provide 'decklite-import)
;;; decklite-import.el ends here

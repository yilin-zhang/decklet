;;; decklet-import.el --- E-reader import for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Kindle and Kobo vocabulary import.

;;; Code:

(require 'seq)
(require 'subr-x)

(require 'decklet-deck)

(defgroup decklet-import nil
  "E-reader vocabulary import for Decklet."
  :group 'decklet)

(defcustom decklet-import-sqlite-command "sqlite3"
  "SQLite command used for e-reader vocab extraction."
  :type 'string
  :group 'decklet-import)

(defvar decklet-import-kindle-buffer-name "*Decklet Import Kindle*"
  "Buffer name for Kindle vocab import.")

(defvar decklet-import-kobo-buffer-name "*Decklet Import Kobo*"
  "Buffer name for Kobo vocab import.")

(defun decklet-import--ensure-sqlite ()
  "Ensure sqlite command is available."
  (unless (executable-find decklet-import-sqlite-command)
    (error "%s command not found.  Please install SQLite3" decklet-import-sqlite-command)))

(defun decklet-import--sqlite-call (db-file sql context)
  "Run SQL against DB-FILE and return command output.
CONTEXT is used as the error message prefix when command execution fails."
  (with-temp-buffer
    (unless (zerop (call-process decklet-import-sqlite-command nil t nil db-file sql))
      (error "%s: %s" context (string-trim (buffer-string))))
    (buffer-string)))

(defun decklet-import-kindle--read-words (db-file)
  "Return a list of unique words from Kindle DB-FILE."
  ;; Use stems instead of words in their original forms.
  (split-string (decklet-import--sqlite-call
                 db-file
                 "SELECT stem FROM WORDS ORDER BY rowid;"
                 "Failed to query database")
                "\n" t))

(defun decklet-import-kindle--maybe-clear-db (db-file)
  "Prompt to clear DB-FILE after a successful import."
  (when (yes-or-no-p (format "Clear all data from %s? "
                             (file-name-nondirectory db-file)))
    (decklet-import--sqlite-call
     db-file
     "DELETE FROM LOOKUPS; DELETE FROM WORDS; DELETE FROM BOOK_INFO; VACUUM;"
     "Failed to clear database")
    (message "Database cleared successfully")))

(defun decklet-import-kobo--normalize-word (word)
  "Normalize WORD captured by Kobo."
  ;; Sometimes Kobo doesn't remove the trailing comma.
  (if (string-suffix-p "," word)
      (substring word 0 -1)
    word))

(defun decklet-import-kobo--read-words (db-file)
  "Return a list of unique normalized words from Kobo DB-FILE."
  ;; We need to deduplicate after normalization
  (seq-uniq
   (mapcar #'decklet-import-kobo--normalize-word
           (split-string (decklet-import--sqlite-call
                          db-file
                          "SELECT Text FROM WordList ORDER BY rowid;"
                          "Failed to query database")
                         "\n" t))))

(defun decklet-import-kobo--maybe-clear-db (db-file)
  "Prompt to clear imported word rows from Kobo DB-FILE."
  (when (yes-or-no-p (format "Clear all words from %s? "
                             (file-name-nondirectory db-file)))
    (decklet-import--sqlite-call
     db-file
     "DELETE FROM WordList; VACUUM;"
     "Failed to clear database")
    (message "WordList cleared successfully")))

;;;###autoload
(defun decklet-import-kindle (db-file)
  "Extract words from Kindle vocab DB-FILE and open a batch add buffer."
  (interactive "fKindle vocab.db file: ")
  (setq db-file (expand-file-name db-file))
  (unless (file-exists-p db-file)
    (error "Database file does not exist: %s" db-file))
  (decklet-import--ensure-sqlite)
  (let* ((words (decklet-import-kindle--read-words db-file))
         (message-prefix (format "Extracted %d unique words." (length words))))
    (decklet-add-card-batch
     words
     :buffer-name decklet-import-kindle-buffer-name
     :title "Decklet Kindle Vocab Import"
     :message-prefix message-prefix
     :on-confirm (lambda (_words)
                   (decklet-import-kindle--maybe-clear-db db-file)))))

;;;###autoload
(defun decklet-import-kobo (db-file)
  "Extract words from KoboReader DB-FILE and open a batch add buffer."
  (interactive "fKoboReader.sqlite file: ")
  (setq db-file (expand-file-name db-file))
  (unless (file-exists-p db-file)
    (error "Database file does not exist: %s" db-file))
  (decklet-import--ensure-sqlite)
  (let* ((words (decklet-import-kobo--read-words db-file))
         (message-prefix (format "Extracted %d unique words." (length words))))
    (decklet-add-card-batch
     words
     :buffer-name decklet-import-kobo-buffer-name
     :title "Decklet Kobo Vocab Import"
     :message-prefix message-prefix
     :on-confirm (lambda (_words)
                   (decklet-import-kobo--maybe-clear-db db-file)))))

(provide 'decklet-import)
;;; decklet-import.el ends here

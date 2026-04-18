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

(defcustom decklet-import-kindle-usage t
  "When non-nil, import Kindle usage examples as hints.
Usage lines are inserted into batch import buffers as lines starting with
`#', one line per usage example."
  :type 'boolean
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

(defun decklet-import-kindle--highlight-usage-word (usage word)
  "Wrap each occurrence of WORD in USAGE with asterisks.
Matching uses word boundaries.  If WORD is all lowercase, matching is
case-insensitive; otherwise matching is exact case-sensitive."
  (let ((case-fold-search (let ((case-fold-search nil))
                            (not (string-match-p "[[:upper:]]" word))))
        (pattern (format "\\b%s\\b" (regexp-quote word))))
    (replace-regexp-in-string pattern "*\\&*" usage t nil)))

(defun decklet-import-kindle--read-rows (db-file)
  "Return Kindle rows as (STEM WORD USAGE) lists from DB-FILE.
Each row comes from a LEFT JOIN between WORDS and LOOKUPS."
  (let* ((sql
          (concat
           "SELECT "
           "ifnull(WORDS.stem, '') || char(31) || "
           "ifnull(WORDS.word, '') || char(31) || "
           "replace(ifnull(LOOKUPS.usage, ''), char(10), ' ') "
           "FROM WORDS "
           "LEFT JOIN LOOKUPS ON LOOKUPS.word_key = WORDS.id "
           "ORDER BY WORDS.rowid, LOOKUPS.rowid;"))
         (raw (decklet-import--sqlite-call db-file sql "Failed to query database")))
    (mapcar (lambda (line)
              (let ((parts (split-string line "\\(?:\x1f\\|\\^_\\)" nil)))
                (list (string-trim (nth 0 parts))
                      (string-trim (nth 1 parts))
                      (string-trim (string-join (nthcdr 2 parts) "")))))
            (split-string raw "\n" t))))

(defun decklet-import-kindle--rows->batch-lines (rows)
  "Build batch buffer lines from Kindle ROWS.
ROWS should be a list of (STEM WORD USAGE)."
  ;; Keep order stable: first seen stem decides block position.
  (let (groups-rev)
    (dolist (row rows)
      (pcase-let* ((`(,stem ,word ,usage) row)
                   (hint (and decklet-import-kindle-usage
                              (decklet-import-kindle--highlight-usage-word usage word)))
                   (cell (assoc stem groups-rev)))
        (unless cell
          (setq cell (cons stem nil))
          (push cell groups-rev))
        (when (and hint (not (member hint (cdr cell))))
          (setcdr cell (cons hint (cdr cell))))))
    (let (lines)
      (dolist (cell (nreverse groups-rev))
        (push (car cell) lines)
        (dolist (hint (nreverse (cdr cell)))
          (push (concat "# " hint) lines)))
      (nreverse lines))))

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
    (user-error "Database file does not exist: %s" db-file))
  (decklet-import--ensure-sqlite)
  (let* ((lines (decklet-import-kindle--rows->batch-lines
                 (decklet-import-kindle--read-rows db-file)))
         (word-count (seq-count (lambda (line) (not (string-prefix-p "#" line))) lines))
         (message-prefix (format "Extracted %d unique words." word-count)))
    (decklet-add-card-batch
     lines
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
    (user-error "Database file does not exist: %s" db-file))
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

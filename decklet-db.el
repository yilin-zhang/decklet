;;; decklet-db.el --- Database layer for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yilin Zhang

;;; Commentary:

;; SQLite connection management and card queries.

;;; Code:

(require 'map)
(require 'seq)
(require 'sqlite)
(require 'subr-x)

(require 'decklet-core)
(require 'decklet-scheduler)

(defgroup decklet-db nil
  "Database for Decklet."
  :group 'decklet)

(defcustom decklet-db-file
  (expand-file-name "decklet.sqlite" decklet-directory)
  "Path to the SQLite database file."
  :type 'file
  :group 'decklet-db)


(defvar decklet-db--conn nil
  "SQLite connection for Decklet.")

(defvar decklet-db--in-operation nil
  "Non-nil while an outer `decklet-with-db' owns the DB connection lifetime.")

(defvar decklet-db--last-card-id nil
  "Last minted card id, seeded from `MAX(card_id)' on first use.")

(defvar decklet-db-pre-connect-hook nil
  "Hook run before the SQLite connection is opened.
A function can refuse the connection by signaling an error, usually a
`user-error', which reaches the command that needed the database.")

(defvar decklet-db-pre-disconnect-hook nil
  "Hook run immediately before the SQLite connection is closed.
Use this to clean up what lives as long as the connection, such as
sidecar processes or caches.")

(defvar-local decklet-db--session-buffer nil
  "Non-nil in the review and edit buffers, which hold the Decklet session.
The DB connection stays open while any of them lives.")

(defconst decklet-db--card-columns
  "card_id, word, hint, back, added_date, last_review, due, state, step, stability, difficulty, tags"
  "Column list shared by card SELECTs that feed `decklet-db--normalize-row'.
Column order must match `decklet-db--normalize-row's `pcase-let'.")

(defun decklet-db--normalize-row (row)
  "Turn ROW, selected with `decklet-db--card-columns', into a card plist.
Text is normalized when written, so it is taken as stored."
  (when row
    (pcase-let ((`(,card-id ,word ,hint ,back ,added ,last-review ,due ,state ,step ,stability ,difficulty ,tags) row))
      (list :card-id card-id
            :word word
            :hint hint
            :back back
            :added added
            :last-review last-review
            :due due
            :state state
            :step step
            :stability stability
            :difficulty difficulty
            :tags (json-parse-string tags :array-type 'list)))))

(defun decklet-db--ensure ()
  "Ensure SQLite connection and schema are initialized."
  (unless decklet-db--conn
    (run-hooks 'decklet-db-pre-connect-hook)
    (when-let* ((dir (file-name-directory decklet-db-file)))
      (make-directory dir t))
    (setq decklet-db--conn (sqlite-open decklet-db-file))
    (sqlite-execute decklet-db--conn "PRAGMA journal_mode = TRUNCATE;")
    (sqlite-execute decklet-db--conn "PRAGMA foreign_keys = ON;")
    (sqlite-execute decklet-db--conn
                    "CREATE TABLE IF NOT EXISTS cards (
                       card_id     INTEGER PRIMARY KEY,
                       word        TEXT    UNIQUE NOT NULL,
                       hint        TEXT,
                       back        TEXT,
                       added_date  TEXT    NOT NULL,
                       last_review TEXT,
                       due         TEXT    NOT NULL,
                       archived_at TEXT,
                       state       TEXT    NOT NULL,
                       step        INTEGER,
                       stability   REAL,
                       difficulty  REAL,
                       tags        TEXT    NOT NULL DEFAULT '[]'
                     );")
    ;; `card_id' is the rowid and `word' is UNIQUE, so both are indexed.
    (sqlite-execute decklet-db--conn
                    "CREATE INDEX IF NOT EXISTS idx_cards_due ON cards(due);"))
  decklet-db--conn)

(defun decklet-db--disconnect ()
  "Close the SQLite connection used by Decklet."
  (when decklet-db--conn
    ;; A failing extension must not keep the connection open.
    (decklet-run-hook-isolated 'decklet-db-pre-disconnect-hook)
    (sqlite-close decklet-db--conn)
    (setq decklet-db--conn nil)))

(defun decklet-db--acquire-session-buffer ()
  "Mark the current buffer as holding the Decklet session.
The connection stays open while a session buffer lives, and closes
when the last one is killed."
  (setq-local decklet-db--session-buffer t)
  (add-hook 'kill-buffer-hook #'decklet-db--on-session-buffer-killed nil t))

(defun decklet-db--session-buffers (&optional exclude)
  "Return live Decklet session buffers, ignoring EXCLUDE.
Pass the current buffer from kill hooks, where the dying buffer is
still present in `buffer-list'."
  (seq-filter (lambda (buffer)
                (and (not (eq buffer exclude))
                     (buffer-local-value 'decklet-db--session-buffer buffer)))
              (buffer-list)))

(defun decklet-db--disconnect-if-idle ()
  "Disconnect the DB when no session buffer is open.
Used after one-shot work outside a session, such as loading or saving
a card back, which opens the connection lazily."
  (unless (decklet-db--session-buffers)
    (decklet-db--disconnect)))

(defmacro decklet-with-db (&rest body)
  "Run BODY and disconnect the DB afterward if no session buffer is open.
Nested calls share the connection and disconnect only when the
outermost form exits."
  (declare (indent 0) (debug t))
  (let ((outer (make-symbol "outer")))
    `(let ((,outer (not decklet-db--in-operation))
           (decklet-db--in-operation t))
       (unwind-protect
           (progn ,@body)
         (when ,outer
           (decklet-db--disconnect-if-idle))))))

(defun decklet-db--on-session-buffer-killed ()
  "Disconnect the DB when the last session buffer is killed."
  (unless (decklet-db--session-buffers (current-buffer))
    (decklet-db--disconnect)))

;;;###autoload
(defun decklet-disconnect ()
  "Close the Decklet review and edit buffers, then disconnect the DB."
  (interactive)
  (let ((buffers (decklet-db--session-buffers))
        (had-conn decklet-db--conn))
    (dolist (buffer buffers)
      (unless (kill-buffer buffer)
        (user-error "Decklet disconnect canceled by buffer %s"
                    (buffer-name buffer))))
    (decklet-db--disconnect)
    (when (called-interactively-p 'any)
      (message (if (or buffers had-conn)
                   "Decklet disconnected"
                 "Decklet already disconnected")))))

(defun decklet-db--select-card-row-by-word (word)
  "Return the card row for WORD or nil."
  (let ((conn (decklet-db--ensure)))
    (decklet-db--normalize-row
     (car (sqlite-select conn
                         (format "SELECT %s FROM cards WHERE word = ?;"
                                 decklet-db--card-columns)
                         (list word))))))

(defun decklet-db--select-card-row (card-id)
  "Return the card row for CARD-ID or nil."
  (let ((conn (decklet-db--ensure)))
    (decklet-db--normalize-row
     (car (sqlite-select conn
                         (format "SELECT %s FROM cards WHERE card_id = ?;"
                                 decklet-db--card-columns)
                         (list card-id))))))

(defun decklet-db--card-exists-p (card-id)
  "Return non-nil when CARD-ID has a row, without fetching the row."
  (let ((conn (decklet-db--ensure)))
    (and (sqlite-select conn
                        "SELECT 1 FROM cards WHERE card_id = ? LIMIT 1;"
                        (list card-id))
         t)))

(defun decklet-db--require-card-row (card-id)
  "Return the card row for CARD-ID, or signal a user error."
  (or (decklet-db--select-card-row card-id)
      (user-error "No card found for id %s" card-id)))

(defun decklet-db--select-card-field (card-id field)
  "Return FIELD for CARD-ID, or nil if absent.
FIELD is interpolated into SQL; only `word', `hint', and `back' are accepted."
  (unless (memq field '(word hint back))
    (error "Unsupported card field: %S" field))
  (let ((conn (decklet-db--ensure)))
    (caar (sqlite-select conn
                         (format "SELECT %s FROM cards WHERE card_id = ?;" field)
                         (list card-id)))))

(defun decklet-db--update-card-text-field (card-id field value)
  "Set text FIELD of CARD-ID to VALUE, already normalized by the caller.
FIELD is interpolated into SQL; only `hint' and `back' are accepted."
  (unless (memq field '(hint back))
    (error "Unsupported card text field: %S" field))
  (sqlite-execute (decklet-db--ensure)
                  (format "UPDATE cards SET %s = ? WHERE card_id = ?;" field)
                  (list value card-id)))

(defun decklet-db--set-card-archived-at (card-id archived-at)
  "Set CARD-ID archived_at to ARCHIVED-AT, or nil to unarchive it."
  (let ((conn (decklet-db--ensure)))
    (sqlite-execute conn "UPDATE cards SET archived_at = ? WHERE card_id = ?;"
                    (list archived-at card-id))))

(defun decklet-db--insert-card (word card-meta)
  "Insert WORD, already normalized, with scheduling fields from CARD-META."
  (sqlite-execute
   (decklet-db--ensure)
   "INSERT INTO cards (card_id, word, added_date, last_review, due, state, step, stability, difficulty)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);"
   (list (decklet-card-meta-card-id card-meta)
         word
         (decklet-card-meta-added-date card-meta)
         (decklet-card-meta-last-review card-meta)
         (decklet-card-meta-due card-meta)
         (decklet-fsrs-state-string (decklet-card-meta-state card-meta))
         (decklet-card-meta-step card-meta)
         (decklet-card-meta-stability card-meta)
         (decklet-card-meta-difficulty card-meta))))

(defun decklet-db--update-card-meta (card-id card-meta)
  "Update CARD-ID's scheduling fields from CARD-META.
The row's word, hint, back and tags are left alone."
  (sqlite-execute
   (decklet-db--ensure)
   "UPDATE cards
       SET added_date = ?,
           last_review = ?,
           due = ?,
           state = ?,
           step = ?,
           stability = ?,
           difficulty = ?
     WHERE card_id = ?;"
   (list (decklet-card-meta-added-date card-meta)
         (decklet-card-meta-last-review card-meta)
         (decklet-card-meta-due card-meta)
         (decklet-fsrs-state-string (decklet-card-meta-state card-meta))
         (decklet-card-meta-step card-meta)
         (decklet-card-meta-stability card-meta)
         (decklet-card-meta-difficulty card-meta)
         card-id)))

(defun decklet-db--update-tags (card-id tags)
  "Set CARD-ID's TAGS, already normalized by the caller."
  (sqlite-execute (decklet-db--ensure)
                  "UPDATE cards SET tags = ? WHERE card_id = ?;"
                  (list (json-serialize (vconcat tags)) card-id)))

(defun decklet-db--tag-map ()
  "Return a hash table mapping every existing card id to its current tags."
  (let ((table (make-hash-table :test 'eql)))
    (dolist (row (sqlite-select (decklet-db--ensure)
                                "SELECT card_id, tags FROM cards;"))
      (puthash (car row) (json-parse-string (cadr row) :array-type 'list) table))
    table))

(defun decklet-db--delete-card (card-id)
  "Delete CARD-ID from the database."
  (let ((conn (decklet-db--ensure)))
    (sqlite-execute conn "DELETE FROM cards WHERE card_id = ?;" (list card-id))))

(defun decklet-db--mint-card-id ()
  "Return a fresh unique card id.
Seeds lazily from `MAX(card_id)' in the DB so ids stay monotonic
across Emacs sessions; see `decklet--mint-monotonic-id'."
  (decklet--mint-monotonic-id
   'decklet-db--last-card-id
   (lambda ()
     (caar (sqlite-select
            (decklet-db--ensure)
            "SELECT COALESCE(MAX(card_id), 0) FROM cards;")))))

(defun decklet-db--update-word (card-id new-word)
  "Rename CARD-ID to NEW-WORD, already normalized by the caller."
  (let ((old-word (plist-get (decklet-db--require-card-row card-id) :word)))
    (unless (string-equal old-word new-word)
      (when (decklet-db--select-card-row-by-word new-word)
        (user-error "Word \"%s\" already exists in the deck" new-word))
      (sqlite-execute (decklet-db--ensure)
                      "UPDATE cards SET word = ? WHERE card_id = ?;"
                      (list new-word card-id)))))

(defun decklet-db--filter-sql (filter)
  "Return (SQL . PARAMS) for FILTER."
  (let ((s-review (decklet-fsrs-state-string :review))
        (s-learning (decklet-fsrs-state-string :learning))
        (s-relearning (decklet-fsrs-state-string :relearning)))
    (pcase filter
      ('review
       (list " WHERE archived_at IS NULL AND state = ?" s-review))
      ('learning
       (list " WHERE archived_at IS NULL AND state IN (?, ?)"
             s-learning s-relearning))
      ('archived (list " WHERE archived_at IS NOT NULL"))
      (_ (list " WHERE archived_at IS NULL")))))

(defun decklet-db--select-card-rows (&optional filter)
  "Return cards filtered by FILTER, ordered by word."
  (let ((conn (decklet-db--ensure)))
    (pcase-let ((`(,where . ,params) (decklet-db--filter-sql filter)))
      (mapcar
       #'decklet-db--normalize-row
       (sqlite-select conn
                      (concat (format "SELECT %s FROM cards" decklet-db--card-columns)
                              where
                              " ORDER BY word;")
                      params)))))

(defun decklet-db--row->card-meta (row)
  "Convert card plist ROW into a `decklet-card-meta' instance."
  (when row
    (pcase-let* (((map :card-id :added :last-review :due :state :step :stability :difficulty) row)
                 (state (decklet--normalize-fsrs-state state)))
      (make-decklet-card-meta
       :card-id card-id
       :added-date added
       :last-review last-review
       :due due
       :state state
       :step step
       :stability stability
       :difficulty difficulty))))

(defun decklet-db--row->card (row)
  "Return public card plist converted from ROW."
  (list :card-id (plist-get row :card-id)
        :word (plist-get row :word)
        :hint (plist-get row :hint)
        :back (plist-get row :back)
        :tags (plist-get row :tags)
        :meta (decklet-db--row->card-meta row)))

(defun decklet-db--due-items (now)
  "Return the cards due at NOW as plists, in card-id order.
Each item's :effective-state is an FSRS keyword, or :new for a card
never reviewed."
  ;; Intraday learning/relearning cards come due by the minute;
  ;; interday learning, review and new cards come due by the review day.
  (let* ((now-ts (decklet--now now))
         (day-start (decklet--now (decklet-day-start-time now)))
         (day-end (decklet--now (decklet--next-day-start-time now)))
         (rows (sqlite-select
                (decklet-db--ensure)
                "SELECT card_id, word, due, added_date, last_review,
                        stability, difficulty, state
                   FROM cards
                  WHERE archived_at IS NULL
                    AND ((last_review IS NOT NULL
                          AND state IN (?, ?)
                          AND (due <= ? OR (last_review < ? AND due < ?)))
                         OR (last_review IS NOT NULL
                             AND state = ?
                             AND last_review < ?
                             AND due < ?)
                         OR (last_review IS NULL AND due < ?))
                  ORDER BY card_id;"
                (list (decklet-fsrs-state-string :learning)
                      (decklet-fsrs-state-string :relearning)
                      now-ts day-start day-end
                      (decklet-fsrs-state-string :review) day-start day-end
                      day-end))))
    (mapcar (pcase-lambda (`(,card-id ,word ,due ,added ,last-review
                                      ,stability ,difficulty ,state))
              (list :card-id card-id :word word :due due :added added
                    :last-review last-review :stability stability
                    :difficulty difficulty
                    :effective-state (if last-review
                                         (decklet--normalize-fsrs-state state)
                                       :new)))
            rows)))

(defun decklet-db--next-due-time (&optional time)
  "Return the next due timestamp later in TIME's review day, or nil."
  ;; Only intraday learning/relearning cards can come due later today;
  ;; interday cards are already due for the whole day.
  (let ((now (or time (current-time))))
    (caar (sqlite-select
           (decklet-db--ensure)
           "SELECT MIN(due) FROM cards
             WHERE archived_at IS NULL
               AND last_review IS NOT NULL
               AND last_review >= ?
               AND state IN (?, ?)
               AND due > ?
               AND due < ?;"
           (list (decklet--now (decklet-day-start-time now))
                 (decklet-fsrs-state-string :learning)
                 (decklet-fsrs-state-string :relearning)
                 (decklet--now now)
                 (decklet--now
                  (decklet--next-day-start-time now)))))))

(defun decklet-db--reviewed-count (start end)
  "Return the number of active cards last reviewed between START and END."
  (caar (sqlite-select
         (decklet-db--ensure)
         "SELECT COUNT(*) FROM cards
           WHERE archived_at IS NULL
             AND last_review >= ? AND last_review < ?;"
         (list (decklet--now start) (decklet--now end)))))

;; Calendar queries

(defun decklet-db-due-counts-by-date (day-start cutoff)
  "Return due-card counts between the times DAY-START and CUTOFF.
The result is a plist of :rows, a list of (DATE-STRING COUNT), and
:overdue, the number of cards due before DAY-START."
  (let* ((conn (decklet-db--ensure))
         (day-start-ts (decklet--now day-start))
         (cutoff-ts (decklet--now cutoff))
         (offset (format "%+d hours"
                         (- (decklet--clamp decklet-day-rollover-hour 0 23))))
         (rows (sqlite-select
                conn
                "SELECT date(due, 'localtime', ?) AS due_date, COUNT(*)
                 FROM cards
                 WHERE archived_at IS NULL
                   AND last_review IS NOT NULL
                   AND due >= ?
                   AND due < ?
                 GROUP BY due_date;"
                (list offset day-start-ts cutoff-ts)))
         (overdue-count
          (caar (sqlite-select
                 conn
                 "SELECT COUNT(*) FROM cards
                  WHERE archived_at IS NULL
                    AND last_review IS NOT NULL
                    AND due < ?;"
                 (list day-start-ts)))))
    (list :rows rows :overdue overdue-count)))

;; Maintenance command

;;;###autoload
(defun decklet-open-db-file ()
  "Open the SQLite database file in `sqlite-mode'."
  (interactive)
  (sqlite-mode-open-file decklet-db-file))

(provide 'decklet-db)
;;; decklet-db.el ends here

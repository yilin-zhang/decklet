;;; decklet-db.el --- Database layer for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; SQLite storage and backup helpers.

;;; Code:

(require 'cl-lib)
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

(defvar decklet-db--last-card-id nil
  "In-memory monotonic counter for `cards.card_id' values.
Seeded lazily from the current `MAX(card_id)' on first call,
then incremented monotonically with each mint.  Reset to nil each
Emacs session so the seed is recomputed from the DB on startup.")

(defvar decklet-db-pre-disconnect-hook nil
  "Hook run immediately before the SQLite connection is closed.
Use this to clean up any resources that depend on an open DB connection.
Core already keeps review, edit, and card-back buffers alive as long as
the DB is open (see `decklet-db--session-window-open-p'); this hook is
for sidecar packages that need a last-chance cleanup before the handle
goes away.")

(defvar decklet-db-post-backup-functions nil
  "Abnormal hook called after a successful database backup.
Each function is called with two arguments: BACKUP-DIR and TIMESTAMP.
Intended for modules that want to back up auxiliary files (e.g. the
review log JSONL) alongside the DB snapshot.")

(defconst decklet-db--numeric-sort-columns '("stability" "difficulty")
  "DB columns that use numeric COALESCE for sorting.")

(defconst decklet-db--card-columns
  "card_id, word, hint, back, added_date, last_review, due, state, step, stability, difficulty"
  "Column list shared by card SELECTs that feed `decklet-db--normalize-row'.
Column order must match `decklet-db--normalize-row's `pcase-let'.")

(defun decklet-db--normalize-word (word)
  "Normalize WORD and signal an error if empty."
  (let* ((trimmed (string-trim (or word "")))
         (single-line (replace-regexp-in-string "[\r\n]+" " " trimmed)))
    (if (string-empty-p single-line)
        (user-error "Word cannot be empty")
      single-line)))

(defun decklet-db--normalize-optional-text (text)
  "Trim TEXT and return nil if blank."
  (when text
    (let ((trimmed (string-trim text)))
      (unless (string-empty-p trimmed)
        trimmed))))

(defun decklet-db--normalize-row (row)
  "Normalize ROW into a card plist with named keys.
ROW's column order must match the physical DB column order (skipping
`archived_at'): card_id, word, hint, back, added_date, last_review,
due, state, step, stability, difficulty.
Return a plist with keys :card-id, :word, :hint, :back, :added,
:last-review, :due, :state, :step, :stability, and :difficulty."
  (when row
    (pcase-let ((`(,card-id ,word ,hint ,back ,added ,last-review ,due ,state ,step ,stability ,difficulty) row))
      (list :card-id card-id
            :word (decklet-db--normalize-word word)
            :hint (decklet-db--normalize-optional-text hint)
            :back (decklet-db--normalize-optional-text back)
            :added added
            :last-review last-review
            :due due
            :state state
            :step step
            :stability stability
            :difficulty difficulty))))

(defun decklet-db--ensure-db-dir ()
  "Ensure the database directory exists."
  (let ((dir (file-name-directory decklet-db-file)))
    (unless (file-exists-p dir)
      (make-directory dir t))))

(defun decklet-db--ensure ()
  "Ensure SQLite connection and schema are initialized."
  (unless decklet-db--conn
    (decklet-db--ensure-db-dir)
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
                       difficulty  REAL
                     );")
    ;; `card_id INTEGER PRIMARY KEY' aliases to rowid, so no separate
    ;; unique index is needed on it — the rowid B-tree IS the primary
    ;; key index.  The implicit index on `word' is created
    ;; automatically from `UNIQUE NOT NULL'.
    (sqlite-execute decklet-db--conn
                    "CREATE INDEX IF NOT EXISTS idx_cards_due ON cards(due);"))
  decklet-db--conn)

(defun decklet-db--disconnect ()
  "Close the SQLite connection used by Decklet."
  (when decklet-db--conn
    (run-hooks 'decklet-db-pre-disconnect-hook)
    (sqlite-close decklet-db--conn)
    (setq decklet-db--conn nil)))

(defun decklet-db--session-window-open-p (&optional exclude-buffer)
  "Return non-nil when any buffer still depends on the DB connection.
That includes review buffers, edit buffers, and card-back popups —
card-back buffers save through the DB on write, so disconnecting
while one is open would strand its edits.
When EXCLUDE-BUFFER is non-nil, ignore it during the scan — useful
from `kill-buffer-hook' handlers, where the buffer being killed is
still present in `buffer-list' but should not be counted as an
active session for the purpose of deciding whether to disconnect."
  (cl-some
   (lambda (buffer)
     (and (buffer-live-p buffer)
          (not (eq buffer exclude-buffer))
          (with-current-buffer buffer
            (or (derived-mode-p 'decklet-review-mode)
                (derived-mode-p 'decklet-edit-mode)
                (bound-and-true-p decklet-card-back-mode)))))
   (buffer-list)))

(defun decklet-db--disconnect-if-idle (&optional excluding-buffer)
  "Disconnect DB when no review/edit session windows are open.
EXCLUDING-BUFFER, when non-nil, is excluded from the session-open
check — pass the current buffer from inside `kill-buffer-hook' so
the soon-to-be-gone session buffer does not keep the DB open."
  (unless (decklet-db--session-window-open-p excluding-buffer)
    (decklet-db--disconnect)))

(defun decklet-db--select-card-row-by-word (word)
  "Return the card row for WORD or nil."
  (let ((conn (decklet-db--ensure)))
    (decklet-db--normalize-row
     (car (sqlite-select conn
                         (format "SELECT %s FROM cards WHERE word = ?;"
                                 decklet-db--card-columns)
                         (list word))))))

(defun decklet-db--require-card-row-by-word (word)
  "Return the card row for WORD, or signal a user error."
  (or (decklet-db--select-card-row-by-word word)
      (user-error "No card found for \"%s\"" word)))

(defun decklet-db--select-card-row (card-id)
  "Return the card row for CARD-ID or nil."
  (let ((conn (decklet-db--ensure)))
    (decklet-db--normalize-row
     (car (sqlite-select conn
                         (format "SELECT %s FROM cards WHERE card_id = ?;"
                                 decklet-db--card-columns)
                         (list card-id))))))

(defun decklet-db--require-card-row (card-id)
  "Return the card row for CARD-ID, or signal a user error."
  (or (decklet-db--select-card-row card-id)
      (user-error "No card found for id %s" card-id)))

(defun decklet-db--select-card-word (card-id)
  "Return the word for CARD-ID, or nil if absent."
  (decklet-db--select-card-field card-id 'word))

(defun decklet-db--select-card-field (card-id field)
  "Return FIELD for CARD-ID, or nil if absent."
  (let ((conn (decklet-db--ensure)))
    (caar (sqlite-select conn
                         (format "SELECT %s FROM cards WHERE card_id = ?;" field)
                         (list card-id)))))

(defun decklet-db--update-card-text-field (card-id field value)
  "Update text FIELD for CARD-ID with VALUE, returning normalized text."
  (let* ((value (decklet-db--normalize-optional-text value))
         (conn (decklet-db--ensure)))
    (sqlite-execute conn
                    (format "UPDATE cards SET %s = ? WHERE card_id = ?;" field)
                    (list value card-id))
    value))

(defun decklet-db--set-card-archived-at (card-id archived-at)
  "Set CARD-ID archived_at to ARCHIVED-AT."
  (let ((conn (decklet-db--ensure)))
    (sqlite-execute conn "UPDATE cards SET archived_at = ? WHERE card_id = ?;"
                    (list archived-at card-id))))

(defun decklet-db--upsert-card (word card-meta)
  "Insert or update WORD with CARD-META in the database.
Only scheduling fields are written; content fields (hint, back) are
left unchanged on conflict.  `card_id' is inserted for new rows but
intentionally excluded from the ON CONFLICT UPDATE clause, so a
card's stable identity is preserved across rating updates."
  (let* ((word (decklet-db--normalize-word word))
         (conn (decklet-db--ensure)))
    (sqlite-execute
     conn
     "INSERT INTO cards (card_id, word, added_date, last_review, due, state, step, stability, difficulty)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(word) DO UPDATE SET
        added_date = excluded.added_date,
        last_review = excluded.last_review,
        due = excluded.due,
        state = excluded.state,
        step = excluded.step,
        stability = excluded.stability,
        difficulty = excluded.difficulty;"
     (list (decklet-card-meta-card-id card-meta)
           word
           (decklet-card-meta-added-date card-meta)
           (decklet-card-meta-last-review card-meta)
           (decklet-card-meta-due card-meta)
           (decklet-fsrs-state-string (decklet-card-meta-state card-meta))
           (decklet-card-meta-step card-meta)
           (decklet-card-meta-stability card-meta)
           (decklet-card-meta-difficulty card-meta)))))

(defun decklet-db--update-hint (card-id hint)
  "Update CARD-ID's hint with HINT in the database, return normalized hint."
  (decklet-db--update-card-text-field card-id 'hint hint))

(defun decklet-db--update-back (card-id back)
  "Update CARD-ID's back with BACK in the database, return normalized back."
  (decklet-db--update-card-text-field card-id 'back back))

(defun decklet-db--select-card-hint (card-id)
  "Return the hint for CARD-ID, or nil."
  (decklet-db--normalize-optional-text
   (decklet-db--select-card-field card-id 'hint)))

(defun decklet-db--select-card-back (card-id)
  "Return the back content for CARD-ID's card, or nil."
  (decklet-db--normalize-optional-text
   (decklet-db--select-card-field card-id 'back)))

(defun decklet-db--delete-card (card-id)
  "Delete CARD-ID from the database."
  (let ((conn (decklet-db--ensure)))
    (sqlite-execute conn "DELETE FROM cards WHERE card_id = ?;" (list card-id))))

(defun decklet-db--archive-card (card-id archived-at)
  "Mark CARD-ID as archived at ARCHIVED-AT."
  (decklet-db--set-card-archived-at card-id archived-at))

(defun decklet-db--unarchive-card (card-id)
  "Clear CARD-ID's archived flag."
  (decklet-db--set-card-archived-at card-id nil))

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
  "Rename CARD-ID to NEW-WORD in the database, return normalized new word."
  (let* ((conn (decklet-db--ensure))
         (row (or (decklet-db--select-card-row card-id)
                  (user-error "No card found for id %s" card-id)))
         (old-word (plist-get row :word))
         (new-word (decklet-db--normalize-word new-word)))
    (if (string-equal old-word new-word)
        old-word
      (when (decklet-db--select-card-row-by-word new-word)
        (user-error "Word \"%s\" already exists in the deck" new-word))
      (sqlite-execute conn "UPDATE cards SET word = ? WHERE card_id = ?;"
                      (list new-word card-id))
      new-word)))

(defun decklet-db--edit-filter-sql (filter)
  "Return (SQL . PARAMS) for FILTER."
  (let ((s-review (decklet-fsrs-state-string :review))
        (s-learning (decklet-fsrs-state-string :learning))
        (s-relearning (decklet-fsrs-state-string :relearning)))
    (pcase filter
      ('review
       (cons " WHERE archived_at IS NULL AND state = ?"
             (list s-review)))
      ('learning
       (cons " WHERE archived_at IS NULL AND state IN (?, ?)"
             (list s-learning s-relearning)))
      ('archived (cons " WHERE archived_at IS NOT NULL" nil))
      (_ (cons " WHERE archived_at IS NULL" nil)))))

(defun decklet-db--edit-order-sql (sort-key)
  "Return SQL ORDER BY clause for SORT-KEY.
SORT-KEY is (DB-COLUMN . DESCENDING-P), where DB-COLUMN is a raw
database column name string."
  (let* ((db-column (or (car sort-key) "word"))
         (direction (if (cdr sort-key) "DESC" "ASC"))
         (order-expr (if (member db-column decklet-db--numeric-sort-columns)
                         (format "COALESCE(%s, 0)" db-column)
                       (format "COALESCE(%s, '')" db-column))))
    (format " ORDER BY %s %s, rowid %s" order-expr direction direction)))

(defun decklet-db--select-card-rows (&optional filter sort-key)
  "Return cards filtered by FILTER and sorted by SORT-KEY."
  (let ((conn (decklet-db--ensure)))
    (pcase-let ((`(,where . ,params) (decklet-db--edit-filter-sql filter)))
      (mapcar
       #'decklet-db--normalize-row
       (sqlite-select conn
                      (concat (format "SELECT %s FROM cards" decklet-db--card-columns)
                              where
                              (decklet-db--edit-order-sql sort-key)
                              ";")
                      params)))))

(defun decklet-db--row->card-meta (row)
  "Convert card plist ROW into a `decklet-card-meta' instance."
  (when row
    (pcase-let* (((map :card-id :added :last-review :due :state :step :stability :difficulty) row)
                 (is-new (decklet-last-review-empty-p last-review))
                 (state (decklet--normalize-fsrs-state state))
                 (step (if is-new (or step 0) step)))
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
        :meta (decklet-db--row->card-meta row)))

(defun decklet-db--review-normalize-targets (targets)
  "Normalize TARGETS into a list of review types."
  (cond
   ((keywordp targets) (list targets))
   ((listp targets) targets)
   (t (error "Invalid review targets: %S" targets))))

(defun decklet-db--review-validate-order (order)
  "Signal error if ORDER is invalid for `decklet-review-order'."
  (let ((all-targets '()))
    (dolist (step order)
      (let ((step-targets
             (pcase step
               (`(,targets . shuffle)
                (decklet-db--review-normalize-targets targets))
               (`(,targets sort ,field ,sort-order)
                (unless (memq sort-order '(:asc :desc))
                  (error "Invalid sort order: %S" sort-order))
                (let* ((step-targets (decklet-db--review-normalize-targets targets))
                       ;; Learning/relearning/new cards only support due/added sorting.
                       (allowed (if (or (memq :learning step-targets)
                                        (memq :relearning step-targets)
                                        (memq :new step-targets))
                                    '(:due :added)
                                  '(:due :added :last-review :difficulty :stability))))
                  (unless (memq field allowed)
                    (error "Invalid sort field: %S" field))
                  step-targets))
               (_ (error "Invalid review order step: %S" step)))))
        (setq all-targets (append step-targets all-targets))))
    ;; Validate final target list and reject duplicate targets.
    (dolist (target all-targets)
      (unless (memq target '(:learning :relearning :review :new))
        (error "Invalid review target: %S" target)))
    (let ((seen (make-hash-table :test 'eq)))
      (dolist (target all-targets)
        (when (gethash target seen)
          (error "Review target already used: %S" target))
        (puthash target t seen)))))

(defcustom decklet-review-order
  '(((:learning :relearning) . (sort :due :asc))
    (:review  . shuffle)
    (:new     . (sort :added :desc)))
  "Review order for due cards.

Each entry maps TARGETS to a spec:

  (TARGETS . shuffle)
  (TARGETS . (sort FIELD ORDER))

TARGETS is a keyword or list of keywords from `:learning',
`:relearning', `:review', and `:new'.

FIELD can be `:due', `:added', `:last-review', `:difficulty', or
`:stability'.  For `:learning', `:relearning', or `:new' targets,
only `:due' and `:added' are supported.  ORDER can be `:asc' or
`:desc'."
  :type '(repeat sexp)
  :set (lambda (sym val)
         (decklet-db--review-validate-order val)
         (set-default sym val))
  :group 'decklet-review)

(defun decklet-db--review-sort-clause (field order)
  "Return ORDER BY clause for FIELD and ORDER."
  (let* ((column (pcase field
                   (:due "due")
                   (:added "added_date")
                   (:last-review "last_review")
                   (:difficulty "difficulty")
                   (:stability "stability")
                   (_ (error "Unknown sort field: %S" field))))
         (direction (if (eq order :asc) "ASC" "DESC")))
    ;; Tie-break equal sort values by insertion order so later-added cards stay
    ;; after earlier ones (later inserts usually have larger rowid values).
    (format " ORDER BY %s %s, rowid %s" column direction direction)))

(defun decklet-db--review-target-clause (target now)
  "Return SQL clause and params for TARGET at NOW."
  ;; Review cards are due by day; learning/relearning cards are due by timestamp.
  (let ((review-cutoff (decklet--time->fsrs-timestamp
                        (decklet--next-day-start-time now)))
        (learning-cutoff (decklet--time->fsrs-timestamp now))
        (s-review (decklet-fsrs-state-string :review))
        (s-learning (decklet-fsrs-state-string :learning))
        (s-relearning (decklet-fsrs-state-string :relearning)))
    (pcase target
      (:learning
       (cons "state = ?
              AND last_review IS NOT NULL
              AND due <= ?" (list s-learning learning-cutoff)))
      (:relearning
       (cons "state = ?
              AND last_review IS NOT NULL
              AND due <= ?" (list s-relearning learning-cutoff)))
      (:review
       (cons "state = ?
              AND last_review IS NOT NULL
              AND due <= ?" (list s-review review-cutoff)))
      (:new
       (cons "last_review IS NULL
              AND due <= ?" (list review-cutoff)))
      (_ (error "Unknown review target: %S" target)))))

(defun decklet-db--due-items (targets now field order)
  "Return due items for TARGETS at NOW, optionally sorted by FIELD ORDER."
  (let* ((conn (decklet-db--ensure))
         (clauses-and-params (mapcar (lambda (target)
                                       (decklet-db--review-target-clause target now))
                                     targets))
         ;; Build a single WHERE clause with the params in matching order.
         (clauses (mapcar #'car clauses-and-params))
         (params (apply #'append (mapcar #'cdr clauses-and-params)))
         (where (string-join clauses " OR "))
         (order-clause (when field (decklet-db--review-sort-clause field order)))
         (sql (format
               "SELECT card_id, word, due, added_date, last_review, stability, difficulty
                 FROM cards
                 WHERE archived_at IS NULL
                   AND (%s)%s;"
               where (or order-clause "")))
         (rows (sqlite-select conn sql params)))
    (mapcar (lambda (row)
              (cl-loop for key in '(:card-id :word :due :added :last-review :stability :difficulty)
                       for val in row
                       append (list key val)))
            rows)))

(defun decklet-db--review-step-items (step now)
  "Return ITEMS for STEP at NOW.
STEP can be a shuffle or sort clause."
  (pcase step
    (`(,targets . shuffle)
     (let* ((step-targets (decklet-db--review-normalize-targets targets))
            (step-items (decklet-db--due-items step-targets now nil nil)))
       ;; Shuffle happens after SQL filtering (no ORDER BY).
       (decklet--shuffle-list step-items)))
    (`(,targets sort ,field ,sort-order)
     (unless (memq sort-order '(:asc :desc))
       (error "Unknown sort order: %S" sort-order))
     (let* ((step-targets (decklet-db--review-normalize-targets targets)))
       ;; Sorting is done by SQL ORDER BY for this step.
       (decklet-db--due-items step-targets now field sort-order)))
    (_ (error "Invalid review order step: %S" step))))

(defun decklet-db--collect-due-items ()
  "Return due items according to `decklet-review-order'."
  (let* ((now (current-time))
         (items '()))
    (dolist (step decklet-review-order)
      (let ((step-items (decklet-db--review-step-items step now)))
        (setq items (append items step-items))))
    items))

(defun decklet-db--select-due-card-ids ()
  "Return card ids due for review according to `decklet-review-order'."
  (mapcar (lambda (item) (plist-get item :card-id))
          (decklet-db--collect-due-items)))

(defun decklet-db--counts ()
  "Return counter plist from database state."
  (let* ((now (current-time))
         (day-start (decklet--time->fsrs-timestamp (decklet-day-start-time now)))
         (review-cutoff (decklet--time->fsrs-timestamp (decklet--next-day-start-time now)))
         (learning-cutoff (decklet--time->fsrs-timestamp now))
         (s-review (decklet-fsrs-state-string :review))
         (s-learning (decklet-fsrs-state-string :learning))
         (s-relearning (decklet-fsrs-state-string :relearning))
         (conn (decklet-db--ensure))
         (row (car (sqlite-select
                    conn
                    "SELECT
                       SUM(CASE WHEN last_review >= ? AND last_review < ? THEN 1 ELSE 0 END),
                       SUM(CASE WHEN last_review IS NOT NULL AND state = ?
                                     AND due <= ? THEN 1 ELSE 0 END),
                       SUM(CASE WHEN last_review IS NOT NULL
                                     AND state IN (?, ?)
                                     AND due <= ? THEN 1 ELSE 0 END),
                       SUM(CASE WHEN last_review IS NULL THEN 1 ELSE 0 END)
                     FROM cards WHERE archived_at IS NULL;"
                    (list day-start review-cutoff
                          s-review review-cutoff
                          s-learning s-relearning learning-cutoff)))))
    (list :reviewed    (or (nth 0 row) 0)
          :due-review  (or (nth 1 row) 0)
          :due-learning (or (nth 2 row) 0)
          :new         (or (nth 3 row) 0))))

;; Calendar queries

(defun decklet-db-due-counts-by-date (day-start cutoff)
  "Return due-card counts grouped by date.

DAY-START and CUTOFF are time values that bound the query.

Return a plist with keys:
- :rows    list of (DATE-STRING COUNT) rows
- :overdue count of cards due before DAY-START."
  (let* ((conn (decklet-db--ensure))
         (day-start-ts (decklet--time->fsrs-timestamp day-start))
         (cutoff-ts (decklet--time->fsrs-timestamp cutoff))
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

;; JSON export and import

(defun decklet-db--timestamp-utc (&optional time)
  "Return TIME formatted as a UTC timestamp for filenames."
  (format-time-string "%Y%m%dT%H%M%SZ" (or time (current-time)) "UTC0"))

(defun decklet-db--export-default-file ()
  "Return the default JSON export file path."
  (expand-file-name
   (format "decklet-export-%s.json"
           (decklet-db--timestamp-utc))
   decklet-directory))

(defun decklet-db--json-alist-get-raw (record key)
  "Return KEY value from RECORD alist, accepting symbol or string keys.
Preserves the `:json-null' sentinel used by the import parser — callers
that need to distinguish \"key missing\" from \"key explicitly null\"
should use this; everyone else should prefer `decklet-db--json-alist-get'."
  (or (alist-get key record nil nil #'equal)
      (alist-get (symbol-name key) record nil nil #'equal)))

(defun decklet-db--json-alist-get (record key)
  "Return KEY value from RECORD alist, accepting symbol or string keys.
Collapses the `:json-null' sentinel to nil so fields that treat
missing and null equivalently (everything except hint/back) don't
have to care about the import sentinel."
  (let ((value (decklet-db--json-alist-get-raw record key)))
    (if (eq value :json-null) nil value)))

(defun decklet-db--import-text-value (raw)
  "Classify RAW JSON value for an import text field like hint or back.
Return nil when the field was missing from the record, `:clear' when it
was present but JSON `null' or blank, or the trimmed non-empty string."
  (cond
   ((null raw) nil)
   ((eq raw :json-null) :clear)
   ((stringp raw)
    (let ((trimmed (string-trim raw)))
      (if (string-empty-p trimmed) :clear trimmed)))
   (t (user-error "Invalid text value in import: %S" raw))))

(defun decklet-db--import-record->card (record)
  "Convert JSON RECORD alist to a card plist.
Returns a card plist with keys :card-id, :word, :hint, :back,
:meta, and :archived-at.  The :archived-at key is specific to the
import flow and is not present on cards produced by
`decklet-db--row->card'.

:hint and :back use the tri-state encoding from
`decklet-db--import-text-value': nil (missing — preserve existing
value on overwrite), `:clear' (present as JSON null or blank —
clear existing value on overwrite), or a normalized non-empty
string."
  (unless (listp record)
    (user-error "Invalid JSON record: expected object, got %S" record))
  (let* ((now (decklet--now))
         (word (decklet-db--normalize-word
                (decklet-db--json-alist-get record 'word)))
         (state (or (decklet--normalize-fsrs-state
                     (decklet-db--json-alist-get record 'state))
                    :learning))
         (step-raw (decklet-db--json-alist-get record 'step))
         ;; Step is meaningful for learning/relearning.
         ;; Keep review cards at nil when step is missing.
         (step (if (numberp step-raw)
                   step-raw
                 (if (eq state :review) nil 0)))
         (meta (make-decklet-card-meta
                :card-id (decklet-db--mint-card-id)
                :added-date (or (decklet-db--json-alist-get record 'added_date) now)
                :last-review (decklet-db--json-alist-get record 'last_review)
                :due (or (decklet-db--json-alist-get record 'due) now)
                :state state
                :step step
                :stability (decklet-db--json-alist-get record 'stability)
                :difficulty (decklet-db--json-alist-get record 'difficulty)))
         (hint (decklet-db--import-text-value
                (decklet-db--json-alist-get-raw record 'hint)))
         (back (decklet-db--import-text-value
                (decklet-db--json-alist-get-raw record 'back)))
         (archived-at (decklet-db--json-alist-get record 'archived_at)))
    (list :card-id (decklet-card-meta-card-id meta)
          :word word
          :hint hint
          :back back
          :meta meta
          :archived-at archived-at)))

(defun decklet-db--import-read-conflict-choice (word)
  "Prompt conflict action for WORD.
Return (CURRENT-ACTION . GLOBAL-ACTION), where each action is
`:skip' or `:overwrite'.  GLOBAL-ACTION is non-nil only when user
confirms an \"all\" behavior."
  (let ((global-choice nil)
        (resolved nil))
    (while (not resolved)
      (let ((choice (read-char-choice
                     (format "Word \"%s\" exists: [s]kip, [o]verwrite, skip [a]ll, overwrite [A]ll: "
                             word)
                     '(?s ?o ?a ?A))))
        (pcase choice
          (?s
           (setq resolved :skip))
          (?o
           (setq resolved :overwrite))
          (?a
           (if (yes-or-no-p "Apply \"skip all\" for remaining conflicts? ")
               (setq global-choice :skip resolved :skip)
             (message "Canceled \"skip all\"; choose for current word.")))
          (?A
           (if (yes-or-no-p "Apply \"overwrite all\" for remaining conflicts? ")
               (setq global-choice :overwrite resolved :overwrite)
             (message "Canceled \"overwrite all\"; choose for current word."))))))
    (cons resolved global-choice)))

(defun decklet-db--apply-import-text-field (card-id field value overwrite-p)
  "Apply FIELD (`hint' or `back') VALUE for CARD-ID during import.
VALUE uses the tri-state encoding from `decklet-db--import-text-value'.
OVERWRITE-P non-nil means the caller chose overwrite-on-conflict, so a
`:clear' value should actually null the DB field; for new cards the
field is already null so `:clear' is a no-op."
  (let ((setter (pcase field
                  ('hint #'decklet-db--update-hint)
                  ('back #'decklet-db--update-back)
                  (_ (error "Unknown import text field: %S" field)))))
    (pcase value
      ('nil nil)
      (:clear (when overwrite-p (funcall setter card-id nil)))
      ((pred stringp) (funcall setter card-id value))
      (_ (error "Invalid import text value for %s: %S" field value)))))

(defun decklet-db--apply-import-card (card overwrite-p)
  "Upsert CARD into the database and apply its archive flag.
CARD is the plist returned by `decklet-db--import-record->card'.
When OVERWRITE-P is non-nil, also clear any stale archived flag
on an existing row.  New cards never need this since they start
unarchived."
  (let ((word (plist-get card :word))
        (meta (plist-get card :meta))
        (hint (plist-get card :hint))
        (back (plist-get card :back))
        (archived-at (plist-get card :archived-at)))
    (decklet-db--upsert-card word meta)
    (let ((card-id (plist-get (decklet-db--select-card-row-by-word word) :card-id)))
      (decklet-db--apply-import-text-field card-id 'hint hint overwrite-p)
      (decklet-db--apply-import-text-field card-id 'back back overwrite-p)
      (if archived-at
          (decklet-db--archive-card card-id archived-at)
        (when overwrite-p
          (decklet-db--unarchive-card card-id))))))

(defun decklet-db--import-json-file (file)
  "Import cards from JSON FILE.
Return a plist with :added, :overwritten, and :skipped."
  (unless (file-exists-p file)
    (user-error "Import file does not exist: %s" file))
  ;; Parse with `:json-null' as the null sentinel so hint/back can
  ;; distinguish "key missing" (nil) from "key explicitly null"
  ;; (`:json-null').  `decklet-db--import-text-value' collapses both
  ;; null and blank strings into the `:clear' marker downstream.
  (let ((records (with-temp-buffer
                   (insert-file-contents file)
                   (json-parse-buffer :object-type 'alist
                                      :array-type 'list
                                      :null-object :json-null
                                      :false-object nil))))
    (unless (listp records)
      (user-error "Import JSON must be an array of card objects"))
    ;; Resolve all conflict decisions before opening a transaction so
    ;; interactive prompts don't block inside a write transaction.
    ;; Reject intra-file duplicates early: two records with the same word
    ;; would both get a minted id during planning and both be marked
    ;; `:add', but the second upsert hits `ON CONFLICT(word)' and keeps
    ;; the first row's id — so the second minted id is a ghost that
    ;; would leak into `added' counts and `decklet-cards-added-functions'.
    (let* ((global-conflict-action nil)
           (seen-words (make-hash-table :test 'equal))
           (planned (mapcar
                     (lambda (record)
                       (let* ((card (decklet-db--import-record->card record))
                              (word (plist-get card :word)))
                         (when (gethash word seen-words)
                           (user-error "Duplicate word in import file: %s" word))
                         (puthash word t seen-words)
                         (let ((action (if (decklet-db--select-card-row-by-word word)
                                           (or global-conflict-action
                                               (let ((decision (decklet-db--import-read-conflict-choice word)))
                                                 (setq global-conflict-action (cdr decision))
                                                 (car decision)))
                                         :add)))
                           (cons card action))))
                     records))
           (added 0) (overwritten 0) (skipped 0)
           (added-card-ids nil))
      ;; Write all cards in a single transaction.
      (let ((conn (decklet-db--ensure)))
        (sqlite-execute conn "BEGIN;")
        (condition-case err
            (progn
              (dolist (entry planned)
                (let ((card (car entry))
                      (action (cdr entry)))
                  (pcase action
                    (:add
                     (decklet-db--apply-import-card card nil)
                     (push (plist-get card :card-id) added-card-ids)
                     (cl-incf added))
                    (:skip
                     (cl-incf skipped))
                    (:overwrite
                     (decklet-db--apply-import-card card t)
                     (cl-incf overwritten))
                    (_
                     (error "Unknown import action: %S" action)))))
              (sqlite-execute conn "COMMIT;"))
          (error
           (sqlite-execute conn "ROLLBACK;")
           (signal (car err) (cdr err)))))
      ;; Fire lifecycle events after the transaction commits so
      ;; sidecar extensions only see successful imports.  One batched
      ;; event per successful import.
      (when added-card-ids
        (run-hook-with-args 'decklet-cards-added-functions
                            (mapcar (lambda (card-id) (list :card-id card-id))
                                    (nreverse added-card-ids))))
      (list :added added :overwritten overwritten :skipped skipped))))

;;;###autoload
(defun decklet-db-export-json (&optional file)
  "Export all cards to JSON FILE.
When called interactively, prompt for FILE and default to a timestamped
file under `decklet-directory'."
  (interactive
   (let ((default (decklet-db--export-default-file)))
     (list (read-file-name "Export JSON to: "
                           (file-name-directory default)
                           nil nil
                           (file-name-nondirectory default)))))
  (unless (file-exists-p decklet-db-file)
    (user-error "No database file found; nothing to export"))
  (unwind-protect
      (let* ((rows (sqlite-select
                    (decklet-db--ensure)
                    "SELECT word, hint, back, added_date, last_review, due,
                        archived_at, state, step, stability, difficulty
                 FROM cards
                 ORDER BY added_date ASC, word ASC;"))
             (fields '(word hint back added_date last_review due
                            archived_at state step stability difficulty))
             (payload (mapcar (lambda (row)
                                (cl-mapcar #'cons fields row))
                              rows))
             (json-encoding-pretty-print t)
             (json-encoding-default-indentation "  "))

        (make-directory (file-name-directory file) t)
        (let ((coding-system-for-write 'utf-8-unix))
          (with-temp-file file
            (insert (json-encode payload))))

        (when (called-interactively-p 'any)
          (message "Exported %d cards to %s" (length payload) file)))
    (decklet-db--disconnect-if-idle)))

;;;###autoload
(defun decklet-db-import-json (&optional file)
  "Import cards from JSON FILE into the database.
When called interactively, prompt for FILE under `decklet-directory'."
  (interactive
   (let ((default (expand-file-name "decklet-import.json" decklet-directory)))
     (list (read-file-name "Import JSON from: "
                           (file-name-directory default)
                           nil t
                           (file-name-nondirectory default)))))
  (unwind-protect
      (let* ((file (or file (expand-file-name "decklet-import.json" decklet-directory)))
             (result (decklet-db--import-json-file file)))
        (when (called-interactively-p 'any)
          (message "Import finished: %d added, %d overwritten, %d skipped"
                   (plist-get result :added)
                   (plist-get result :overwritten)
                   (plist-get result :skipped)))
        result)
    (decklet-db--disconnect-if-idle)))

;; Backups

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

(defconst decklet-db--backup-timestamp-re "[0-9]\\{8\\}T[0-9]\\{6\\}Z"
  "Regex matching the UTC timestamp produced by `decklet-db--timestamp-utc'.")

(defun decklet-db--backup-file-pattern (base ext)
  "Return a regexp matching timestamped backup files for BASE.EXT.
Includes an optional collision suffix (e.g. `-1', `-2')."
  (format "\\`%s-%s\\(-[0-9]+\\)?\\.%s\\'"
          (regexp-quote base)
          decklet-db--backup-timestamp-re
          (regexp-quote ext)))

(defun decklet-db--backup-target (backup-dir base ext timestamp)
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

(defun decklet-db--backup-prune (backup-dir base ext)
  "Prune old backup files in BACKUP-DIR matching BASE.EXT.
Keeps the newest `decklet-backup-prune-max-count' files and
deletes the rest.  Filenames carry a UTC timestamp, so
lexicographic order matches chronological order."
  (when (and (integerp decklet-backup-prune-max-count)
             (> decklet-backup-prune-max-count 0))
    (let* ((pattern (decklet-db--backup-file-pattern base ext))
           (files (sort (directory-files backup-dir t pattern) #'string<))
           (to-delete (butlast files decklet-backup-prune-max-count)))
      (dolist (file to-delete)
        (condition-case err
            (delete-file file)
          (error
           (message "Decklet: backup prune failed for %s: %s"
                    (abbreviate-file-name file)
                    (error-message-string err))))))))

(defun decklet-db--backup ()
  "Create a database backup, fire the post-backup hook, and prune old backups."
  (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
         (base (file-name-base decklet-db-file))
         (timestamp (decklet-db--timestamp-utc))
         (backup-file (decklet-db--backup-target backup-dir base "sqlite" timestamp)))
    (make-directory backup-dir t)
    (copy-file decklet-db-file backup-file t t t)
    (decklet-db--backup-prune backup-dir base "sqlite")
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
           (target (decklet-db--backup-target backup-dir base ext timestamp)))
      (copy-file source-file target t t t)
      (decklet-db--backup-prune backup-dir base ext))))

(defun decklet-db--backup-timestamp (file)
  "Return the backup timestamp for FILE, or nil if unavailable."
  (let ((pattern (format "\\`%s-\\(%s\\)"
                         (regexp-quote (file-name-base decklet-db-file))
                         decklet-db--backup-timestamp-re))
        (filename (file-name-base file)))
    (when (string-match pattern filename)
      (condition-case nil
          (date-to-time (match-string 1 filename))
        (error nil)))))

(defun decklet-db--backup-files ()
  "Return backup files sorted by newest timestamp first."
  (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
         (base (file-name-base decklet-db-file))
         (pattern (decklet-db--backup-file-pattern base "sqlite"))
         (files (when (file-directory-p backup-dir)
                  (directory-files backup-dir t pattern))))
    (sort files
          (lambda (a b)
            (let ((ta (or (decklet-db--backup-timestamp a)
                          (file-attribute-modification-time (file-attributes a))))
                  (tb (or (decklet-db--backup-timestamp b)
                          (file-attribute-modification-time (file-attributes b)))))
              (time-less-p tb ta))))))

(defun decklet-db--backup-choice-label (file)
  "Return a display label for backup FILE."
  (format-time-string "%Y-%m-%d %H:%M:%S"
                      (file-attribute-modification-time
                       (file-attributes file))))

(defun decklet-db--read-backup-choice (choices default)
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
           (latest-backup (car (decklet-db--backup-files)))
           (latest-mtime (when latest-backup
                           (file-attribute-modification-time
                            (file-attributes latest-backup)))))
      (if (equal mtime latest-mtime)
          (when (called-interactively-p 'any)
            (message "Backup not needed; database unchanged"))
        (decklet-db--backup)
        (when (called-interactively-p 'any)
          (message "Backup created"))))))

;;;###autoload
(defun decklet-db-restore ()
  "Restore the database from a selected backup file."
  (interactive)
  (let* ((files (decklet-db--backup-files)))
    (unless files
      (user-error "No backups found in %s" decklet-backup-directory))
    (let* ((choices (mapcar (lambda (file)
                              (cons (decklet-db--backup-choice-label file) file))
                            files))
           (default (caar choices))
           (selection (decklet-db--read-backup-choice choices default))
           (backup-file (cdr (assoc selection choices))))
      (unless backup-file
        (user-error "No backup selected"))
      ;; Require explicit disconnection before restore.
      ;; Replacing the DB file is only unsafe when a live SQLite connection
      ;; still holds the file handle.
      (when decklet-db--conn
        (user-error "Please quit review/edit sessions (or otherwise disconnect DB) before restore"))
      (when (yes-or-no-p (format "Restore %s to %s? "
                                 (file-name-nondirectory backup-file)
                                 decklet-db-file))
        (copy-file backup-file decklet-db-file t t t)
        (message "Restored database from %s" (file-name-nondirectory backup-file))))))

;; Maintenance command

;;;###autoload
(defun decklet-open-db-file ()
  "Open the SQLite database file in `sqlite-mode'."
  (interactive)
  (sqlite-mode-open-file decklet-db-file))

(provide 'decklet-db)
;;; decklet-db.el ends here

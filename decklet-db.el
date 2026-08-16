;;; decklet-db.el --- Database layer for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; SQLite connection management and card queries.

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
Use this for last-chance cleanup of sidecar resources that depend
on an open DB connection.")

(defvar-local decklet-db--session-buffer nil
  "Non-nil when the current buffer is part of the Decklet session.
Set by `decklet-db-register-session-buffer'.  Session buffers keep
the connection open while they live, are closed by
`decklet-disconnect', and block `decklet-db-restore'.")

(defvar-local decklet-db--session-primary nil
  "Non-nil when the current buffer owns the session lifetime.
Set for review/edit buffers: when the last primary buffer is
killed, attached session buffers are closed first and the DB
disconnects.")

(defconst decklet-db--numeric-sort-columns '("stability" "difficulty")
  "DB columns that use numeric COALESCE for sorting.")

(defconst decklet-db--sortable-columns
  '("word" "hint" "added_date" "last_review" "due" "state"
    "stability" "difficulty")
  "DB columns that card SELECTs may be sorted by.
`decklet-db--edit-order-sql' rejects anything outside this set;
column names are interpolated into SQL, so the whitelist lives
next to the interpolation rather than in each caller.
Keep `decklet-edit--db-sort-columns' values within this set.")

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
Words are stored normalized (see `decklet-db--normalize-word' at the
write sites), so the read path takes them as-is.
Return a plist with keys :card-id, :word, :hint, :back, :added,
:last-review, :due, :state, :step, :stability, and :difficulty."
  (when row
    (pcase-let ((`(,card-id ,word ,hint ,back ,added ,last-review ,due ,state ,step ,stability ,difficulty) row))
      (list :card-id card-id
            :word word
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
  (when-let* ((dir (file-name-directory decklet-db-file)))
    (make-directory dir t)))

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

(defun decklet-db--clear-session-markers ()
  "Drop the current buffer's session markers and lifecycle hooks.
Leaves the connection alone; callers decide when to check for idleness."
  (kill-local-variable 'decklet-db--session-buffer)
  (kill-local-variable 'decklet-db--session-primary)
  (remove-hook 'kill-buffer-query-functions
               #'decklet-db--primary-kill-query t)
  (remove-hook 'kill-buffer-hook
               #'decklet-db--on-session-buffer-killed t))

(defun decklet-db-acquire-session-buffer (&optional primary)
  "Mark the current buffer as part of the Decklet session.
Extension-owned popups that read or write the DB should call this
once during setup: session buffers keep the connection open while
they live, are closed by `decklet-disconnect', and block
`decklet-db-restore'.

PRIMARY is for Decklet's own review/edit buffers: when the last
primary buffer is killed, the remaining session buffers are closed
first (each may prompt to save) and the DB disconnects.

Return a disposer: a function of no arguments that releases the
lease, dropping the buffer's session markers and disconnecting the
DB when no session buffer is left.  Buffers that live exactly as
long as their lease need not keep it — killing them releases the
lease through `kill-buffer-hook'.  A buffer that outlives its lease
\(a minor mode the user can switch off) must call the disposer, or
the connection stays open with nothing holding it.

The disposer is idempotent and stays safe once the buffer is dead."
  (let ((buffer (current-buffer))
        (released nil))
    (setq-local decklet-db--session-buffer t)
    (when primary
      (setq-local decklet-db--session-primary t)
      (add-hook 'kill-buffer-query-functions
                #'decklet-db--primary-kill-query nil t))
    (add-hook 'kill-buffer-hook #'decklet-db--on-session-buffer-killed nil t)
    (lambda ()
      (unless released
        (setq released t)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (decklet-db--clear-session-markers)))
        (decklet-db--disconnect-if-idle)))))

(defun decklet-db-register-session-buffer (&optional primary)
  "Mark the current buffer as part of the Decklet session.
PRIMARY is passed through to `decklet-db-acquire-session-buffer'.

This is the lease-for-the-buffer's-lifetime form: it discards the
disposer, so the lease is only released when the buffer is killed.
Prefer `decklet-db-acquire-session-buffer' whenever the buffer can
outlive its use of the DB."
  (decklet-db-acquire-session-buffer primary)
  nil)

(define-obsolete-function-alias 'decklet-db-register-dependent-buffer
  #'decklet-db-register-session-buffer "0.1.0")

(defun decklet-db--session-buffers (&optional exclude)
  "Return live Decklet session buffers, ignoring EXCLUDE.
Pass the current buffer from kill hooks, where the dying buffer is
still present in `buffer-list'."
  (seq-filter (lambda (buffer)
                (and (not (eq buffer exclude))
                     (buffer-local-value 'decklet-db--session-buffer buffer)))
              (buffer-list)))

(defun decklet-db--primary-session-buffers (&optional exclude)
  "Return live primary session buffers, ignoring EXCLUDE."
  (seq-filter (lambda (buffer)
                (buffer-local-value 'decklet-db--session-primary buffer))
              (decklet-db--session-buffers exclude)))

(defun decklet-db--primary-kill-query ()
  "Close attached session buffers when the last primary buffer dies.
With another primary buffer still live, allow the kill untouched.
Otherwise try to close every other session buffer first, and veto
the kill if one refuses (e.g. an unsaved card back whose save
prompt was canceled)."
  (or (decklet-db--primary-session-buffers (current-buffer))
      (not (seq-some (lambda (buffer) (not (kill-buffer buffer)))
                     (decklet-db--session-buffers (current-buffer))))))

(defun decklet-db--disconnect-if-idle (&optional exclude)
  "Disconnect the DB when no session buffer (ignoring EXCLUDE) is open.
Used after one-shot commands like JSON export/import, which may
have lazily opened the connection outside any session."
  (unless (decklet-db--session-buffers exclude)
    (decklet-db--disconnect)))

(defun decklet-db--on-session-buffer-killed ()
  "Disconnect the DB when the last session buffer is killed."
  (decklet-db--disconnect-if-idle (current-buffer)))

;;;###autoload
(defun decklet-disconnect ()
  "Close Decklet session buffers, then disconnect the DB.
Killing a session buffer can prompt (e.g. an unsaved card back); if
any buffer refuses to die, abort and leave the DB connected."
  (interactive)
  (let* ((buffers (decklet-db--session-buffers))
         (primaries (decklet-db--primary-session-buffers))
         ;; Primaries first: the last one cascade-kills the attached
         ;; buffers via its kill query, so an abort names the
         ;; review/edit buffer rather than an attached popup.
         (ordered (append primaries (seq-difference buffers primaries)))
         (had-conn decklet-db--conn))
    (dolist (buffer ordered)
      (when (buffer-live-p buffer)
        (unless (kill-buffer buffer)
          (user-error "Decklet disconnect canceled by buffer %s"
                      (buffer-name buffer)))))
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

(defun decklet-db--select-card-word (card-id)
  "Return the word for CARD-ID, or nil if absent."
  (decklet-db--select-card-field card-id 'word))

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
  "Update text FIELD for CARD-ID with VALUE, returning normalized text.
FIELD is interpolated into SQL; only `hint' and `back' are accepted."
  (unless (memq field '(hint back))
    (error "Unsupported card text field: %S" field))
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
database column name string from `decklet-db--sortable-columns'."
  (let ((db-column (or (car sort-key) "word")))
    (unless (member db-column decklet-db--sortable-columns)
      (error "Unsupported sort column: %S" db-column))
    (let* ((direction (if (cdr sort-key) "DESC" "ASC"))
           (order-expr (if (member db-column decklet-db--numeric-sort-columns)
                           (format "COALESCE(%s, 0)" db-column)
                         (format "COALESCE(%s, '')" db-column))))
      (format " ORDER BY %s %s, rowid %s" order-expr direction direction))))

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
`:desc'.

The value is validated both when set through Customize and when
the due queue is collected, so `setq'-configured values get the
same checks on the next review."
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
  "Return due items according to `decklet-review-order'.
Validates the order first so `setq'-configured values get the same
checks as Customize-set ones."
  (decklet-db--review-validate-order decklet-review-order)
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

;; Maintenance command

;;;###autoload
(defun decklet-open-db-file ()
  "Open the SQLite database file in `sqlite-mode'."
  (interactive)
  (sqlite-mode-open-file decklet-db-file))

(provide 'decklet-db)
;;; decklet-db.el ends here

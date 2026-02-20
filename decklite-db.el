;;; decklite-db.el --- Database layer for DeckLite -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; SQLite storage and backup helpers.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'sqlite)
(require 'subr-x)

(require 'decklite-core)
(require 'decklite-schedular)

(defgroup decklite-db nil
  "Database for DeckLite."
  :group 'decklite)

(defcustom decklite-db-file
  (expand-file-name "decklite.sqlite" decklite-directory)
  "Path to the SQLite database file."
  :type 'file
  :group 'decklite-db)

(defcustom decklite-review-order
  '((:sort :due :asc :learning)
    (:shuffle :review)
    (:sort :added :desc :new))
  "Review order for due cards.

Each entry is one of:

  (:shuffle TARGETS)
  (:sort FIELD ORDER TARGETS)

TARGETS can be a single type or a list of types.  Types are:
`:learning', `:review', and `:new'.  `:learning' includes relearning cards.

FIELD can be `:due', `:added', `:last-review', `:difficulty', or `:stability'.
For `:learning' or `:new' targets, only `:due' and `:added' are supported.
ORDER can be `:asc' or `:desc'."
  :type '(repeat sexp)
  :group 'decklite-review)

(defvar decklite-db--conn nil
  "SQLite connection for DeckLite.")

(defconst decklite-db--edit-sort-columns
  '(("Word" . "word")
    ("Hint" . "hint")
    ("Added" . "added_date")
    ("Due" . "due")
    ("State" . "state")
    ("Stability" . "stability")
    ("Difficulty" . "difficulty"))
  "Mapping of edit table headers to database columns.")

(defun decklite-db--normalize-word (word)
  "Trim WORD and signal an error if empty."
  (let ((trimmed (string-trim (or word ""))))
    (if (string-empty-p trimmed)
        (error "Word cannot be empty")
      trimmed)))

(defun decklite-db--normalize-hint (hint)
  "Trim HINT and return nil if empty."
  (when hint
    (let ((trimmed (string-trim hint)))
      (unless (string-empty-p trimmed)
        trimmed))))

(defun decklite-db--normalize-row (row)
  "Normalize ROW values for word and hint fields."
  (when row
    (pcase-let ((`(,word ,added ,last-review ,due ,state ,step ,stability ,difficulty ,hint) row))
      (let ((normalized-word (decklite-db--normalize-word word))
            (normalized-hint (decklite-db--normalize-hint hint)))
        (list normalized-word
              added last-review due state step stability difficulty
              normalized-hint)))))

(defun decklite-db--ensure-db-dir ()
  "Ensure the database directory exists."
  (let ((dir (file-name-directory decklite-db-file)))
    (unless (file-exists-p dir)
      (make-directory dir t))))

(defun decklite-db--ensure ()
  "Ensure SQLite connection and schema are initialized."
  (unless decklite-db--conn
    (decklite-db--ensure-db-dir)
    (setq decklite-db--conn (sqlite-open decklite-db-file))
    (sqlite-execute decklite-db--conn "PRAGMA journal_mode = TRUNCATE;")
    (sqlite-execute decklite-db--conn "PRAGMA foreign_keys = ON;")
    (sqlite-execute decklite-db--conn
                    "CREATE TABLE IF NOT EXISTS cards (
                       word TEXT PRIMARY KEY,
                       added_date TEXT NOT NULL,
                       last_review TEXT,
                       due TEXT NOT NULL,
                       archived_at TEXT,
                       state TEXT NOT NULL,
                       step INTEGER,
                       stability REAL,
                       difficulty REAL,
                       hint TEXT
                     );")
    (sqlite-execute decklite-db--conn
                    "CREATE INDEX IF NOT EXISTS idx_cards_due ON cards(due);"))
  decklite-db--conn)

(defun decklite-db--disconnect ()
  "Close the SQLite connection used by DeckLite."
  (when decklite-db--conn
    (sqlite-close decklite-db--conn)
    (setq decklite-db--conn nil)))

(defun decklite-db--session-window-open-p ()
  "Return non-nil when a review/edit session buffer is still open."
  (cl-some
   (lambda (buffer)
     (and (buffer-live-p buffer)
          (with-current-buffer buffer
            (or (derived-mode-p 'decklite-review-mode)
                (derived-mode-p 'decklite-edit-mode)))))
   (buffer-list)))

(defun decklite-db--disconnect-if-idle ()
  "Disconnect DB when no review/edit session windows are open."
  (unless (decklite-db--session-window-open-p)
    (decklite-db--disconnect)))

(defun decklite-db--select-card (word)
  "Return the card row for WORD or nil."
  (let ((conn (decklite-db--ensure)))
    (decklite-db--normalize-row
     (car (sqlite-select conn
                         "SELECT word, added_date, last_review, due, state, step, stability, difficulty, hint
                          FROM cards WHERE word = ?;"
                         (list word))))))

(defun decklite-db--upsert-card (word card-meta)
  "Insert or update WORD with CARD-META in the database."
  (let* ((word (decklite-db--normalize-word word))
         (hint (decklite-db--normalize-hint (decklite-card-meta-hint card-meta)))
         (conn (decklite-db--ensure)))
    (setf (decklite-card-meta-hint card-meta) hint) ; update to the normalized hint
    (sqlite-execute
     conn
     "INSERT INTO cards (word, added_date, last_review, due, state, step, stability, difficulty, hint)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(word) DO UPDATE SET
        added_date = excluded.added_date,
        last_review = excluded.last_review,
        due = excluded.due,
        state = excluded.state,
        step = excluded.step,
        stability = excluded.stability,
        difficulty = excluded.difficulty,
        hint = excluded.hint;"
     (list word
           (decklite-card-meta-added-date card-meta)
           (decklite-card-meta-last-review card-meta)
           (decklite-card-meta-due card-meta)
           (decklite--fsrs-state-string (decklite-card-meta-state card-meta))
           (decklite-card-meta-step card-meta)
           (decklite-card-meta-stability card-meta)
           (decklite-card-meta-difficulty card-meta)
           hint))))

(defun decklite-db--update-hint (word hint)
  "Update WORD's hint with HINT in the database, return normalized hint."
  (let* ((word (decklite-db--normalize-word word))
         (hint (decklite-db--normalize-hint hint))
         (conn (decklite-db--ensure)))
    (sqlite-execute conn "UPDATE cards SET hint = ? WHERE word = ?;"
                    (list hint word))
    hint))

(defun decklite-db--delete-card (word)
  "Delete WORD from the database."
  (let ((conn (decklite-db--ensure)))
    (sqlite-execute conn "DELETE FROM cards WHERE word = ?;" (list word))))

(defun decklite-db--archive-card (word archived-at)
  "Mark WORD as archived at ARCHIVED-AT."
  (let ((conn (decklite-db--ensure)))
    (sqlite-execute conn "UPDATE cards SET archived_at = ? WHERE word = ?;"
                    (list archived-at word))))

(defun decklite-db--unarchive-card (word)
  "Clear WORD's archived flag."
  (let ((conn (decklite-db--ensure)))
    (sqlite-execute conn "UPDATE cards SET archived_at = NULL WHERE word = ?;"
                    (list word))))

(defun decklite-db--update-word (old-word new-word)
  "Rename OLD-WORD to NEW-WORD in the database, return normalized new word."
  (let ((conn (decklite-db--ensure))
        (old-word (decklite-db--normalize-word old-word))
        (new-word (decklite-db--normalize-word new-word)))
    (when (string-equal old-word new-word)
      (cl-return-from decklite-db--update-word old-word))
    (when (decklite-db--select-card new-word)
      (error "Word \"%s\" already exists in the deck" new-word))
    (sqlite-execute conn "UPDATE cards SET word = ? WHERE word = ?;"
                    (list new-word old-word))
    new-word))

(defun decklite-db--edit-filter-sql (filter)
  "Return (SQL . PARAMS) for FILTER."
  (pcase filter
    ('review (cons " WHERE archived_at IS NULL AND state = 'review'" nil))
    ('learning (cons " WHERE archived_at IS NULL AND state IN ('learning', 'relearning')" nil))
    ('archived (cons " WHERE archived_at IS NOT NULL" nil))
    (_ (cons " WHERE archived_at IS NULL" nil))))

(defun decklite-db--edit-order-sql (sort-key)
  "Return SQL ORDER BY clause for SORT-KEY."
  (let* ((column (and sort-key (car sort-key)))
         (reverse (and sort-key (cdr sort-key)))
         (db-column (cdr (assoc-string column decklite-db--edit-sort-columns)))
         (db-column (or db-column "word"))
         (direction (if reverse "DESC" "ASC"))
         (order-expr (if (member db-column '("stability" "difficulty"))
                         (format "COALESCE(%s, 0)" db-column)
                       (format "COALESCE(%s, '')" db-column))))
    ;; Tie-break equal sort values by insertion order so later-added cards stay
    ;; after earlier ones (later inserts usually have larger rowid values).
    (format " ORDER BY %s %s, rowid %s" order-expr direction direction)))

(defun decklite-db--select-cards (&optional filter sort-key)
  "Return cards filtered by FILTER and sorted by SORT-KEY."
  (let ((conn (decklite-db--ensure)))
    (pcase-let ((`(,where . ,params) (decklite-db--edit-filter-sql filter)))
      (mapcar
       #'decklite-db--normalize-row
       (sqlite-select conn
                      (concat
                       "SELECT word, added_date, last_review, due, state, step, stability, difficulty, hint
                        FROM cards"
                       where
                       (decklite-db--edit-order-sql sort-key)
                       ";")
                      params)))))

(defun decklite-db--row->card-meta (row)
  "Convert ROW into a `decklite-card-meta' instance."
  (when row
    (pcase-let ((`(,_word ,added-date ,last-review ,due ,state ,step ,stability ,difficulty ,hint) row))
      (let* ((scheduler (decklite--get-fsrs-scheduler))
             (state (decklite--normalize-fsrs-state state))
             (added-date (or added-date (fsrs-now)))
             (last-review last-review)
             (due (or due (fsrs-now)))
             (is-new (null last-review))
             (state (or state (if is-new :learning :review)))
             (step (if is-new (or step 0) step))
             (stability (and (numberp stability) (> stability 0) stability))
             (difficulty (and (numberp difficulty) (> difficulty 0) difficulty))
             (stability (if (and (not is-new) (null stability))
                            (fsrs-scheduler-initial-stability scheduler :good)
                          stability))
             (difficulty (if (and (not is-new) (null difficulty))
                             (fsrs-scheduler-initial-difficulty scheduler :good)
                           difficulty)))
        (make-decklite-card-meta
         :added-date added-date
         :last-review last-review
         :due due
         :state state
         :step step
         :stability stability
         :difficulty difficulty
         :hint hint)))))

(defun decklite-db--review-normalize-targets (targets)
  "Normalize TARGETS into a list of review types."
  (cond
   ((keywordp targets) (list targets))
   ((listp targets) targets)
   (t (error "Invalid review targets: %S" targets))))

(defun decklite-db--review-validate-order (order)
  "Signal error if ORDER is invalid for `decklite-review-order'."
  (let ((all-targets '()))
    (dolist (step order)
      (pcase step
        (`(:shuffle ,step-targets)
         ;; Track targets as they appear so we can detect duplicates later.
         (setq all-targets
               (append (decklite-db--review-normalize-targets step-targets) all-targets)))
        (`(:sort ,field ,order ,step-targets)
         (unless (memq order '(:asc :desc))
           (error "Invalid sort order: %S" order))
         (let* ((step-targets (decklite-db--review-normalize-targets step-targets))
                ;; Learning/new cards only support due/added sorting.
                (allowed (if (or (memq :learning step-targets)
                                 (memq :new step-targets))
                             '(:due :added)
                           '(:due :added :last-review :difficulty :stability))))
           (unless (memq field allowed)
             (error "Invalid sort field: %S" field))
           (setq all-targets (append step-targets all-targets))))
        (_ (error "Invalid review order step: %S" step))))
    ;; Validate final target list and reject duplicate targets.
    (dolist (target all-targets)
      (unless (memq target '(:learning :review :new))
        (error "Invalid review target: %S" target)))
    (let ((seen (make-hash-table :test 'eq)))
      (dolist (target all-targets)
        (when (gethash target seen)
          (error "Review target already used: %S" target))
        (puthash target t seen)))))

(defun decklite-db--review-sort-clause (field order)
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

(defun decklite-db--review-target-clause (target now)
  "Return SQL clause and params for TARGET at NOW."
  ;; Review cards are due by day; learning cards are due by timestamp.
  (let ((review-cutoff (decklite--time->fsrs-timestamp
                        (decklite--next-day-start-time now)))
        (learning-cutoff (decklite--time->fsrs-timestamp now)))
    (pcase target
      (:learning
       (cons "state IN ('learning', 'relearning')
              AND last_review IS NOT NULL
              AND due <= ?" (list learning-cutoff)))
      (:review
       (cons "state = 'review'
              AND last_review IS NOT NULL
              AND due <= ?" (list review-cutoff)))
      (:new
       (cons "last_review IS NULL
              AND due <= ?" (list review-cutoff)))
      (_ (error "Unknown review target: %S" target)))))

(defun decklite-db--due-items (targets now field order)
  "Return due items for TARGETS at NOW, optionally sorted by FIELD ORDER."
  (let* ((conn (decklite-db--ensure))
         (clauses-and-params (mapcar (lambda (target)
                                       (decklite-db--review-target-clause target now))
                                     targets))
         ;; Build a single WHERE clause with the params in matching order.
         (clauses (mapcar #'car clauses-and-params))
         (params (apply #'append (mapcar #'cdr clauses-and-params)))
         (where (string-join clauses " OR "))
         (order-clause (when field (decklite-db--review-sort-clause field order)))
         (sql (format
               "SELECT word, due, added_date, last_review, stability, difficulty
                FROM cards
                WHERE archived_at IS NULL
                  AND (%s)%s;"
               where (or order-clause "")))
         (rows (sqlite-select conn sql params)))
    (mapcar (lambda (row)
              (cl-loop for key in '(:word :due :added :last-review :stability :difficulty)
                       for val in row
                       append (list key val)))
            rows)))

(defun decklite-db--review-step-items (step now)
  "Return ITEMS for STEP at NOW.
STEP can be a shuffle or sort clause."
  (pcase step
    (`(:shuffle ,targets)
     (let* ((step-targets (decklite-db--review-normalize-targets targets))
            (step-items (decklite-db--due-items step-targets now nil nil)))
       ;; Shuffle happens after SQL filtering (no ORDER BY).
       (decklite--shuffle-list step-items)))
    (`(:sort ,field ,order ,targets)
      (unless (memq order '(:asc :desc))
        (error "Unknown sort order: %S" order))
      (let* ((step-targets (decklite-db--review-normalize-targets targets))
             (step-items (decklite-db--due-items step-targets now field order)))
        ;; Sorting is done by SQL ORDER BY for this step.
        step-items))
    (_ (error "Invalid review order step: %S" step))))

(defun decklite-db--select-due-words ()
  "Return words due for review according to `decklite-review-order'."
  (let* ((now (current-time))
         (items '()))
    (decklite-db--review-validate-order decklite-review-order)
    (dolist (step decklite-review-order)
      (let ((step-items (decklite-db--review-step-items step now)))
        ;; Preserve step ordering while concatenating.
        (setq items (append items step-items))))
    (mapcar (lambda (item) (plist-get item :word)) items)))

(defun decklite-db--count (sql params)
  "Return the count for SQL query with PARAMS."
  (let* ((conn (decklite-db--ensure))
         (row (car (sqlite-select conn sql params))))
    (if row (car row) 0)))

(defun decklite-db--counts ()
  "Return counter plist from database state."
  (let* ((now (current-time))
         (day-start (decklite--time->fsrs-timestamp
                     (decklite--day-start-time now)))
         (review-cutoff (decklite--time->fsrs-timestamp
                         (decklite--next-day-start-time now)))
         (learning-cutoff (decklite--time->fsrs-timestamp now))
         (reviewed (decklite-db--count
                    "SELECT COUNT(*) FROM cards
                     WHERE archived_at IS NULL
                       AND last_review IS NOT NULL
                       AND last_review >= ?
                       AND last_review < ?;"
                    (list day-start review-cutoff)))
         (due-review (decklite-db--count
                      "SELECT COUNT(*) FROM cards
                       WHERE archived_at IS NULL
                         AND last_review IS NOT NULL
                         AND state = 'review'
                         AND due <= ?;"
                      (list review-cutoff)))
         (due-learning (decklite-db--count
                        "SELECT COUNT(*) FROM cards
                         WHERE archived_at IS NULL
                           AND last_review IS NOT NULL
                           AND state IN ('learning', 'relearning')
                           AND due <= ?;"
                        (list learning-cutoff)))
         (new (decklite-db--count
               "SELECT COUNT(*) FROM cards WHERE archived_at IS NULL AND last_review IS NULL;"
               nil)))
    (list :reviewed reviewed :due-review due-review :due-learning due-learning :new new)))

;; Calendar queries

(defun decklite-db--due-counts-by-date (day-start cutoff)
  "Return due-card counts grouped by date.

DAY-START and CUTOFF are time values that bound the query.

Return a plist with keys:
- :rows    list of (DATE-STRING COUNT) rows
- :overdue count of cards due before DAY-START."
  (let* ((conn (decklite-db--ensure))
         (day-start-ts (decklite--time->fsrs-timestamp day-start))
         (cutoff-ts (decklite--time->fsrs-timestamp cutoff))
         (offset (format "%+d hours"
                         (- (decklite--clamp decklite-day-rollover-hour 0 23))))
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
         (overdue-row
          (car (sqlite-select
                conn
                "SELECT COUNT(*) FROM cards
                 WHERE archived_at IS NULL
                   AND last_review IS NOT NULL
                   AND due < ?;"
                (list day-start-ts))))
         (overdue-count (if overdue-row (car overdue-row) 0)))
    (list :rows rows :overdue overdue-count)))

;; JSON export and import

(defun decklite-db--timestamp-utc (&optional time)
  "Return TIME formatted as a UTC timestamp for filenames."
  (format-time-string "%Y%m%dT%H%M%SZ" (or time (current-time)) "UTC0"))

(defun decklite-db--export-default-file ()
  "Return the default JSON export file path."
  (expand-file-name
   (format "decklite-export-%s.json"
           (decklite-db--timestamp-utc))
   decklite-directory))

(defun decklite-db--json-alist-get (record key)
  "Return KEY value from RECORD alist, accepting symbol or string keys."
  (or (alist-get key record nil nil #'equal)
      (alist-get (symbol-name key) record nil nil #'equal)))

(defun decklite-db--import-record->card (record)
  "Convert JSON RECORD alist to (WORD META ARCHIVED-AT)."
  (unless (listp record)
    (error "Invalid JSON record: expected object, got %S" record))
  (let* ((now (fsrs-now))
         (word (decklite-db--normalize-word
                (decklite-db--json-alist-get record 'word)))
         (state (or (decklite--normalize-fsrs-state
                     (decklite-db--json-alist-get record 'state))
                    :learning))
         (step-raw (decklite-db--json-alist-get record 'step))
         ;; Step is meaningful for learning/relearning.
         ;; Keep review cards at nil when step is missing.
         (step (if (numberp step-raw)
                   step-raw
                 (if (eq state :review) nil 0)))
         (meta (make-decklite-card-meta
                :added-date (or (decklite-db--json-alist-get record 'added_date) now)
                :last-review (decklite-db--json-alist-get record 'last_review)
                :due (or (decklite-db--json-alist-get record 'due) now)
                :state state
                :step step
                :stability (decklite-db--json-alist-get record 'stability)
                :difficulty (decklite-db--json-alist-get record 'difficulty)
                :hint (decklite-db--normalize-hint
                       (decklite-db--json-alist-get record 'hint))))
         (archived-at (decklite-db--json-alist-get record 'archived_at)))
    (list word meta archived-at)))

(defun decklite-db--import-read-conflict-choice (word)
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

(defun decklite-db--apply-import-card (word meta archived-at)
  "Upsert WORD with META, then apply ARCHIVED-AT flag."
  (decklite-db--upsert-card word meta)
  (if archived-at
      (decklite-db--archive-card word archived-at)
    (decklite-db--unarchive-card word)))

(defun decklite-db--import-json-file (file)
  "Import cards from JSON FILE.
Return a plist with :added, :overwritten, and :skipped."
  (let ((global-conflict-action nil)
        (added 0)
        (overwritten 0)
        (skipped 0))
    (unless (file-exists-p file)
      (user-error "Import file does not exist: %s" file))
    (with-temp-buffer
      (insert-file-contents file)
      (let ((records (json-parse-buffer :object-type 'alist
                                        :array-type 'list
                                        :null-object nil
                                        :false-object nil)))
        (unless (listp records)
          (error "Import JSON must be an array of card objects"))
        (dolist (record records)
          (pcase-let ((`(,word ,meta ,archived-at)
                       (decklite-db--import-record->card record)))
            (if (decklite-db--select-card word)
                (let ((action (or global-conflict-action
                                  (let ((decision (decklite-db--import-read-conflict-choice word)))
                                    (setq global-conflict-action (or (cdr decision) global-conflict-action))
                                    (car decision)))))
                  (pcase action
                    (:skip
                     (cl-incf skipped))
                    (:overwrite
                     (decklite-db--apply-import-card word meta archived-at)
                     (cl-incf overwritten))
                    (_
                     (error "Unknown import action: %S" action))))
              (decklite-db--apply-import-card word meta archived-at)
              (cl-incf added))))))
    (list :added added :overwritten overwritten :skipped skipped)))

;;;###autoload
(defun decklite-db-export-json (&optional file)
  "Export all cards to JSON FILE.
When called interactively, prompt for FILE and default to a timestamped
file under `decklite-directory'."
  (interactive
   (let ((default (decklite-db--export-default-file)))
     (list (read-file-name "Export JSON to: "
                           (file-name-directory default)
                           nil nil
                           (file-name-nondirectory default)))))
  (unless (file-exists-p decklite-db-file)
    (user-error "No database file found; nothing to export"))

  (let* ((rows (sqlite-select
                (decklite-db--ensure)
                "SELECT word, added_date, last_review, due, archived_at, state,
                        step, stability, difficulty, hint
                 FROM cards
                 ORDER BY added_date ASC, word ASC;"))
         (fields '(word added_date last_review due archived_at state
                        step stability difficulty hint))
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
      (message "Exported %d cards to %s" (length payload) file))))

;;;###autoload
(defun decklite-db-import-json (&optional file)
  "Import cards from JSON FILE into the database.
When called interactively, prompt for FILE under `decklite-directory'."
  (interactive
   (let ((default (expand-file-name "decklite-import.json" decklite-directory)))
     (list (read-file-name "Import JSON from: "
                           (file-name-directory default)
                           nil t
                           (file-name-nondirectory default)))))
  (let* ((file (or file (expand-file-name "decklite-import.json" decklite-directory)))
         (result (decklite-db--import-json-file file)))
    (when (called-interactively-p 'any)
      (message "Import finished: %d added, %d overwritten, %d skipped"
               (plist-get result :added)
               (plist-get result :overwritten)
               (plist-get result :skipped)))
    result))

;; Backups

(defcustom decklite-backup-directory
  (expand-file-name "backups" decklite-directory)
  "Directory for DeckLite database backups."
  :type 'file
  :group 'decklite-db)

(defcustom decklite-backup-retain-days 30
  "Number of days to keep database backups."
  :type 'integer
  :group 'decklite-db)

(defcustom decklite-backup-prune-min-count 10
  "Minimum number of backups before pruning old ones."
  :type 'integer
  :group 'decklite-db)

(defcustom decklite-backup-prune-max-count nil
  "Prune when backup count exceeds this number.
When nil, this threshold is disabled."
  :type '(choice (const :tag "Disabled" nil) integer)
  :group 'decklite-db)

(defcustom decklite-backup-prune-confirm t
  "Whether to confirm before pruning backups."
  :type 'boolean
  :group 'decklite-db)

(defcustom decklite-backup-restore-completion-setup
  (lambda ()
    '((vertico-sort-override-function . identity)))
  "Function returning temporary completion bindings for backup restore.
When non-nil, it is called with no arguments inside
`decklite-db-restore` and should return an alist of
\(SYMBOL . VALUE) pairs to bind dynamically around `completing-read`."
  :type 'function
  :group 'decklite-db)

(defun decklite-db--backup-target (backup-dir base timestamp)
  "Return a unique backup filename in BACKUP-DIR using BASE and TIMESTAMP."
  (let ((suffix 0))
    (cl-loop for candidate = (expand-file-name
                              (format "%s-%s%s.sqlite"
                                      base
                                      timestamp
                                      (if (zerop suffix) "" (format "-%d" suffix)))
                              backup-dir)
             while (file-exists-p candidate)
             do (cl-incf suffix)
             finally return candidate)))

(defun decklite-db--backup-prune (backup-dir base)
  "Prune old backups in BACKUP-DIR for BASE when thresholds are met."
  ;; Only proceed if config values are valid.
  ;; This keeps us from pruning on misconfigured or zero-ish values.
  (when (and (integerp decklite-backup-retain-days)
             (> decklite-backup-retain-days 0)
             (integerp decklite-backup-prune-min-count)
             (> decklite-backup-prune-min-count 0))
    ;; Find all backup files for the current DB base name.
    (let* ((pattern (format "\\`%s-[0-9]\\{8\\}T[0-9]\\{6\\}Z\\.sqlite\\'"
                            (regexp-quote base)))
           (files (directory-files backup-dir t pattern))
           (count (length files))
           (max-exceeded (and (integerp decklite-backup-prune-max-count)
                              (> decklite-backup-prune-max-count 0)
                              (> count decklite-backup-prune-max-count))))
      ;; Only prune if we have minimum count or exceeded maximum.
      (when (or (>= count decklite-backup-prune-min-count) max-exceeded)
        ;; Calculate cutoff date and find old files.
        (let* ((cutoff-time (time-subtract (current-time)
                                           (days-to-time decklite-backup-retain-days)))
               (files-by-age (sort (copy-sequence files)
                                   (lambda (a b)
                                     (time-less-p (file-attribute-modification-time (file-attributes a))
                                                  (file-attribute-modification-time (file-attributes b))))))
               (old-files (seq-filter (lambda (file)
                                        (time-less-p (file-attribute-modification-time (file-attributes file))
                                                     cutoff-time))
                                      files-by-age))
               (to-delete old-files))
          ;; If max exceeded, delete oldest files regardless of age.
          (when max-exceeded
            (let ((excess-count (- count decklite-backup-prune-max-count)))
              (setq to-delete (seq-take files-by-age excess-count))))
          ;; Ask user (optional) and delete.
          (when (and to-delete
                     (or (not decklite-backup-prune-confirm)
                         (yes-or-no-p (format "Prune %d backup(s) from %s? "
                                              (length to-delete)
                                              (abbreviate-file-name backup-dir)))))
            (dolist (file to-delete)
              ;; Always trash, just to be safe.
              (condition-case err
                  (delete-file file t)
                (error
                 (message "DeckLite: backup prune failed for %s: %s"
                          (abbreviate-file-name file)
                          (error-message-string err)))))))))))

(defun decklite-db--backup ()
  "Create a database backup and prune old backups."
  (let* ((backup-dir (file-name-as-directory decklite-backup-directory))
         (base (file-name-base decklite-db-file))
         (timestamp (decklite-db--timestamp-utc))
         (backup-file (decklite-db--backup-target backup-dir base timestamp)))
    (make-directory backup-dir t)
    (copy-file decklite-db-file backup-file t t t)
    (decklite-db--backup-prune backup-dir base)))

(defun decklite-db--backup-timestamp (file)
  "Return the backup timestamp for FILE, or nil if unavailable."
  (let ((pattern (format "\\`%s-\\([0-9]\\{8\\}T[0-9]\\{6\\}Z\\)"
                         (regexp-quote (file-name-base decklite-db-file))))
        (filename (file-name-base file)))
    (when (string-match pattern filename)
      (condition-case nil
          (date-to-time (match-string 1 filename))
        (error nil)))))

(defun decklite-db--backup-files ()
  "Return backup files sorted by newest timestamp first."
  (let* ((backup-dir (file-name-as-directory decklite-backup-directory))
         (base (file-name-base decklite-db-file))
         (pattern (format "\\`%s-[0-9]\\{8\\}T[0-9]\\{6\\}Z\\(-[0-9]+\\)?\\.sqlite\\'"
                          (regexp-quote base)))
         (files (when (file-directory-p backup-dir)
                  (directory-files backup-dir t pattern))))
    (sort (or files '())
          (lambda (a b)
            (let ((ta (or (decklite-db--backup-timestamp a)
                          (file-attribute-modification-time (file-attributes a))))
                  (tb (or (decklite-db--backup-timestamp b)
                          (file-attribute-modification-time (file-attributes b)))))
              (time-less-p tb ta))))))

(defun decklite-db--backup-choice-label (file)
  "Return a display label for backup FILE."
  (format "%s (%s)"
          (file-name-base file)
          (format-time-string "%Y-%m-%d %H:%M:%S"
                              (file-attribute-modification-time
                               (file-attributes file)))))

(defun decklite-db--read-backup-choice (choices default)
  "Read backup choice from CHOICES with DEFAULT using completion."
  (let* ((bindings (when (functionp decklite-backup-restore-completion-setup)
                     (funcall decklite-backup-restore-completion-setup)))
         (symbols (mapcar #'car bindings))
         (values (mapcar #'cdr bindings)))
    (if bindings
        (cl-progv symbols values
          (completing-read "Restore backup: " choices nil t nil nil default))
      (completing-read "Restore backup: " choices nil t nil nil default))))

;;;###autoload
(defun decklite-db-backup ()
  "Create a database backup if the DB has changed since the last backup."
  (interactive)
  (if (not (file-exists-p decklite-db-file))
      (when (called-interactively-p 'any)
        (message "No database file found; skipping backup"))
    (let* ((attrs (file-attributes decklite-db-file))
           (mtime (file-attribute-modification-time attrs))
           (latest-backup (car (decklite-db--backup-files)))
           (latest-mtime (when latest-backup
                           (file-attribute-modification-time
                            (file-attributes latest-backup)))))
      (if (equal mtime latest-mtime)
          (when (called-interactively-p 'any)
            (message "Backup not needed; database unchanged"))
        (decklite-db--backup)
        (when (called-interactively-p 'any)
          (message "Backup created"))))))

;;;###autoload
(defun decklite-db-restore ()
  "Restore the database from a selected backup file."
  (interactive)
  (let* ((files (decklite-db--backup-files)))
    (unless files
      (user-error "No backups found in %s" decklite-backup-directory))
    (let* ((choices (mapcar (lambda (file)
                              (cons (decklite-db--backup-choice-label file) file))
                            files))
           (default (caar choices))
           (selection (decklite-db--read-backup-choice choices default))
           (backup-file (cdr (assoc selection choices))))
      (unless backup-file
        (user-error "No backup selected"))
      (when (yes-or-no-p (format "Restore %s to %s? "
                                 (file-name-nondirectory backup-file)
                                 decklite-db-file))
        (copy-file backup-file decklite-db-file t t t)
        (message "Restored database from %s" (file-name-nondirectory backup-file))))))

;; Maintenance command

;;;###autoload
(defun decklite-open-db-file ()
  "Open the SQLite database file.
Prefer `sqlite-mode-open-file' when available."
  (interactive)
  (if (fboundp 'sqlite-mode-open-file)
      (sqlite-mode-open-file decklite-db-file)
    (find-file decklite-db-file)))

(provide 'decklite-db)
;;; decklite-db.el ends here

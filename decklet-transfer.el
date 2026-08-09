;;; decklet-transfer.el --- JSON transfer for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; JSON import and export for Decklet cards.

;;; Code:

(require 'cl-lib)
(require 'json)

(require 'decklet-core)
(require 'decklet-scheduler)
(require 'decklet-db)

;; JSON export and import

(defconst decklet-transfer--missing :decklet-transfer-missing
  "Sentinel distinguishing a missing JSON key from null and false.")

(defun decklet-transfer--export-default-file ()
  "Return the default JSON export file path."
  (expand-file-name
   (format "decklet-export-%s.json"
           (decklet--timestamp-utc))
   decklet-directory))

(defun decklet-transfer--json-alist-get-raw (record key)
  "Return KEY value from RECORD alist, accepting symbol or string keys.
Preserves the `:json-null' sentinel used by the import parser — callers
that need to distinguish \"key missing\" from \"key explicitly null\"
should use this; everyone else should prefer `decklet-transfer--json-alist-get'."
  (let ((cell (or (assoc key record)
                  (assoc (symbol-name key) record))))
    (if cell (cdr cell) decklet-transfer--missing)))

(defun decklet-transfer--json-alist-get (record key)
  "Return KEY value from RECORD alist, accepting symbol or string keys.
Collapses the `:json-null' sentinel to nil so fields that treat
missing and null equivalently (everything except hint/back) don't
have to care about the import sentinel."
  (let ((value (decklet-transfer--json-alist-get-raw record key)))
    (if (or (eq value decklet-transfer--missing)
            (eq value :json-null))
        nil
      value)))

(defun decklet-transfer--import-text-value (raw)
  "Classify RAW JSON value for an import text field like hint or back.
Return nil when the field was missing from the record, `:clear' when it
was present but JSON `null' or blank, or the trimmed non-empty string."
  (cond
   ((eq raw decklet-transfer--missing) nil)
   ((eq raw :json-null) :clear)
   ((stringp raw)
    (let ((trimmed (string-trim raw)))
      (if (string-empty-p trimmed) :clear trimmed)))
   (t (user-error "Invalid text value in import: %S" raw))))

(defun decklet-transfer--import-normalize-state (raw)
  "Normalize imported RAW scheduler state.
JSON exports may contain `new' for older Decklet data.  Store it as
`learning', since newness is derived from an empty last-review value and
FSRS only accepts learning/review/relearning scheduler states."
  (condition-case nil
      (decklet--fsrs-schedulable-state (or raw :learning))
    (error (user-error "Invalid card state in import: %S" raw))))

(defun decklet-transfer--import-valid-timestamp-p (value)
  "Return non-nil when VALUE is nil or a valid FSRS timestamp string."
  (or (null value)
      (and (stringp value)
           (condition-case nil
               (progn
                 (fsrs-timestamp-difference value value)
                 t)
             (error nil)))))

(defun decklet-transfer--import-validate-number (word field value predicate description)
  "Validate WORD's FIELD VALUE with PREDICATE, expecting DESCRIPTION."
  (unless (or (null value)
              (and (numberp value) (funcall predicate value)))
    (user-error "Card %S: %s must be %s, got %S"
                word field description value)))

(defun decklet-transfer--import-validate-card (card)
  "Validate imported CARD metadata and return CARD."
  (let* ((word (plist-get card :word))
         (meta (plist-get card :meta))
         (state (decklet-card-meta-state meta))
         (step (decklet-card-meta-step meta))
         (last-review (decklet-card-meta-last-review meta)))
    (dolist (field-value
             `(("added_date" ,(decklet-card-meta-added-date meta))
               ("last_review" ,last-review)
               ("due" ,(decklet-card-meta-due meta))
               ("archived_at" ,(plist-get card :archived-at))))
      (unless (decklet-transfer--import-valid-timestamp-p (cadr field-value))
        (user-error "Card %S: %s must be a valid FSRS timestamp, got %S"
                    word (car field-value) (cadr field-value))))
    (unless (or (and (eq state :review) (null step))
                (and (integerp step) (>= step 0)))
      (user-error "Card %S: step must be a non-negative integer, got %S"
                  word step))
    (decklet-transfer--import-validate-number
     word "stability" (decklet-card-meta-stability meta)
     (lambda (value) (> value 0)) "a positive number")
    (decklet-transfer--import-validate-number
     word "difficulty" (decklet-card-meta-difficulty meta)
     (lambda (value) (and (>= value 1) (<= value 10)))
     "a number between 1 and 10")
    (if (null last-review)
        (progn
          (unless (eq state :learning)
            (user-error "Card %S: a never-reviewed card must use learning state"
                        word))
          (when (or (decklet-card-meta-stability meta)
                    (decklet-card-meta-difficulty meta))
            (user-error
             "Card %S: a never-reviewed card cannot have stability or difficulty"
             word)))
      (unless (and (decklet-card-meta-stability meta)
                   (decklet-card-meta-difficulty meta))
        (user-error
         "Card %S: a reviewed card requires stability and difficulty" word)))
    card))

(defun decklet-transfer--import-record->card (record)
  "Convert JSON RECORD alist to a card plist.
Returns a card plist with keys :card-id, :word, :hint, :back,
:meta, and :archived-at.  The :archived-at key is specific to the
import flow and is not present on cards produced by
`decklet-db--row->card'.

:hint and :back use the tri-state encoding from
`decklet-transfer--import-text-value': nil (missing — preserve existing
value on overwrite), `:clear' (present as JSON null or blank —
clear existing value on overwrite), or a normalized non-empty
string."
  (unless (listp record)
    (user-error "Invalid JSON record: expected object, got %S" record))
  (let* ((now (decklet--now))
         (word (decklet-db--normalize-word
                (decklet-transfer--json-alist-get record 'word)))
         (state (decklet-transfer--import-normalize-state
                 (decklet-transfer--json-alist-get record 'state)))
         (step-raw (decklet-transfer--json-alist-get record 'step))
         ;; Step is meaningful for learning/relearning.
         ;; Keep review cards at nil when step is missing.
         (step (cond
                ((null step-raw) (if (eq state :review) nil 0))
                ((numberp step-raw) step-raw)
                (t step-raw)))
         (meta (make-decklet-card-meta
                :card-id (decklet-db--mint-card-id)
                :added-date (or (decklet-transfer--json-alist-get record 'added_date) now)
                :last-review (decklet-transfer--json-alist-get record 'last_review)
                :due (or (decklet-transfer--json-alist-get record 'due) now)
                :state state
                :step step
                :stability (decklet-transfer--json-alist-get record 'stability)
                :difficulty (decklet-transfer--json-alist-get record 'difficulty)))
         (hint (decklet-transfer--import-text-value
                (decklet-transfer--json-alist-get-raw record 'hint)))
         (back (decklet-transfer--import-text-value
                (decklet-transfer--json-alist-get-raw record 'back)))
         (archived-at (decklet-transfer--json-alist-get record 'archived_at)))
    (decklet-transfer--import-validate-card
     (list :card-id (decklet-card-meta-card-id meta)
           :word word
           :hint hint
           :back back
           :meta meta
           :archived-at archived-at))))

(defun decklet-transfer--import-read-conflict-choice (word)
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

(defun decklet-transfer--apply-import-text-field (card-id field value overwrite-p)
  "Apply FIELD (`hint' or `back') VALUE for CARD-ID during import.
VALUE uses the tri-state encoding from `decklet-transfer--import-text-value'.
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

(defun decklet-transfer--apply-import-card (card overwrite-p)
  "Upsert CARD into the database and apply its archive flag.
CARD is the plist returned by `decklet-transfer--import-record->card'.
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
      (decklet-transfer--apply-import-text-field card-id 'hint hint overwrite-p)
      (decklet-transfer--apply-import-text-field card-id 'back back overwrite-p)
      (if archived-at
          (decklet-db--archive-card card-id archived-at)
        (when overwrite-p
          (decklet-db--unarchive-card card-id)))
      card-id)))

(defun decklet-transfer--import-json-file (file)
  "Import cards from JSON FILE.
Return a plist with :added, :overwritten, and :skipped."
  ;; Parse with `:json-null' as the null sentinel so hint/back can
  ;; distinguish "key missing" (nil) from "key explicitly null"
  ;; (`:json-null').  `decklet-transfer--import-text-value' collapses both
  ;; null and blank strings into the `:clear' marker downstream.
  (let ((records (with-temp-buffer
                   (insert-file-contents file)
                   (json-parse-buffer :object-type 'alist
                                      :array-type 'array
                                      :null-object :json-null
                                      :false-object :json-false))))
    (unless (vectorp records)
      (user-error "Import JSON must be an array of card objects"))
    (setq records (append records nil))
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
                       (let* ((card (decklet-transfer--import-record->card record))
                              (word (plist-get card :word)))
                         (when (gethash word seen-words)
                           (user-error "Duplicate word in import file: %s" word))
                         (puthash word t seen-words)
                         (let ((action (if (decklet-db--select-card-row-by-word word)
                                           (or global-conflict-action
                                               (let ((decision (decklet-transfer--import-read-conflict-choice word)))
                                                 (setq global-conflict-action (cdr decision))
                                                 (car decision)))
                                         :add)))
                           (cons card action))))
                     records))
           (added 0) (overwritten 0) (skipped 0)
           (added-card-ids nil)
           (overwritten-card-ids nil))
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
                     (push (decklet-transfer--apply-import-card card nil)
                           added-card-ids)
                     (cl-incf added))
                    (:skip
                     (cl-incf skipped))
                    (:overwrite
                     (push (decklet-transfer--apply-import-card card t)
                           overwritten-card-ids)
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
        (decklet-run-hook-isolated
         'decklet-cards-added-functions
         (mapcar (lambda (card-id) (list :card-id card-id))
                 (nreverse added-card-ids))))
      (when overwritten-card-ids
        (decklet-run-hook-isolated
         'decklet-cards-field-updated-functions
         (mapcar (lambda (card-id) (list :card-id card-id :field 'import))
                 (nreverse overwritten-card-ids))))
      (list :added added :overwritten overwritten :skipped skipped))))

;;;###autoload
(defun decklet-db-export-json (&optional file)
  "Export all cards to JSON FILE.
When called interactively, prompt for FILE and default to a timestamped
file under `decklet-directory'."
  (interactive
   (let ((default (decklet-transfer--export-default-file)))
     (list (read-file-name "Export JSON to: "
                           (file-name-directory default)
                           nil nil
                           (file-name-nondirectory default)))))
  (unless (file-exists-p decklet-db-file)
    (user-error "No database file found; nothing to export"))
  (unwind-protect
      (let* ((file (or file (decklet-transfer--export-default-file)))
             (rows (sqlite-select
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

        (when-let* ((dir (file-name-directory file)))
          (make-directory dir t))
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
             (result (decklet-transfer--import-json-file file)))
        (when (called-interactively-p 'any)
          (message "Import finished: %d added, %d overwritten, %d skipped"
                   (plist-get result :added)
                   (plist-get result :overwritten)
                   (plist-get result :skipped)))
        result)
    (decklet-db--disconnect-if-idle)))


(provide 'decklet-transfer)
;;; decklet-transfer.el ends here

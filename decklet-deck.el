;;; decklet-deck.el --- Deck operations for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yilin Zhang

;;; Commentary:

;; Core card/deck operations shared by UI modules.

;;; Code:

(require 'cl-lib)
(require 'crm)
(require 'seq)
(require 'subr-x)

(require 'decklet-core)
(require 'decklet-scheduler)
(require 'decklet-db)
(require 'decklet-review-log)

(defcustom decklet-add-and-refresh t
  "When non-nil, re-adding an unreviewed word resets its timestamps."
  :type 'boolean
  :group 'decklet)

(defvar decklet-current-card-id nil
  "The current card id being reviewed.")

(defvar decklet-last-added-word nil
  "Most recently added word outside review.")

(defvar decklet-due-card-ids nil
  "List of card ids that are due for review.")

(defun decklet--refresh-counter ()
  "Refresh counters from database state."
  (setq decklet--counter (decklet-db--counts)))

(defun decklet--refresh-due-card-ids ()
  "Refresh the due card-id list if a review session is active."
  (setq decklet-due-card-ids (decklet-db--select-due-card-ids)))

(defun decklet--require-current-card-id (action)
  "Return the current card id, or report ACTION and return nil.
ACTION should be a verb phrase used in the fallback message."
  (when (not decklet-current-card-id)
    (user-error "No word to %s" action))
  decklet-current-card-id)

(defun decklet--resolve-word (word &optional prompt)
  "Return WORD if non-nil, otherwise resolve from context.
If region is active, use its trimmed text.  Otherwise, use the current
review word in review mode, the word at the current edit line in edit
mode, or prompt with a default from word at point.  PROMPT is used when
a minibuffer prompt is needed."
  (if word
      word
    (let ((region-text (when (use-region-p)
                         (string-trim
                          (buffer-substring-no-properties
                           (region-beginning)
                           (region-end))))))
      (cond
       ((use-region-p)
        (if (string-empty-p region-text)
            (user-error "Selected text is empty")
          region-text))
       ((derived-mode-p 'decklet-review-mode)
        (or (and decklet-current-card-id
                 (decklet-get-card-word decklet-current-card-id))
            (user-error "No word to use")))
       ((derived-mode-p 'decklet-edit-mode)
        (let ((card-id (tabulated-list-get-id)))
          (if card-id
              (or (decklet-get-card-word card-id)
                  (user-error "No word on this line"))
            (user-error "No word on this line"))))
       (t
        (let* ((default (thing-at-point 'word t))
               (input (read-string (or prompt "Word: ") default))
               (trimmed (string-trim input)))
          (if (string-empty-p trimmed)
              (user-error "Word cannot be empty")
            trimmed)))))))

;; Public API — card accessors
;;
;; These are the stable entry points extensions should use instead of
;; reaching into `decklet-db--' internals.  Internal identity is always
;; `card_id'; callers that start from a word should resolve the card row
;; first, then operate by id.

(defun decklet-get-card (card-id)
  "Return card data for CARD-ID as a plist, or nil if not found."
  (let ((row (decklet-db--select-card-row card-id)))
    (when row
      (decklet-db--row->card row))))

(defun decklet-require-card (card-id)
  "Return card data for CARD-ID as a plist, or signal a `user-error'."
  (or (decklet-get-card card-id)
      (user-error "No card found for id %s" card-id)))

(defun decklet-get-card-hint (card-id)
  "Return the hint string for CARD-ID, or nil when absent."
  (decklet-db--select-card-hint card-id))

(defun decklet-get-card-back (card-id)
  "Return the card back content for CARD-ID, or nil when absent."
  (decklet-db--select-card-back card-id))

(defun decklet-get-card-meta (card-id)
  "Return the `decklet-card-meta' struct for CARD-ID, or nil when absent."
  (let ((row (decklet-db--select-card-row card-id)))
    (when row
      (decklet-db--row->card-meta row))))

(defun decklet-get-card-word (card-id)
  "Return the current word for CARD-ID, or nil when absent."
  (decklet-db--select-card-word card-id))

(defun decklet-get-card-id-by-word (word)
  "Return the card id for WORD, or nil when absent."
  (plist-get (decklet-db--select-card-row-by-word word) :card-id))

(defun decklet-card-exists-p (card-id)
  "Return non-nil when CARD-ID has a card in the deck."
  (decklet-db--card-exists-p card-id))

(defun decklet-list-words (&optional filter)
  "Return all words in the deck as a list, optionally filtered.
FILTER is one of the symbols `all' (default), `review', `learning',
or `archived'."
  (mapcar (lambda (row) (plist-get row :word))
          (decklet-db--select-card-rows (or filter 'all))))

(defun decklet-prompt-word (&optional prompt)
  "Resolve a word from the current context or prompt for one.
If a region is active, its trimmed text is returned.  In review mode,
the current review word is used.  In edit mode, the word on the
current line is used.  Otherwise the minibuffer is read with an
optional PROMPT, defaulting to the word at point."
  (decklet--resolve-word nil prompt))

;; Public API — tags

(defun decklet-get-card-tags (card-id)
  "Return the current tag strings for CARD-ID, or nil."
  (plist-get (decklet-db--select-card-row card-id) :tags))

(defun decklet-list-tags ()
  "Return all tag names in the deck, sorted and deduplicated."
  (let ((tags nil))
    (maphash (lambda (_id names) (setq tags (append names tags)))
             (decklet-db--tag-map))
    (decklet-normalize-tags tags)))

(defun decklet-set-card-tags (card-id tags)
  "Replace CARD-ID's TAGS and return their normalized value.
Emit a field-updated event only when the tags changed."
  (let ((old (decklet-get-card-tags card-id))
        (new (decklet-normalize-tags tags)))
    (decklet-db--require-card-row card-id)
    (unless (equal old new)
      (decklet-db--update-tags card-id new)
      (decklet-fire-one-card-event 'decklet-cards-field-updated-functions
                                   :card-id card-id :field 'tags))
    new))

(defun decklet-add-card-tags (card-id tags)
  "Merge TAGS into CARD-ID's existing tags and return the result."
  (decklet-set-card-tags card-id (append (decklet-get-card-tags card-id) tags)))

(defun decklet-remove-card-tags (card-id tags)
  "Remove TAGS from CARD-ID and return the remaining tags."
  (decklet-normalize-tags tags)
  (decklet-set-card-tags card-id (seq-difference (decklet-get-card-tags card-id) tags)))

(defun decklet-read-tags (&optional initial prompt)
  "Read tag names with completion, using INITIAL names and optional PROMPT.
Names are separated by whitespace; an empty response clears the list."
  (let ((crm-separator "[ \t]+"))
    (decklet-normalize-tags
     (completing-read-multiple (or prompt "Tags (space-separated): ")
                               (decklet-list-tags) nil nil
                               (string-join initial " ")))))

(defun decklet-prompt-set-tags (card-id)
  "Prompt to replace CARD-ID's tags, returning the new list."
  (decklet-set-card-tags card-id (decklet-read-tags (decklet-get-card-tags card-id))))

;; Public API — card mutations
;;
;; Each mutation broadcasts a lifecycle event so extensions can stay
;; in sync without scanning state.  Rating and rename also append a
;; record to the persistent review log.  UI refresh for field updates
;; is handled by core subscribers registered in `decklet-review.el'
;; and `decklet-edit.el'.

(defun decklet-rate-card (card-id grade &optional prior-grade)
  "Update CARD-ID with review GRADE (1-4).
PRIOR-GRADE, when non-nil, is the rating being replaced."
  (let* ((row (decklet-db--require-card-row card-id))
         (word (plist-get row :word))
         (old-meta (decklet-db--row->card-meta row)))
    (decklet--rate-card-state card-id word old-meta grade prior-grade)))

(defun decklet--rate-card-state (card-id word old-meta grade &optional prior-grade)
  "Update CARD-ID using WORD and OLD-META with review GRADE (1-4).
PRIOR-GRADE, when non-nil, is the rating being replaced."
  (let* ((new-meta (decklet--update-meta-with-grade old-meta grade))
         (log-id (decklet-review-log-append-rated
                  word card-id grade old-meta new-meta)))
    (unless log-id
      (user-error "Could not write rating to the review log"))
    ;; Only the DB write is rolled back against the log: once it has
    ;; landed the rating stands, so a later failure must not void it.
    (condition-case err
        (decklet-db--upsert-card word new-meta)
      (error
       ;; Best-effort: retire the orphaned log record before re-signaling.
       ;; A failed void already reports itself from the log writer.
       (decklet-review-log-append-void log-id)
       (signal (car err) (cdr err))))
    (decklet--refresh-counter)
    (decklet-fire-one-card-event 'decklet-cards-rated-functions
                                 :card-id card-id
                                 :old-meta old-meta
                                 :grade grade
                                 :new-meta new-meta
                                 :prior-grade prior-grade)
    log-id))

(defun decklet-set-card-word (card-id new-word)
  "Rename CARD-ID to NEW-WORD and return the normalized new value."
  (let* ((old-word (decklet-get-card-word card-id))
         (normalized (decklet-db--update-word card-id new-word)))
    (unless (string-equal old-word normalized)
      (unless (decklet-review-log-append-rename card-id old-word normalized)
        ;; Best-effort rollback to keep DB and log consistent.
        (ignore-errors (decklet-db--update-word card-id old-word))
        (user-error "Could not write rename to the review log"))
      (when (and decklet-last-added-word
                 (string-equal old-word decklet-last-added-word))
        (setq decklet-last-added-word normalized))
      (decklet-fire-one-card-event 'decklet-cards-renamed-functions
                                   :card-id card-id
                                   :old-word old-word
                                   :new-word normalized))
    normalized))

(defun decklet-set-card-hint (card-id hint)
  "Update CARD-ID's card hint to HINT.
Return non-nil when the stored value changed."
  (let* ((row (decklet-db--require-card-row card-id))
         (normalized (decklet-db--normalize-optional-text hint)))
    (unless (equal (plist-get row :hint) normalized)
      (decklet-db--update-hint card-id normalized)
      (decklet-fire-one-card-event 'decklet-cards-field-updated-functions
                                   :card-id card-id :field 'hint)
      t)))

(defun decklet-set-card-back (card-id content)
  "Update CARD-ID's card back to CONTENT.
Return non-nil when the stored value changed."
  (let* ((row (decklet-db--require-card-row card-id))
         (normalized (decklet-db--normalize-optional-text content)))
    (unless (equal (plist-get row :back) normalized)
      (decklet-db--update-back card-id normalized)
      (decklet-fire-one-card-event 'decklet-cards-field-updated-functions
                                   :card-id card-id :field 'back)
      t)))

(defun decklet-delete-card (card-id)
  "Delete CARD-ID from the deck."
  (let ((card (decklet-require-card card-id)))
    (decklet-db--delete-card card-id)
    (when (eql decklet-current-card-id card-id)
      (setq decklet-current-card-id nil))
    (when decklet-due-card-ids
      (setq decklet-due-card-ids (delete card-id decklet-due-card-ids)))
    (decklet--refresh-counter)
    (decklet-fire-one-card-event 'decklet-cards-deleted-functions
                                 :card-id card-id :card card)))

(defun decklet-archive-card (card-id)
  "Archive CARD-ID without deleting it."
  (decklet-db--require-card-row card-id)
  (decklet-db--archive-card card-id (decklet--now))
  (when decklet-due-card-ids
    (setq decklet-due-card-ids (delete card-id decklet-due-card-ids)))
  (decklet--refresh-counter)
  (decklet-fire-one-card-event 'decklet-cards-archived-functions
                               :card-id card-id))

(defun decklet-unarchive-card (card-id)
  "Unarchive CARD-ID and return it to the active deck."
  (decklet-db--require-card-row card-id)
  (decklet-db--unarchive-card card-id)
  (decklet--refresh-counter)
  (decklet-fire-one-card-event 'decklet-cards-unarchived-functions
                               :card-id card-id))

(defun decklet-prompt-set-word (card-id)
  "Prompt for a new word for CARD-ID and rename if changed.
Return the (possibly updated) word."
  (let* ((word (decklet-get-card-word card-id))
         (new-word (read-string (format "Word (%s): " word) word)))
    (if (string-equal new-word word)
        word
      (decklet-set-card-word card-id new-word))))

(defun decklet-prompt-set-hint (card-id)
  "Prompt for a new hint for CARD-ID and set it if changed.
Return the card's word."
  (pcase-let (((map :word :hint) (decklet-require-card card-id)))
    (let* ((current (or hint ""))
           (new-hint (read-string (format "Hint (%s): " word) current)))
      (unless (string-equal new-hint current)
        (decklet-set-card-hint card-id new-hint)))
    word))

(defun decklet--add-hint-precheck ()
  "Get the target word for adding hint, or signal an error if none."
  (or decklet-last-added-word
      (user-error "No word to add a hint to")))

(defun decklet--add-card (word)
  "Add WORD as a new card and return a result plist.
Keys in the returned plist:
  :card-id  id of the card touched (always set).
  :status   one of the symbols `added', `exists', `refreshed':
            - `added'     a brand-new row was created.
            - `exists'    the word is already in the deck; nothing changed.
            - `refreshed' the word was an existing new card whose
                          added-date was refreshed in place.
  :message  human-readable status string.

Fires `decklet-cards-added-functions' only when status is `added'.
Refreshing the added date of an existing new card does not fire the
hook (the card's existence has not changed).

A brand-new row is also assigned a fresh `card-id' via
`decklet-db--mint-card-id'.  Refreshing an existing new card
preserves its existing `card-id'."
  (setq word (decklet-db--normalize-word word))
  (let* ((row (decklet-db--select-card-row-by-word word))
         (meta (and row (decklet-db--row->card-meta row))))
    (setq decklet-last-added-word word)
    (cond
     ;; Brand-new word: create a row and emit the added hook once.
     ((null meta)
      (let ((now (decklet--now)))
        (setq meta (make-decklet-card-meta :card-id (decklet-db--mint-card-id)))
        (setf (decklet-card-meta-added-date meta) now)
        (setf (decklet-card-meta-due meta) now)
        (decklet-db--upsert-card word meta)
        (let ((card-id (decklet-card-meta-card-id meta)))
          (decklet-fire-one-card-event 'decklet-cards-added-functions
                                       :card-id card-id)
          (list :card-id card-id
                :status 'added
                :message (format "Added \"%s\" to the deck. " word)))))
     ;; Existing reviewed card: do not treat it as addable again.
     ((not (decklet-card-meta-effective-state-new-p meta))
      (list :card-id (decklet-card-meta-card-id meta)
            :status 'exists
            :message (format "Word \"%s\" already exists in the deck. " word)))
     ;; Existing new card: optionally refresh its added date instead of
     ;; creating a second add event for the same card.
     ((not decklet-add-and-refresh)
      (list :card-id (decklet-card-meta-card-id meta)
            :status 'exists
            :message (format "Word \"%s\" already exists in the deck. " word)))
     ;; Refresh the existing new card in place and keep its card-id.
     (t
      (let ((now (decklet--now)))
        (setf (decklet-card-meta-added-date meta) now)
        (setf (decklet-card-meta-due meta) now)
        (decklet-db--upsert-card word meta)
        (list :card-id (decklet-card-meta-card-id meta)
              :status 'refreshed
              :message (format "Refreshed the added date of existing new word \"%s\". " word)))))))

;;;###autoload
(defun decklet-add-card (word)
  "Add WORD, then offer hint and tag editing when called interactively."
  (interactive (list (read-string "Word to add: ")))
  (let ((interactive-p (called-interactively-p 'any))
        (more t))
    (while more
      (let* ((result (decklet--add-card word))
             (card-id (plist-get result :card-id))
             (status (plist-get result :message))
             (editing interactive-p))
        (setq more nil)
        (while editing
          (pcase (read-char-choice
                  (concat status "Add another? (y/n, ENTER=yes, H=hint, t=tags): ")
                  '(?y ?n ?\r ?H ?t))
            (?H (decklet-prompt-set-hint card-id))
            (?t (decklet-prompt-set-tags card-id))
            ((or ?y ?\r)
             (setq word (read-string "Word to add: ") more t editing nil))
            (?n (setq editing nil))))))))

(defun decklet-add-hint (hint &optional target)
  "Add HINT to TARGET word, defaulting to the last added word."
  (interactive
   (let ((target (decklet--add-hint-precheck)))
     (list
      (read-string (format "Hint for \"%s\": " target)
                   (plist-get (decklet-db--require-card-row-by-word target) :hint))
      target)))
  (let ((target (or target (decklet--add-hint-precheck))))
    (let ((card-id (plist-get (decklet-db--require-card-row-by-word target) :card-id)))
      (decklet-set-card-hint card-id hint))
    (format "Updated the hint of \"%s\". " target)))

(provide 'decklet-deck)
;;; decklet-deck.el ends here

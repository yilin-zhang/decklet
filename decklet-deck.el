;;; decklet-deck.el --- Deck operations for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yilin Zhang

;;; Commentary:

;; Core card/deck operations shared by UI modules.

;;; Code:

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

;; Public API: card accessors.  Cards are identified by id; callers that
;; start from a word look the id up first.

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
  (decklet-db--select-card-field card-id 'hint))

(defun decklet-get-card-back (card-id)
  "Return the card back content for CARD-ID, or nil when absent."
  (decklet-db--select-card-field card-id 'back))

(defun decklet-get-card-meta (card-id)
  "Return the `decklet-card-meta' struct for CARD-ID, or nil when absent."
  (let ((row (decklet-db--select-card-row card-id)))
    (when row
      (decklet-db--row->card-meta row))))

(defun decklet-get-card-word (card-id)
  "Return the current word for CARD-ID, or nil when absent."
  (decklet-db--select-card-field card-id 'word))

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
  "Return the word in context, or read one with PROMPT.
The active region wins, then the review card, then the edit row.
Otherwise read from the minibuffer, starting from the word at point.
Empty text is a `user-error'."
  (cond
   ((use-region-p)
    (let ((text (string-trim (buffer-substring-no-properties
                              (region-beginning) (region-end)))))
      (if (string-empty-p text)
          (user-error "Selected text is empty")
        text)))
   ((derived-mode-p 'decklet-review-mode)
    (or (and decklet-current-card-id
             (decklet-get-card-word decklet-current-card-id))
        (user-error "No word to use")))
   ((derived-mode-p 'decklet-edit-mode)
    (or (when-let* ((card-id (tabulated-list-get-id)))
          (decklet-get-card-word card-id))
        (user-error "No word on this line")))
   (t
    (let ((input (string-trim
                  (read-string (or prompt "Word: ")
                               (thing-at-point 'word t)))))
      (if (string-empty-p input)
          (user-error "Word cannot be empty")
        input)))))

;; Public API: tags

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
    (minibuffer-with-setup-hook
        (lambda ()
          (let ((map (copy-keymap (current-local-map))))
            (define-key map (kbd "SPC") #'self-insert-command)
            (use-local-map map)))
      (decklet-normalize-tags
       (completing-read-multiple (or prompt "Tags (space-separated): ")
                                 (decklet-list-tags) nil nil
                                 (string-join initial " "))))))

(defun decklet-prompt-set-tags (card-id)
  "Prompt to replace CARD-ID's tags, returning the new list."
  (decklet-set-card-tags card-id (decklet-read-tags (decklet-get-card-tags card-id))))

;; Public API: card mutations.  Each fires a lifecycle event; rating
;; and renaming also write to the review log.

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
    ;; Only a failed DB write voids the log record.  Once the write has
    ;; landed the rating stands, even if a later step fails.
    (condition-case err
        (decklet-db--update-card-meta card-id new-meta)
      (error
       ;; The rating never reached the DB, so void its log record.
       (decklet-review-log-append-void log-id)
       (signal (car err) (cdr err))))
    (decklet-fire-one-card-event 'decklet-cards-rated-functions
                                 :card-id card-id
                                 :old-meta old-meta
                                 :grade grade
                                 :new-meta new-meta
                                 :prior-grade prior-grade)
    log-id))

(defun decklet-set-card-word (card-id new-word)
  "Rename CARD-ID to NEW-WORD and return the normalized new value."
  (let ((old-word (decklet-get-card-word card-id))
        (normalized (decklet--normalize-word new-word)))
    (decklet-db--update-word card-id normalized)
    (unless (string-equal old-word normalized)
      (decklet-review-log-append-rename card-id old-word normalized)
      (decklet-fire-one-card-event 'decklet-cards-renamed-functions
                                   :card-id card-id
                                   :old-word old-word
                                   :new-word normalized))
    normalized))

(defun decklet-set-card-hint (card-id hint)
  "Update CARD-ID's card hint to HINT.
Return non-nil when the stored value changed."
  (let* ((row (decklet-db--require-card-row card-id))
         (normalized (decklet--normalize-optional-text hint)))
    (unless (equal (plist-get row :hint) normalized)
      (decklet-db--update-card-text-field card-id 'hint normalized)
      (decklet-fire-one-card-event 'decklet-cards-field-updated-functions
                                   :card-id card-id :field 'hint)
      t)))

(defun decklet-set-card-back (card-id content)
  "Update CARD-ID's card back to CONTENT.
Return non-nil when the stored value changed."
  (let* ((row (decklet-db--require-card-row card-id))
         (normalized (decklet--normalize-optional-text content)))
    (unless (equal (plist-get row :back) normalized)
      (decklet-db--update-card-text-field card-id 'back normalized)
      (decklet-fire-one-card-event 'decklet-cards-field-updated-functions
                                   :card-id card-id :field 'back)
      t)))

(defun decklet-delete-card (card-id)
  "Delete CARD-ID from the deck."
  (let ((card (decklet-require-card card-id)))
    (decklet-db--delete-card card-id)
    (decklet-fire-one-card-event 'decklet-cards-deleted-functions
                                 :card-id card-id :card card)))

(defun decklet-archive-card (card-id)
  "Archive CARD-ID without deleting it."
  (let ((row (decklet-db--require-card-row card-id)))
    (unless (plist-get row :archived-at)
      (decklet-db--set-card-archived-at card-id (decklet--now))
      (decklet-fire-one-card-event 'decklet-cards-archived-functions
                                   :card-id card-id))))

(defun decklet-unarchive-card (card-id)
  "Unarchive CARD-ID and return it to the active deck."
  (let ((row (decklet-db--require-card-row card-id)))
    (when (plist-get row :archived-at)
      (decklet-db--set-card-archived-at card-id nil)
      (decklet-fire-one-card-event 'decklet-cards-unarchived-functions
                                   :card-id card-id))))

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

(defun decklet--add-card (word)
  "Add WORD as a new card and return a plist describing what happened.
The plist has the touched card's :card-id, a :message for the user,
and a :status of `added' for a new card, `refreshed' when an unreviewed
card got a new added date, or `exists' when nothing changed.  Only an
added card fires `decklet-cards-added-functions'."
  (setq word (decklet--normalize-word word))
  (let* ((row (decklet-db--select-card-row-by-word word))
         (meta (and row (decklet-db--row->card-meta row))))
    (cond
     ;; A brand-new word gets a row and one added event.
     ((null meta)
      (let ((now (decklet--now)))
        (setq meta (make-decklet-card-meta :card-id (decklet-db--mint-card-id)))
        (setf (decklet-card-meta-added-date meta) now)
        (setf (decklet-card-meta-due meta) now)
        (decklet-db--insert-card word meta)
        (let ((card-id (decklet-card-meta-card-id meta)))
          (decklet-fire-one-card-event 'decklet-cards-added-functions
                                       :card-id card-id)
          (list :card-id card-id
                :status 'added
                :message (format "Added \"%s\" to the deck. " word)))))
     ;; An archived card is left archived and reported explicitly.
     ((plist-get row :archived-at)
      (list :card-id (decklet-card-meta-card-id meta)
            :status 'exists
            :message (format "Word \"%s\" already exists in the deck (archived). " word)))
     ;; A reviewed card is left alone.  A still-new card is refreshed
     ;; only when `decklet-add-and-refresh' is on.
     ((or (not (eq (decklet-card-meta-effective-state meta) :new))
          (not decklet-add-and-refresh))
      (list :card-id (decklet-card-meta-card-id meta)
            :status 'exists
            :message (format "Word \"%s\" already exists in the deck. " word)))
     ;; Refresh the existing new card in place and keep its card-id.
     (t
      (let ((now (decklet--now))
            (card-id (decklet-card-meta-card-id meta)))
        (setf (decklet-card-meta-added-date meta) now)
        (setf (decklet-card-meta-due meta) now)
        (decklet-db--update-card-meta card-id meta)
        (decklet-fire-one-card-event 'decklet-cards-field-updated-functions
                                     :card-id card-id :field 'added-date)
        (list :card-id card-id
              :status 'refreshed
              :message (format "Refreshed the added date of existing new word \"%s\". " word)))))))

;;;###autoload
(defun decklet-add-card (word)
  "Add WORD, then offer hint and tag editing when called interactively."
  (interactive (list (read-string "Word to add: ")))
  (let ((interactive-p (called-interactively-p 'any))
        (more t))
    (decklet-with-db
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
              (?n (setq editing nil)))))))))

(provide 'decklet-deck)
;;; decklet-deck.el ends here

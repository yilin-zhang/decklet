;;; decklet-deck.el --- Deck operations for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Core card/deck operations shared by UI modules.

;;; Code:

(require 'cl-lib)
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

(defvar decklet-add-card-batch-buffer-name "*Decklet Batch Add*"
  "Buffer name used for batch card entry.")

(defvar decklet-due-card-ids nil
  "List of card ids that are due for review.")

(defvar-local decklet-add-card-batch--on-confirm nil
  "Function called after batch add confirmation.
Receives a list of added words.")

(defvar-local decklet-add-card-batch--on-cancel nil
  "Function called after batch add cancellation.")

(defvar decklet-add-card-batch-mode-map
  (define-keymap
    "C-c C-c" #'decklet-add-card-batch-confirm
    "C-c C-k" #'decklet-add-card-batch-cancel)
  "Keymap for `decklet-add-card-batch-mode'.")

(defconst decklet--batch-hint-re "^[ \t]*#\\(.*\\)"
  "Regex matching a hint line.  Group 1 captures the hint text.")

(decklet-defface decklet-add-card-batch-word-face
  `((t :foreground ,(face-attribute 'decklet-color-word :foreground)
       :weight bold))
  "Face for word lines in batch card entry."
  :group 'decklet)

(defvar decklet-add-card-batch-font-lock-keywords
  `((,decklet--batch-hint-re
     (0 'font-lock-comment-face)
     (1 'default t))
    ("^[ \t]*\\([^ \t\n].*\\)$"
     (1 (unless (string-match-p decklet--batch-hint-re
                                (match-string-no-properties 0))
          'decklet-add-card-batch-word-face))))
  "Font-lock rules for `decklet-add-card-batch-mode'.")

(define-derived-mode decklet-add-card-batch-mode text-mode "Decklet-Batch"
  "Major mode for editing batch word entries.
Word lines are emphasized; only the hint prefix is subdued."
  ;; Hint lines are data, not comments, and only a leading `#' is special.
  ;; Configure comment commands without teaching the syntax table that every
  ;; `#' starts a comment (which would misclassify words such as "C#").
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "#+[ \t]*")
  (setq-local font-lock-defaults '(decklet-add-card-batch-font-lock-keywords))
  (font-lock-refresh-defaults))

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

(defun decklet--commit-card-rating (card-id word old-meta new-meta grade prior-grade)
  "Store CARD-ID's rating and notify consumers.
WORD, OLD-META, NEW-META, GRADE, and PRIOR-GRADE describe the rating."
  (decklet-db--upsert-card word new-meta)
  (decklet--refresh-counter)
  (decklet-fire-one-card-event 'decklet-cards-rated-functions
                               :card-id card-id
                               :old-meta old-meta
                               :grade grade
                               :new-meta new-meta
                               :prior-grade prior-grade))

(defun decklet--rate-card-state (card-id word old-meta grade &optional prior-grade)
  "Update CARD-ID using WORD and OLD-META with review GRADE (1-4).
PRIOR-GRADE, when non-nil, is the rating being replaced."
  (let* ((new-meta (decklet--update-meta-with-grade old-meta grade))
         (log-id (decklet-review-log-append-rated
                  word card-id grade old-meta new-meta)))
    (unless log-id
      (user-error "Could not write rating to the review log"))
    (condition-case err
        (decklet--commit-card-rating
         card-id word old-meta new-meta grade prior-grade)
      (error
       ;; Best-effort: retire the orphaned log record before re-signaling.
       ;; A failed void already reports itself from the log writer.
       (decklet-review-log-append-void log-id)
       (signal (car err) (cdr err))))
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
  "Add WORD as a new card.
After adding a card, prompts if you want to add another."
  (interactive "sWord to add: ")
  (let ((status-msg (plist-get (decklet--add-card word) :message)))
    (when (called-interactively-p 'any)
      (let ((choice (read-char-choice
                     (concat status-msg "Add another card? (y/n, ENTER for yes, t for hint): ")
                     '(?y ?n ?\r ?t))))
        (pcase choice
          ((or ?y ?\r)
           (call-interactively #'decklet-add-card))
          (?t
           (let ((hint-status-msg (call-interactively #'decklet-add-hint)))
             (when (memq (read-char-choice
                          (concat hint-status-msg "Add another card? (y/n, ENTER for yes): ")
                          '(?y ?n ?\r))
                         '(?y ?\r))
               (call-interactively #'decklet-add-card)))))))))

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

(defun decklet--batch-clean-lines ()
  "Return non-empty trimmed lines from the current buffer.
Lines that are empty or contain only whitespace are removed."
  (seq-filter
   (lambda (line) (not (string-empty-p line)))
   (mapcar #'string-trim
           (split-string (buffer-string) "\n" nil))))

(defun decklet--batch-collect-cards ()
  "Parse current batch buffer and return card plists.
Each returned plist contains `:word' and optional `:hint'.  Any line
whose first non-whitespace character is `#' is treated as a hint line
for the most recent word.  Hint lines are joined with newlines."
  (let* ((lines (decklet--batch-clean-lines))
         (cards nil)
         (current-word nil)
         (current-hints nil)
         (flush (lambda ()
                  (when current-word
                    (push (list :word current-word
                                :hint (when current-hints
                                        (string-join (nreverse current-hints) "\n")))
                          cards)
                    (setq current-word nil
                          current-hints nil)))))
    (dolist (line lines)
      (if (string-match decklet--batch-hint-re line)
          (progn
            (unless current-word
              (user-error "Hint line must follow a word line: %s" line))
            (push (string-trim (match-string 1 line)) current-hints))
        (funcall flush)
        (setq current-word line)))
    (funcall flush)
    (nreverse cards)))

(defun decklet-add-card-batch-confirm ()
  "Confirm batch import for the current buffer.
Fires `decklet-cards-added-functions' and
`decklet-cards-field-updated-functions' once each at the end of the
import, carrying all events from this batch.

Reports an `added/refreshed/exists' breakdown after import, matching
the granularity of `decklet--add-card's status result."
  (interactive)
  (let* ((cards (decklet--batch-collect-cards))
         (conn (decklet-db--ensure))
         (added-events nil)
         (hint-events nil)
         (added 0)
         (refreshed 0)
         (exists 0))
    (sqlite-execute conn "BEGIN;")
    (condition-case err
        ;; Suppress per-card hook fires inside the loop; we fire one
        ;; batch event for each hook after COMMIT.
        (let ((decklet-cards-added-functions nil)
              (decklet-cards-field-updated-functions nil))
          (dolist (card cards)
            (let* ((word (plist-get card :word))
                   (hint (plist-get card :hint))
                   (result (decklet--add-card word))
                   (card-id (plist-get result :card-id)))
              (pcase (plist-get result :status)
                ('added     (cl-incf added)
                            (push (list :card-id card-id) added-events))
                ('refreshed (cl-incf refreshed))
                ('exists    (cl-incf exists)))
              (when (and hint (decklet-set-card-hint card-id hint))
                (push (list :card-id card-id :field 'hint) hint-events))))
          (sqlite-execute conn "COMMIT;"))
      (error
       (sqlite-execute conn "ROLLBACK;")
       (signal (car err) (cdr err))))
    (when added-events
      (decklet-run-hook-isolated 'decklet-cards-added-functions
                                 (nreverse added-events)))
    (when hint-events
      (decklet-run-hook-isolated 'decklet-cards-field-updated-functions
                                 (nreverse hint-events)))
    (when (functionp decklet-add-card-batch--on-confirm)
      (condition-case err
          (funcall decklet-add-card-batch--on-confirm
                   (mapcar (lambda (card) (plist-get card :word)) cards))
        (error
         (display-warning
          'decklet
          (format "Batch confirmation callback failed: %s"
                  (error-message-string err))
          :error))))
    (message "Imported %d: %d added, %d refreshed, %d already existed"
             (length cards) added refreshed exists))
  (quit-window t))

(defun decklet-add-card-batch-cancel ()
  "Cancel batch import and close the buffer."
  (interactive)
  (when (functionp decklet-add-card-batch--on-cancel)
    (funcall decklet-add-card-batch--on-cancel))
  (message "Batch import canceled")
  (quit-window t))

;;;###autoload
(defun decklet-add-card-batch (&optional words &rest options)
  "Open a buffer for batch word entry.
WORDS, when non-nil, are inserted one per line.
OPTIONS is a plist supporting :buffer-name, :title, :on-confirm, :on-cancel,
and :message-prefix."
  (interactive)
  (let ((buffer (get-buffer-create
                 (or (plist-get options :buffer-name)
                     decklet-add-card-batch-buffer-name))))
    (with-current-buffer buffer
      (decklet-add-card-batch-mode)
      (setq header-line-format (or (plist-get options :title) "Decklet Batch Add")
            decklet-add-card-batch--on-confirm (plist-get options :on-confirm)
            decklet-add-card-batch--on-cancel (plist-get options :on-cancel))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (when words
          (insert (string-join words "\n") "\n")))
      (goto-char (point-min)))
    (pop-to-buffer buffer)
    (message "%sType %s to confirm, %s to cancel."
             (if (string-empty-p (or (plist-get options :message-prefix) ""))
                 ""
               (concat (plist-get options :message-prefix) " "))
             (substitute-command-keys "\\[decklet-add-card-batch-confirm]")
             (substitute-command-keys "\\[decklet-add-card-batch-cancel]"))))

;; Card back popup

(defcustom decklet-card-back-buffer-major-mode 'org-mode
  "Major mode used for the card back popup buffer."
  :type 'function
  :group 'decklet)

(defvar-local decklet-card-back--card-id nil
  "Card id associated with the current card back buffer.")

(defun decklet-save-card-back ()
  "Save the card back content to db."
  (interactive)
  (let ((card-id decklet-card-back--card-id))
    (unless card-id
      (user-error "No card associated with this buffer"))
    (let ((content (buffer-substring-no-properties (point-min) (point-max))))
      (decklet-set-card-back card-id content)
      (set-buffer-modified-p nil)
      (message "Wrote card back of word \"%s\""
               (or (decklet-get-card-word card-id) "")))))

(defun decklet-card-back--write-contents ()
  "`write-contents-functions' handler for `decklet-card-back-mode'.
Saves the card back to the DB and returns non-nil so Emacs skips its
normal file-writing path — the buffer is backed by the DB, not a file."
  (decklet-save-card-back)
  t)

(defun decklet-card-back--kill-buffer-query ()
  "`kill-buffer-query-functions' handler for `decklet-card-back-mode'.
Prompts to save before killing a modified card-back buffer so edits
aren't silently lost; returns nil to cancel the kill if the user
declines both save and discard."
  (if (not (buffer-modified-p))
      t
    (pcase (read-char-choice
            (format "Card back \"%s\" modified; (s)ave, (d)iscard, or (c)ancel? "
                    (buffer-name))
            '(?s ?d ?c))
      (?s (decklet-save-card-back) t)
      (?d (set-buffer-modified-p nil) t)
      (?c nil))))

(define-minor-mode decklet-card-back-mode
  "Minor mode for editing a Decklet card back in a popup."
  :lighter " DeckletEdit"
  (if decklet-card-back-mode
      (progn
        (decklet-db-register-session-buffer)
        (add-hook 'write-contents-functions
                  #'decklet-card-back--write-contents nil t)
        (add-hook 'kill-buffer-query-functions
                  #'decklet-card-back--kill-buffer-query nil t))
    (setq decklet-db--session-buffer nil)
    (remove-hook 'kill-buffer-hook
                 #'decklet-db--on-session-buffer-killed t)
    (remove-hook 'write-contents-functions
                 #'decklet-card-back--write-contents t)
    (remove-hook 'kill-buffer-query-functions
                 #'decklet-card-back--kill-buffer-query t)))

(defun decklet-show-card-back (word)
  "Open the card back popup buffer for WORD."
  (interactive (list (decklet--resolve-word nil "Word: ")))
  (let* ((card (decklet-db--require-card-row-by-word word))
         (card-id (plist-get card :card-id))
         (back (plist-get card :back))
         (buf-name (format "*Decklet Card Back: %s*" word))
         (buffer (get-buffer-create buf-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (funcall decklet-card-back-buffer-major-mode)
        (setq-local decklet-card-back--card-id card-id)
        (when back
          (insert back))
        (goto-char (point-min)))
      ;; read-only by default
      (setq buffer-read-only (and back t))
      ;; Loading content from the DB isn't a user edit; clear the modified
      ;; flag so `decklet-card-back--kill-buffer-query' doesn't prompt on a
      ;; buffer the user hasn't actually touched.
      (set-buffer-modified-p nil)
      (decklet-card-back-mode 1))
    (pop-to-buffer buffer)))

(provide 'decklet-deck)
;;; decklet-deck.el ends here

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

(defvar decklet-add-card-batch-font-lock-keywords
  `((,decklet--batch-hint-re . font-lock-comment-face))
  "Font-lock rules for `decklet-add-card-batch-mode'.")

(define-derived-mode decklet-add-card-batch-mode text-mode "Decklet-Batch"
  "Major mode for editing batch word entries.
Lines starting with `#' are highlighted as comment-style hint lines."
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
                 (decklet-card-word-by-id decklet-current-card-id))
            (user-error "No word to use")))
       ((derived-mode-p 'decklet-edit-mode)
        (let ((card-id (tabulated-list-get-id)))
          (if card-id
              (or (decklet-card-word-by-id card-id)
                  (user-error "No word on this line"))
            (user-error "No word on this line"))))
       (t
        (let* ((default (thing-at-point 'word t))
               (input (read-string (or prompt "Word: ") default))
               (trimmed (string-trim input)))
          (if (string-empty-p trimmed)
              (user-error "Word cannot be empty")
            trimmed)))))))

(defun decklet--require-card (word)
  "Return the card row for WORD, or signal a user error."
  (or (decklet-db--select-card word)
      (user-error "No card found for \"%s\"" word)))

(defun decklet--require-card-by-id (card-id)
  "Return the card row for CARD-ID, or signal a user error."
  (or (decklet-db--select-card-by-id card-id)
      (user-error "No card found for id %s" card-id)))

(defun decklet--card-from-row (row)
  "Return public card plist converted from ROW."
  (list :card-id (plist-get row :card-id)
        :word (plist-get row :word)
        :hint (plist-get row :hint)
        :back (plist-get row :back)
        :meta (decklet-db--row->card-meta row)))

;; Public API — card accessors
;;
;; These are the stable entry points extensions should use instead of
;; reaching into `decklet-db--' internals.  Internal identity is always
;; `card_id'; callers that start from a word should resolve the card row
;; first, then operate by id.

(defun decklet-get-card (card-id)
  "Return card data for CARD-ID as a plist, or nil if not found."
  (let ((row (decklet-db--select-card-by-id card-id)))
    (when row
      (decklet--card-from-row row))))

(defun decklet-get-card-hint (card-id)
  "Return the hint string for CARD-ID, or nil when absent."
  (decklet-db--select-card-hint-by-id card-id))

(defun decklet-get-card-back (card-id)
  "Return the card back content for CARD-ID, or nil when absent."
  (decklet-db--select-card-back-by-id card-id))

(defun decklet-get-card-meta (card-id)
  "Return the `decklet-card-meta' struct for CARD-ID, or nil when absent."
  (let ((row (decklet-db--select-card-by-id card-id)))
    (when row
      (decklet-db--row->card-meta row))))

(defun decklet-card-word-by-id (card-id)
  "Return the current word for CARD-ID, or nil when absent."
  (decklet-db--select-card-word-by-id card-id))

(defun decklet-card-id-for-word (word)
  "Return the card id for WORD, or nil when absent."
  (plist-get (decklet-db--select-card word) :card-id))

(defun decklet-card-exists-p (card-id)
  "Return non-nil when CARD-ID has a card in the deck."
  (and (decklet-db--select-card-by-id card-id) t))

(defun decklet-list-words (&optional filter)
  "Return all words in the deck as a list, optionally filtered.
FILTER is one of the symbols `all' (default), `review', `learning',
or `archived'."
  (mapcar (lambda (row) (plist-get row :word))
          (decklet-db--select-cards (or filter 'all))))

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
  "Update CARD-ID with review GRADE (1-4)."
  (let* ((row (decklet--require-card-by-id card-id))
         (word (plist-get row :word))
         (old-meta (decklet-db--row->card-meta row)))
    (decklet--rate-card-state card-id word old-meta grade prior-grade)))

(defun decklet--rate-card-state (card-id word old-meta grade &optional prior-grade)
  "Update CARD-ID using WORD and OLD-META with review GRADE (1-4)."
  (let ((new-meta (decklet--update-card-with-grade word old-meta grade)))
    (decklet-db--upsert-card word new-meta)
    (decklet--refresh-counter)
    (prog1 (decklet-review-log-append-rated word card-id grade old-meta new-meta)
      (run-hook-with-args 'decklet-card-rated-functions
                          card-id old-meta grade new-meta prior-grade))))

(defun decklet-rename-card (card-id new-word)
  "Rename CARD-ID to NEW-WORD and return the normalized new value."
  (let* ((old-word (plist-get (decklet--require-card-by-id card-id) :word))
         (normalized (decklet-db--update-word-by-id card-id new-word)))
    (when (and decklet-last-added-word (string-equal old-word decklet-last-added-word))
      (setq decklet-last-added-word normalized))
    (unless (string-equal old-word normalized)
      (decklet-review-log-append-rename card-id old-word normalized)
      (run-hook-with-args 'decklet-card-renamed-functions card-id old-word normalized))
    normalized))

(defun decklet-set-card-hint (card-id hint)
  "Update CARD-ID's card hint to HINT."
  (decklet--require-card-by-id card-id)
  (decklet-db--update-hint-by-id card-id hint)
  (run-hook-with-args 'decklet-card-field-updated-functions card-id 'hint))

(defun decklet-set-card-back (card-id content)
  "Update CARD-ID's card back to CONTENT."
  (decklet--require-card-by-id card-id)
  (decklet-db--update-back-by-id card-id content)
  (run-hook-with-args 'decklet-card-field-updated-functions card-id 'back))

(defun decklet-delete-card (card-id)
  "Delete CARD-ID from the deck."
  (let ((card (decklet--card-from-row (decklet--require-card-by-id card-id))))
    (decklet-db--delete-card-by-id card-id)
    (when (eql decklet-current-card-id card-id)
      (setq decklet-current-card-id nil))
    (when decklet-due-card-ids
      (setq decklet-due-card-ids (delete card-id decklet-due-card-ids)))
    (decklet--refresh-counter)
    (run-hook-with-args 'decklet-card-deleted-functions card-id card)))

(defun decklet-archive-card (card-id)
  "Archive CARD-ID without deleting it."
  (decklet--require-card-by-id card-id)
  (decklet-db--archive-card-by-id card-id (decklet--now))
  (when decklet-due-card-ids
    (setq decklet-due-card-ids (delete card-id decklet-due-card-ids)))
  (decklet--refresh-counter)
  (run-hook-with-args 'decklet-card-archived-functions card-id))

(defun decklet-unarchive-card (card-id)
  "Unarchive CARD-ID and return it to the active deck."
  (decklet--require-card-by-id card-id)
  (decklet-db--unarchive-card-by-id card-id)
  (decklet--refresh-counter)
  (run-hook-with-args 'decklet-card-unarchived-functions card-id))

(defun decklet-prompt-edit-card-fields (card-id &optional edit-word edit-hint)
  "Edit CARD-ID fields based on EDIT-WORD and EDIT-HINT flags.
Return the updated word."
  (let* ((card (decklet--card-from-row (decklet--require-card-by-id card-id)))
         (word (plist-get card :word))
         (hint (plist-get card :hint)))
    (when edit-word
      (let ((new-word (read-string (format "Word (%s): " word) word)))
        (unless (string-equal new-word word)
          (decklet-rename-card card-id new-word)
          (setq word new-word))))
    (when edit-hint
      (let ((new-hint (read-string (format "Hint (%s): " word) (or hint ""))))
        (unless (string-equal new-hint (or hint ""))
          (decklet-set-card-hint card-id new-hint))))
    word))

(defun decklet--add-hint-precheck ()
  "Get the target word for adding hint, or signal an error if none."
  (or decklet-last-added-word
      (user-error "No word to add a hint to")))

(defun decklet--add-card (word)
  "Add WORD as a new card and return a status message.
Fires `decklet-card-added-functions' only when a brand-new row is
created.  Refreshing the added date of an existing new card does not
fire the hook (the card's existence has not changed).

A brand-new row is also assigned a fresh `card-id' via
`decklet-db--mint-card-id'.  Refreshing an existing new card
preserves its existing `card-id'."
  (setq word (decklet-db--normalize-word word))
  (let* ((row (decklet-db--select-card word))
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
        (run-hook-with-args 'decklet-card-added-functions
                            (decklet-card-meta-card-id meta))
        (format "Added \"%s\" to the deck. " word)))
     ;; Existing reviewed card: do not treat it as addable again.
     ((not (decklet-card-meta-is-new meta))
      (format "Word \"%s\" already exists in the deck. " word))
     ;; Existing new card: optionally refresh its added date instead of
     ;; creating a second add event for the same card.
     ((not decklet-add-and-refresh)
      (format "Word \"%s\" already exists in the deck. " word))
     ;; Refresh the existing new card in place and keep its card-id.
     (t
      (let ((now (decklet--now)))
        (setf (decklet-card-meta-added-date meta) now)
        (setf (decklet-card-meta-due meta) now)
        (decklet-db--upsert-card word meta)
        (format "Refreshed the added date of existing new word \"%s\". " word))))))

;;;###autoload
(defun decklet-add-card (word)
  "Add WORD as a new card.
After adding a card, prompts if you want to add another."
  (interactive "sWord to add: ")
  (let ((status-msg (decklet--add-card word)))
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
                   (plist-get (decklet--require-card target) :hint))
      target)))
  (let ((target (or target (decklet--add-hint-precheck))))
    (let ((card-id (plist-get (decklet--require-card target) :card-id)))
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
  "Confirm batch import for the current buffer."
  (interactive)
  (let* ((cards (decklet--batch-collect-cards))
         (conn (decklet-db--ensure)))
    (sqlite-execute conn "BEGIN;")
    (condition-case err
        (progn
          (dolist (card cards)
            (let ((word (plist-get card :word))
                  (hint (plist-get card :hint)))
              (decklet-add-card word)
              (when hint
                (let* ((row (decklet--require-card word))
                       (card-id (decklet-card-meta-card-id (decklet-db--row->card-meta row))))
                  (decklet-set-card-hint card-id hint)))))
          (sqlite-execute conn "COMMIT;"))
      (error
       (sqlite-execute conn "ROLLBACK;")
       (signal (car err) (cdr err))))
    (message "Imported %d words" (length cards))
    (when (functionp decklet-add-card-batch--on-confirm)
      (funcall decklet-add-card-batch--on-confirm
               (mapcar (lambda (card) (plist-get card :word)) cards))))
  (kill-buffer (current-buffer)))

(defun decklet-add-card-batch-cancel ()
  "Cancel batch import and close the buffer."
  (interactive)
  (when (functionp decklet-add-card-batch--on-cancel)
    (funcall decklet-add-card-batch--on-cancel))
  (kill-buffer (current-buffer))
  (message "Batch import canceled"))

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

(defun decklet-card-back--buffer-name (word)
  "Return the buffer name for the card back of WORD."
  (format "*Decklet Card Back: %s*" word))

(defun decklet-card-back--kill-buffers ()
  "Kill all Decklet card back popup buffers."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (bound-and-true-p decklet-card-back-mode)
        (kill-buffer buffer)))))

;; Card back save is not supposed to work after db disconnection.
(add-hook 'decklet-db-pre-disconnect-hook #'decklet-card-back--kill-buffers)

(defun decklet-card-back-save ()
  "Save the card back content to db."
  (interactive)
  (let ((card-id decklet-card-back--card-id))
    (unless card-id
      (user-error "No card associated with this buffer"))
    (let ((content (buffer-substring-no-properties (point-min) (point-max))))
      (decklet-set-card-back card-id content)
      (message "Wrote card back of word \"%s\""
               (or (decklet-card-word-by-id card-id) "")))))

(define-minor-mode decklet-card-back-mode
  "Minor mode for editing a Decklet card back in a popup."
  :lighter " DeckletEdit"
  (when decklet-card-back-mode
    (add-hook 'write-contents-functions
              (lambda () (decklet-card-back-save) t))))

(defun decklet-card-back-show (word)
  "Open the card back popup buffer for WORD."
  (interactive (list (decklet--resolve-word nil "Word: ")))
  (let* ((card (or (decklet--require-card word)
                   (user-error "No card found for \"%s\"" word)))
         (card-id (plist-get card :card-id))
         (back (plist-get card :back))
         (buf-name (decklet-card-back--buffer-name word))
         (buffer (get-buffer-create buf-name)))
    (with-current-buffer buffer
      ;; insert buffer content
      (let ((inhibit-read-only t))
        (erase-buffer)
        (funcall decklet-card-back-buffer-major-mode)
        (setq-local decklet-card-back--card-id card-id)
        (when back
          (insert back))
        (goto-char (point-min)))
      ;; read-only by default
      (when back
        (setq buffer-read-only t))
      (decklet-card-back-mode 1))
    (pop-to-buffer buffer)))

(provide 'decklet-deck)
;;; decklet-deck.el ends here

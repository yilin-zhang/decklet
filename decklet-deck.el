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

(defvar decklet-current-word nil
  "The current word being reviewed.")

(defvar decklet-last-added-word nil
  "Most recently added word outside review.")

(defvar decklet-add-card-batch-buffer-name "*Decklet Batch Add*"
  "Buffer name used for batch card entry.")

(defvar decklet-due-words nil
  "List of words that are due for review.")

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

(defun decklet--refresh-due-words ()
  "Refresh due words list if review session is active."
  (setq decklet-due-words (decklet-db--select-due-words)))

(defun decklet--load-card-meta (word)
  "Return card metadata for WORD, or nil if not found."
  (let ((row (decklet-db--select-card word)))
    (when row
      (decklet-db--row->card-meta row))))

(defun decklet--load-card-full (word)
  "Return a plist with :meta, :hint, and :back for WORD from a single query.
Return nil if the card does not exist."
  (let ((row (decklet-db--select-card word)))
    (when row
      (list :meta (decklet-db--row->card-meta row)
            :hint (plist-get row :hint)
            :back (plist-get row :back)))))

(defun decklet--require-current-word (action)
  "Return the current word, or report ACTION and return nil.
ACTION should be a verb phrase used in the fallback message."
  (when (not decklet-current-word)
    (user-error "No word to %s" action))
  decklet-current-word)

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
        (decklet--require-current-word "use"))
       ((derived-mode-p 'decklet-edit-mode)
        (or (tabulated-list-get-id)
            (user-error "No word on this line")))
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

(defun decklet--require-card-hint (word)
  "Get the hint for WORD's card."
  (let ((row (decklet--require-card word)))
    (plist-get row :hint)))

(defun decklet--current-card-hint ()
  "Return the hint for the current review word, if any."
  (when decklet-current-word
    (decklet--require-card-hint decklet-current-word)))

;; Public API — card accessors
;;
;; These are the stable entry points extensions should use instead of
;; reaching into `decklet-db--' internals.  They are thin wrappers over
;; the DB layer and the internal helpers above.

(defun decklet-card-exists-p (word)
  "Return non-nil when WORD has a card in the deck."
  (and (decklet-db--select-card word) t))

(defun decklet-get-card (word)
  "Return card data for WORD as a plist, or nil if not found.
The plist has keys `:word', `:hint', `:back', and `:meta'."
  (let ((row (decklet-db--select-card word)))
    (when row
      (list :word (plist-get row :word)
            :hint (plist-get row :hint)
            :back (plist-get row :back)
            :meta (decklet-db--row->card-meta row)))))

(defun decklet-get-card-hint (word)
  "Return the hint string for WORD, or nil when absent."
  (decklet-db--select-card-hint word))

(defun decklet-get-card-back (word)
  "Return the card back content for WORD, or nil when absent."
  (decklet-db--select-card-back word))

(defun decklet-get-card-meta (word)
  "Return the `decklet-card-meta' struct for WORD, or nil when absent."
  (decklet--load-card-meta word))

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

(defun decklet-rate-card (word grade &optional prior-grade)
  "Update the card for WORD with review GRADE (1-4).
Fires `decklet-card-rated-functions' with
\(WORD OLD-META GRADE NEW-META PRIOR-GRADE).  PRIOR-GRADE is nil
for fresh ratings; review mode passes the replaced grade when
re-rating after undo.  Also appends a `rated' record to the
persistent review log and returns the new log record id (or nil
when the log write failed — log errors never abort the rating)."
  (let* ((row (decklet--require-card word))
         (old-meta (decklet-db--row->card-meta row))
         (new-meta (decklet--update-card-with-grade word old-meta grade))
         (card-id (decklet-card-meta-card-id new-meta)))
    (decklet-db--upsert-card word new-meta)
    (decklet--refresh-counter)
    (prog1 (decklet-review-log-append-rated word card-id grade old-meta new-meta)
      (run-hook-with-args 'decklet-card-rated-functions
                          word old-meta grade new-meta prior-grade))))

(defun decklet-rename-word (old-word new-word)
  "Rename OLD-WORD to NEW-WORD and return the normalized new value.
Fires `decklet-card-renamed-functions' and appends a `rename' record
to the persistent review log when the rename actually changes the
stored word."
  (let* ((card-meta (decklet--load-card-meta old-word))
         (card-id (and card-meta (decklet-card-meta-card-id card-meta)))
         (normalized (decklet-db--update-word old-word new-word)))
    (when (and decklet-current-word (string-equal old-word decklet-current-word))
      (setq decklet-current-word normalized))
    (when (and decklet-last-added-word (string-equal old-word decklet-last-added-word))
      (setq decklet-last-added-word normalized))
    (when decklet-due-words
      (setq decklet-due-words
            (cl-substitute normalized old-word decklet-due-words :test #'string=)))
    (unless (string-equal old-word normalized)
      (when card-id
        (decklet-review-log-append-rename card-id old-word normalized))
      (run-hook-with-args 'decklet-card-renamed-functions old-word normalized))
    normalized))

(defun decklet-set-card-hint (word hint)
  "Update WORD's card hint to HINT.
Signals a user error if WORD does not exist.
Fires `decklet-card-field-updated-functions' with (WORD `hint')."
  (decklet--require-card word)
  (decklet-db--update-hint word hint)
  (run-hook-with-args 'decklet-card-field-updated-functions word 'hint))

(defun decklet-set-card-back (word content)
  "Update WORD's card back to CONTENT.
Signals a user error if WORD does not exist.
Fires `decklet-card-field-updated-functions' with (WORD `back')."
  (decklet--require-card word)
  (decklet-db--update-back word content)
  (run-hook-with-args 'decklet-card-field-updated-functions word 'back))

(defun decklet-delete-card (word)
  "Delete the card for WORD from the deck.
Fires `decklet-card-deleted-functions' after the row is removed."
  (decklet-db--delete-card word)
  (when decklet-due-words
    (setq decklet-due-words (delete word decklet-due-words)))
  (decklet--refresh-counter)
  (run-hook-with-args 'decklet-card-deleted-functions word))

(defun decklet-archive-card (word)
  "Archive the card for WORD without deleting it.
Fires `decklet-card-archived-functions'."
  (decklet-db--archive-card word (decklet--now))
  (when decklet-due-words
    (setq decklet-due-words (delete word decklet-due-words)))
  (decklet--refresh-counter)
  (run-hook-with-args 'decklet-card-archived-functions word))

(defun decklet-unarchive-card (word)
  "Unarchive the card for WORD and return it to the active deck.
Fires `decklet-card-unarchived-functions'."
  (decklet-db--unarchive-card word)
  ;; No need to refresh `decklet-due-words' here
  (decklet--refresh-counter)
  (run-hook-with-args 'decklet-card-unarchived-functions word))

(defun decklet-prompt-edit-card-fields (word &optional edit-word edit-hint)
  "Edit WORD fields based on EDIT-WORD and EDIT-HINT flags.
Return the updated word."
  (let* ((row (decklet--require-card word))
         (hint (plist-get row :hint)))
    (when edit-word
      (let ((new-word (read-string (format "Word (%s): " word) word)))
        (unless (string-equal new-word word)
          (decklet-rename-word word new-word)
          (setq word new-word))))
    (when edit-hint
      (let ((new-hint (read-string (format "Hint (%s): " word) (or hint ""))))
        (unless (string-equal new-hint (or hint ""))
          (decklet-set-card-hint word new-hint))))
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
  (let* ((meta (decklet--load-card-meta word))
         (was-absent (null meta))
         (is-new (and meta (decklet-card-meta-is-new meta))))
    (setq decklet-last-added-word word)
    (if (and meta
             (or (not is-new)
                 (not decklet-add-and-refresh)))
        (format "Word \"%s\" already exists in the deck. " word)
      (let ((now (decklet--now)))
        (unless meta
          (setq meta (make-decklet-card-meta
                      :card-id (decklet-db--mint-card-id))))
        (setf (decklet-card-meta-added-date meta) now)
        (setf (decklet-card-meta-due meta) now)
        (decklet-db--upsert-card word meta)
        ;; No need to refresh `decklet-due-words' here
        (when was-absent
          (run-hook-with-args 'decklet-card-added-functions word))
        (if is-new
            (format "Refreshed the added date of existing new word \"%s\". " word)
          (format "Added \"%s\" to the deck. " word))))))

(defun decklet--add-card-prompt-next (status-msg)
  "Prompt for next action after adding a card with prepended STATUS-MSG."
  (let ((choice (read-char-choice
                 (concat status-msg "Add another card? (y/n, ENTER for yes, t for hint): ")
                 '(?y ?n ?\r ?t))))
    (pcase choice
      ((or ?y ?\r)
       (call-interactively #'decklet-add-card))
      (?t
       (let ((status-msg (call-interactively #'decklet-add-hint)))
         (when (memq (read-char-choice
                      (concat status-msg "Add another card? (y/n, ENTER for yes): ")
                      '(?y ?n ?\r))
                     '(?y ?\r))
           (call-interactively #'decklet-add-card)))))))

;;;###autoload
(defun decklet-add-card (word)
  "Add WORD as a new card.
After adding a card, prompts if you want to add another."
  (interactive "sWord to add: ")
  (let ((status-msg (decklet--add-card word)))
    (when (called-interactively-p 'any)
      (decklet--add-card-prompt-next status-msg))))

(defun decklet-add-hint (hint &optional target)
  "Add HINT to TARGET word, defaulting to the last added word."
  (interactive
   (let ((target (decklet--add-hint-precheck)))
     (list
      (read-string (format "Hint for \"%s\": " target)
                   (decklet--require-card-hint target))
      target)))
  (let ((target (or target (decklet--add-hint-precheck))))
    (decklet-set-card-hint target hint)
    (format "Updated the hint of \"%s\". " target)))

(defun decklet--batch-collect-words ()
  "Return a list of words parsed from the current batch buffer."
  (mapcar (lambda (card) (plist-get card :word))
          (decklet--batch-collect-cards)))

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
                (decklet-set-card-hint word hint))))
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

(defvar-local decklet-card-back--word nil
  "Word associated with the current card back buffer.")

(defvar-local decklet-card-back--callback nil
  "Callback invoked after saving the card back.
It is called with no arguments.")

(defun decklet-card-back--buffer-name (word)
  "Return the buffer name for the card back of WORD."
  (format "*Decklet Card Back: %s*" word))

(defun decklet-card-back--kill-buffers ()
  "Kill all Decklet card back popup buffers."
  (dolist (buffer (buffer-list))
    (when (string-prefix-p "*Decklet Card Back:" (buffer-name buffer))
      (kill-buffer buffer))))

(add-hook 'decklet-db-pre-disconnect-hook #'decklet-card-back--kill-buffers)

(defun decklet-card-back-save ()
  "Save the card back content, close its window, and kill the buffer."
  (interactive)
  (let ((word decklet-card-back--word)
        (callback decklet-card-back--callback))
    (unless word
      (user-error "No word associated with this buffer"))
    (let ((content (buffer-substring-no-properties (point-min) (point-max))))
      (decklet-set-card-back word content)
      (quit-window t)
      (when (functionp callback)
        (funcall callback)))))

(defun decklet-card-back-cancel ()
  "Close the card back window and kill the buffer without saving."
  (interactive)
  (quit-window t))

(defvar-keymap decklet-card-back-view-mode-map
  :doc "Keymap for `decklet-card-back-view-mode'."
  "q" #'decklet-card-back-cancel)

(define-minor-mode decklet-card-back-view-mode
  "Minor mode for viewing a Decklet card back in a read-only popup."
  :lighter " DeckletView"
  :keymap decklet-card-back-view-mode-map)

(defvar-keymap decklet-card-back-edit-mode-map
  :doc "Keymap for `decklet-card-back-edit-mode'."
  "C-c C-c" #'decklet-card-back-save
  "C-c C-k" #'decklet-card-back-cancel)

(define-minor-mode decklet-card-back-edit-mode
  "Minor mode for editing a Decklet card back in a popup."
  :lighter " DeckletEdit"
  :keymap decklet-card-back-edit-mode-map)

(defun decklet-card-back--open (word read-only-p &optional callback)
  "Open the card back popup buffer for WORD.
When READ-ONLY-P is non-nil the buffer is read-only; otherwise it is editable.
CALLBACK, when provided, is called with no arguments after a successful save."
  (let* ((back (decklet-get-card-back word))
         (buf-name (decklet-card-back--buffer-name word))
         (buffer (get-buffer-create buf-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (funcall decklet-card-back-buffer-major-mode)
        (setq-local decklet-card-back--word word)
        (setq-local decklet-card-back--callback callback)
        (when back
          (insert back))
        (goto-char (point-min))
        (setq buffer-read-only read-only-p))
      (if read-only-p
          (decklet-card-back-view-mode 1)
        (decklet-card-back-edit-mode 1)))
    (pop-to-buffer buffer)))

(defun decklet-card-back-show (word &optional callback)
  "Show the card back for WORD in a read-only popup buffer.
CALLBACK, when provided, is called with no arguments after a successful save."
  (interactive (list (decklet--resolve-word nil "Word: ")))
  (decklet--require-card word)
  (decklet-card-back--open word t callback))

(defun decklet-card-back-edit (word &optional callback)
  "Open the card back for WORD in an editable popup buffer.
CALLBACK, when provided, is called with no arguments after a successful save."
  (interactive (list (decklet--resolve-word nil "Word: ")))
  (decklet--require-card word)
  (decklet-card-back--open word nil callback))

(provide 'decklet-deck)
;;; decklet-deck.el ends here

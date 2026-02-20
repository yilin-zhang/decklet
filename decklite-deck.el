;;; decklite-deck.el --- Deck operations for DeckLite -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Core card/deck operations shared by UI modules.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)

(require 'decklite-core)
(require 'decklite-schedular)
(require 'decklite-db)

(defcustom decklite-add-and-refresh t
  "When non-nil, re-adding an unreviewed word resets its timestamps."
  :type 'boolean
  :group 'decklite)

(defvar decklite-current-word nil
  "The current word being reviewed.")

(defvar decklite-last-added-word nil
  "Most recently added word outside review.")

(defvar decklite-add-card-batch-buffer-name "*DeckLite Batch Add*"
  "Buffer name used for batch card entry.")

(defvar decklite-due-words nil
  "List of words that are due for review.")

(defvar-local decklite-add-card-batch--on-confirm nil
  "Function called after batch add confirmation.
Receives a list of added words.")

(defvar-local decklite-add-card-batch--on-cancel nil
  "Function called after batch add cancellation.")

(defvar decklite-add-card-batch-mode-map
  (define-keymap
    "C-c C-c" #'decklite-add-card-batch-confirm
    "C-c C-k" #'decklite-add-card-batch-cancel)
  "Keymap for `decklite-add-card-batch-mode'.")

(define-derived-mode decklite-add-card-batch-mode text-mode "DeckLite-Batch"
  "Major mode for editing batch word entries.")

(defun decklite--refresh-counter ()
  "Refresh counters from database state."
  (setq decklite--counter (decklite-db--counts)))

(defun decklite--refresh-due-words ()
  "Refresh due words list if review session is active."
  (setq decklite-due-words (decklite-db--select-due-words)))

(defun decklite--load-card-meta (word)
  "Return card metadata for WORD, or nil if not found."
  (let ((row (decklite-db--select-card word)))
    (when row
      (decklite-db--row->card-meta row))))

(defun decklite--require-current-word (action)
  "Return the current word, or report ACTION and return nil.
ACTION should be a verb phrase used in the fallback message."
  (when (not decklite-current-word)
    (user-error "No word to %s" action))
  decklite-current-word)

(defun decklite--resolve-word (word &optional prompt)
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
       ((derived-mode-p 'decklite-review-mode)
        (decklite--require-current-word "use"))
       ((derived-mode-p 'decklite-edit-mode)
        (or (tabulated-list-get-id)
            (user-error "No word on this line")))
       (t
        (let* ((default (thing-at-point 'word t))
               (input (read-string (or prompt "Word: ") default))
               (trimmed (string-trim input)))
          (if (string-empty-p trimmed)
              (user-error "Word cannot be empty")
            trimmed)))))))

(defun decklite--require-card (word)
  "Return the card row for WORD, or signal a user error."
  (or (decklite-db--select-card word)
      (user-error "No card found for \"%s\"" word)))

(defun decklite--require-card-hint (word)
  "Get the hint for WORD's card."
  (let ((meta (decklite--load-card-meta word)))
    (unless meta
      (user-error "No card found for \"%s\"" word))
    (decklite-card-meta-hint meta)))

(defun decklite--current-card-hint ()
  "Return the hint for the current review word, if any."
  (when decklite-current-word
    (decklite--require-card-hint decklite-current-word)))

(defun decklite-rate-card (word grade)
  "Update the card for WORD with review GRADE (1-4)."
  (let* ((row (decklite--require-card word))
         (meta (decklite-db--row->card-meta row))
         (updated (decklite--update-card-with-grade word meta grade)))
    (decklite-db--upsert-card word updated)
    (decklite--refresh-counter)))

(defun decklite-rename-word (old-word new-word)
  "Rename OLD-WORD to NEW-WORD and return the normalized new value."
  (let ((new-word (decklite-db--update-word old-word new-word)))
    (when (and decklite-current-word (string-equal old-word decklite-current-word))
      (setq decklite-current-word new-word))
    (when (and decklite-last-added-word (string-equal old-word decklite-last-added-word))
      (setq decklite-last-added-word new-word))
    (when decklite-due-words
      (setq decklite-due-words
            (cl-substitute new-word old-word decklite-due-words :test #'string=)))
    new-word))

(defun decklite-update-card-hint (word hint)
  "Update the card for WORD with HINT."
  (decklite--require-card word)
  (decklite-db--update-hint word hint))

(defun decklite-delete-card (word)
  "Delete the card for WORD from the deck."
  (decklite-db--delete-card word)
  (when decklite-due-words
    (setq decklite-due-words (delete word decklite-due-words)))
  (decklite--refresh-counter))

(defun decklite-archive-card (word)
  "Archive the card for WORD without deleting it."
  (decklite-db--archive-card word (fsrs-now))
  (when decklite-due-words
    (setq decklite-due-words (delete word decklite-due-words)))
  (decklite--refresh-counter))

(defun decklite-unarchive-card (word)
  "Unarchive the card for WORD and return it to the active deck."
  (decklite-db--unarchive-card word)
  ;; No need to refresh `decklite-due-words' here
  (decklite--refresh-counter))

(defun decklite-prompt-edit-card-fields (word &optional edit-word edit-hint)
  "Edit WORD fields based on EDIT-WORD and EDIT-HINT flags.
Return the updated word."
  (let ((row (decklite--require-card word)))
    (pcase-let ((`(,_word ,_added ,_last ,_due ,_state ,_step ,_stability ,_difficulty ,hint) row))
      (when edit-word
        (let ((new-word (read-string (format "Word (%s): " word) word)))
          (unless (string-equal new-word word)
            (decklite-rename-word word new-word)
            (setq word new-word))))
      (when edit-hint
        (let ((new-hint (read-string (format "Hint (%s): " word) (or hint ""))))
          (unless (string-equal new-hint (or hint ""))
            (decklite-update-card-hint word new-hint))))
      word)))

(defun decklite--add-hint-precheck ()
  "Get the target word for adding hint, or signal an error if none."
  (or decklite-last-added-word
      (user-error "No word to add a hint to")))

(defun decklite--add-card (word)
  "Add WORD as a new card and return a status message."
  (setq word (decklite-db--normalize-word word))
  (let* ((meta (decklite--load-card-meta word))
         (is-new (and meta (decklite-card-meta-is-new meta))))
    (setq decklite-last-added-word word)
    (if (and meta
             (or (not is-new)
                 (not decklite-add-and-refresh)))
        (format "Word \"%s\" already exists in the deck. " word)
      (let ((now (fsrs-now)))
        (unless meta
          (setq meta (make-decklite-card-meta)))
        (setf (decklite-card-meta-added-date meta) now)
        (setf (decklite-card-meta-due meta) now)
        (decklite-db--upsert-card word meta)
        ;; No need to refresh `decklite-due-words' here
        (if is-new
            (format "Refreshed the added date of existing new word \"%s\". " word)
          (format "Added \"%s\" to the deck. " word))))))

(defun decklite--add-card-prompt-next (status-msg)
  "Prompt for next action after adding a card with prepended STATUS-MSG."
  (let ((choice (read-char-choice
                 (concat status-msg "Add another card? (y/n, ENTER for yes, t for hint): ")
                 '(?y ?n ?\r ?t))))
    (pcase choice
      ((or ?y ?\r)
       (call-interactively #'decklite-add-card))
      (?t
       (let ((status-msg (call-interactively #'decklite-add-hint)))
         (when (memq (read-char-choice
                      (concat status-msg "Add another card? (y/n, ENTER for yes): ")
                      '(?y ?n ?\r))
                     '(?y ?\r))
           (call-interactively #'decklite-add-card)))))))

;;;###autoload
(defun decklite-add-card (word)
  "Add WORD as a new card.
After adding a card, prompts if you want to add another."
  (interactive "sWord to add: ")
  (let ((status-msg (decklite--add-card word)))
    (when (called-interactively-p 'any)
      (decklite--add-card-prompt-next status-msg))))

(defun decklite-add-hint (hint)
  "Add HINT to the last added word."
  (interactive
   (let ((target (decklite--add-hint-precheck)))
     (list
      (read-string (format "Hint for \"%s\": " target)
                   (decklite--require-card-hint target)))))
  (let ((target (decklite--add-hint-precheck)))
    (decklite-update-card-hint target hint)
    (format "Updated the hint of \"%s\". " target)))

(defun decklite--batch-collect-words ()
  "Return a list of non-empty words from the current buffer."
  (split-string (buffer-string) "\n" t "[[:space:]]+"))

(defun decklite-add-card-batch-confirm ()
  "Confirm batch import for the current buffer."
  (interactive)
  (let ((words (decklite--batch-collect-words)))
    (dolist (word words)
      (decklite-add-card word))
    (message "Imported %d words" (length words))
    (when (functionp decklite-add-card-batch--on-confirm)
      (funcall decklite-add-card-batch--on-confirm words)))
  (kill-buffer (current-buffer)))

(defun decklite-add-card-batch-cancel ()
  "Cancel batch import and close the buffer."
  (interactive)
  (when (functionp decklite-add-card-batch--on-cancel)
    (funcall decklite-add-card-batch--on-cancel))
  (kill-buffer (current-buffer))
  (message "Batch import canceled"))

;;;###autoload
(defun decklite-add-card-batch (&optional words &rest options)
  "Open a buffer for batch word entry.
WORDS, when non-nil, are inserted one per line.
OPTIONS is a plist supporting :buffer-name, :title, :on-confirm, :on-cancel,
and :message-prefix."
  (interactive)
  (let ((buffer (get-buffer-create
                 (or (plist-get options :buffer-name)
                     decklite-add-card-batch-buffer-name))))
    (with-current-buffer buffer
      (decklite-add-card-batch-mode)
      (setq header-line-format (or (plist-get options :title) "DeckLite Batch Add")
            decklite-add-card-batch--on-confirm (plist-get options :on-confirm)
            decklite-add-card-batch--on-cancel (plist-get options :on-cancel))
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
             (substitute-command-keys "\\[decklite-add-card-batch-confirm]")
             (substitute-command-keys "\\[decklite-add-card-batch-cancel]"))))

(provide 'decklite-deck)
;;; decklite-deck.el ends here

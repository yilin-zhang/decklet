;;; mnemodeck-deck.el --- Deck operations for MnemoDeck -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Core card/deck operations shared by UI modules.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)

(require 'mnemodeck-core)
(require 'mnemodeck-schedular)
(require 'mnemodeck-db)

(defcustom mnemodeck-add-and-refresh t
  "When non-nil, re-adding an unreviewed word resets its timestamps."
  :type 'boolean
  :group 'mnemodeck)

(defvar mnemodeck-current-word nil
  "The current word being reviewed.")

(defvar mnemodeck-last-added-word nil
  "Most recently added word outside review.")

(defvar mnemodeck-add-card-batch-buffer-name "*MnemoDeck Batch Add*"
  "Buffer name used for batch card entry.")

(defvar mnemodeck-due-words nil
  "List of words that are due for review.")

(defvar-local mnemodeck-add-card-batch--on-confirm nil
  "Function called after batch add confirmation.
Receives a list of added words.")

(defvar-local mnemodeck-add-card-batch--on-cancel nil
  "Function called after batch add cancellation.")

(defvar mnemodeck-add-card-batch-mode-map
  (define-keymap
    "C-c C-c" #'mnemodeck-add-card-batch-confirm
    "C-c C-k" #'mnemodeck-add-card-batch-cancel)
  "Keymap for `mnemodeck-add-card-batch-mode'.")

(define-derived-mode mnemodeck-add-card-batch-mode text-mode "MnemoDeck-Batch"
  "Major mode for editing batch word entries.")

(defun mnemodeck--refresh-counter ()
  "Refresh counters from database state."
  (setq mnemodeck--counter (mnemodeck-db--counts)))

(defun mnemodeck--refresh-due-words ()
  "Refresh due words list if review session is active."
  (setq mnemodeck-due-words (mnemodeck-db--select-due-words)))

(defun mnemodeck--load-card-meta (word)
  "Return card metadata for WORD, or nil if not found."
  (let ((row (mnemodeck-db--select-card word)))
    (when row
      (mnemodeck-db--row->card-meta row))))

(defun mnemodeck--require-current-word (action)
  "Return the current word, or report ACTION and return nil.
ACTION should be a verb phrase used in the fallback message."
  (when (not mnemodeck-current-word)
    (user-error "No word to %s" action))
  mnemodeck-current-word)

(defun mnemodeck--resolve-word (word &optional prompt)
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
       ((derived-mode-p 'mnemodeck-review-mode)
        (mnemodeck--require-current-word "use"))
       ((derived-mode-p 'mnemodeck-edit-mode)
        (or (tabulated-list-get-id)
            (user-error "No word on this line")))
       (t
        (let* ((default (thing-at-point 'word t))
               (input (read-string (or prompt "Word: ") default))
               (trimmed (string-trim input)))
          (if (string-empty-p trimmed)
              (user-error "Word cannot be empty")
            trimmed)))))))

(defun mnemodeck--require-card (word)
  "Return the card row for WORD, or signal a user error."
  (or (mnemodeck-db--select-card word)
      (user-error "No card found for \"%s\"" word)))

(defun mnemodeck--require-card-hint (word)
  "Get the hint for WORD's card."
  (let ((meta (mnemodeck--load-card-meta word)))
    (unless meta
      (user-error "No card found for \"%s\"" word))
    (mnemodeck-card-meta-hint meta)))

(defun mnemodeck--current-card-hint ()
  "Return the hint for the current review word, if any."
  (when mnemodeck-current-word
    (mnemodeck--require-card-hint mnemodeck-current-word)))

(defun mnemodeck-rate-card (word grade)
  "Update the card for WORD with review GRADE (1-4)."
  (let* ((row (mnemodeck--require-card word))
         (meta (mnemodeck-db--row->card-meta row))
         (updated (mnemodeck--update-card-with-grade word meta grade)))
    (mnemodeck-db--upsert-card word updated)
    (mnemodeck--refresh-counter)))

(defun mnemodeck-rename-word (old-word new-word)
  "Rename OLD-WORD to NEW-WORD and return the normalized new value."
  (let ((new-word (mnemodeck-db--update-word old-word new-word)))
    (when (and mnemodeck-current-word (string-equal old-word mnemodeck-current-word))
      (setq mnemodeck-current-word new-word))
    (when (and mnemodeck-last-added-word (string-equal old-word mnemodeck-last-added-word))
      (setq mnemodeck-last-added-word new-word))
    (when mnemodeck-due-words
      (setq mnemodeck-due-words
            (cl-substitute new-word old-word mnemodeck-due-words :test #'string=)))
    new-word))

(defun mnemodeck-update-card-hint (word hint)
  "Update the card for WORD with HINT."
  (mnemodeck--require-card word)
  (mnemodeck-db--update-hint word hint))

(defun mnemodeck-delete-card (word)
  "Delete the card for WORD from the deck."
  (mnemodeck-db--delete-card word)
  (when mnemodeck-due-words
    (setq mnemodeck-due-words (delete word mnemodeck-due-words)))
  (mnemodeck--refresh-counter))

(defun mnemodeck-archive-card (word)
  "Archive the card for WORD without deleting it."
  (mnemodeck-db--archive-card word (fsrs-now))
  (when mnemodeck-due-words
    (setq mnemodeck-due-words (delete word mnemodeck-due-words)))
  (mnemodeck--refresh-counter))

(defun mnemodeck-unarchive-card (word)
  "Unarchive the card for WORD and return it to the active deck."
  (mnemodeck-db--unarchive-card word)
  ;; No need to refresh `mnemodeck-due-words' here
  (mnemodeck--refresh-counter))

(defun mnemodeck-prompt-edit-card-fields (word &optional edit-word edit-hint)
  "Edit WORD fields based on EDIT-WORD and EDIT-HINT flags.
Return the updated word."
  (let ((row (mnemodeck--require-card word)))
    (pcase-let ((`(,_word ,_added ,_last ,_due ,_state ,_step ,_stability ,_difficulty ,hint) row))
      (when edit-word
        (let ((new-word (read-string (format "Word (%s): " word) word)))
          (unless (string-equal new-word word)
            (mnemodeck-rename-word word new-word)
            (setq word new-word))))
      (when edit-hint
        (let ((new-hint (read-string (format "Hint (%s): " word) (or hint ""))))
          (unless (string-equal new-hint (or hint ""))
            (mnemodeck-update-card-hint word new-hint))))
      word)))

(defun mnemodeck--add-hint-precheck ()
  "Get the target word for adding hint, or signal an error if none."
  (or mnemodeck-last-added-word
      (user-error "No word to add a hint to")))

(defun mnemodeck--add-card (word)
  "Add WORD as a new card and return a status message."
  (setq word (mnemodeck-db--normalize-word word))
  (let* ((meta (mnemodeck--load-card-meta word))
         (is-new (and meta (mnemodeck-card-meta-is-new meta))))
    (setq mnemodeck-last-added-word word)
    (if (and meta
             (or (not is-new)
                 (not mnemodeck-add-and-refresh)))
        (format "Word \"%s\" already exists in the deck. " word)
      (let ((now (fsrs-now)))
        (unless meta
          (setq meta (make-mnemodeck-card-meta)))
        (setf (mnemodeck-card-meta-added-date meta) now)
        (setf (mnemodeck-card-meta-due meta) now)
        (mnemodeck-db--upsert-card word meta)
        ;; No need to refresh `mnemodeck-due-words' here
        (if is-new
            (format "Refreshed the added date of existing new word \"%s\". " word)
          (format "Added \"%s\" to the deck. " word))))))

(defun mnemodeck--add-card-prompt-next (status-msg)
  "Prompt for next action after adding a card with prepended STATUS-MSG."
  (let ((choice (read-char-choice
                 (concat status-msg "Add another card? (y/n, ENTER for yes, t for hint): ")
                 '(?y ?n ?\r ?t))))
    (pcase choice
      ((or ?y ?\r)
       (call-interactively #'mnemodeck-add-card))
      (?t
       (let ((status-msg (call-interactively #'mnemodeck-add-hint)))
         (when (memq (read-char-choice
                      (concat status-msg "Add another card? (y/n, ENTER for yes): ")
                      '(?y ?n ?\r))
                     '(?y ?\r))
           (call-interactively #'mnemodeck-add-card)))))))

;;;###autoload
(defun mnemodeck-add-card (word)
  "Add WORD as a new card.
After adding a card, prompts if you want to add another."
  (interactive "sWord to add: ")
  (let ((status-msg (mnemodeck--add-card word)))
    (when (called-interactively-p 'any)
      (mnemodeck--add-card-prompt-next status-msg))))

(defun mnemodeck-add-hint (hint)
  "Add HINT to the last added word."
  (interactive
   (let ((target (mnemodeck--add-hint-precheck)))
     (list
      (read-string (format "Hint for \"%s\": " target)
                   (mnemodeck--require-card-hint target)))))
  (let ((target (mnemodeck--add-hint-precheck)))
    (mnemodeck-update-card-hint target hint)
    (format "Updated the hint of \"%s\". " target)))

(defun mnemodeck--batch-collect-words ()
  "Return a list of non-empty words from the current buffer."
  (split-string (buffer-string) "\n" t "[[:space:]]+"))

(defun mnemodeck-add-card-batch-confirm ()
  "Confirm batch import for the current buffer."
  (interactive)
  (let ((words (mnemodeck--batch-collect-words)))
    (dolist (word words)
      (mnemodeck-add-card word))
    (message "Imported %d words" (length words))
    (when (functionp mnemodeck-add-card-batch--on-confirm)
      (funcall mnemodeck-add-card-batch--on-confirm words)))
  (kill-buffer (current-buffer)))

(defun mnemodeck-add-card-batch-cancel ()
  "Cancel batch import and close the buffer."
  (interactive)
  (when (functionp mnemodeck-add-card-batch--on-cancel)
    (funcall mnemodeck-add-card-batch--on-cancel))
  (kill-buffer (current-buffer))
  (message "Batch import canceled"))

;;;###autoload
(defun mnemodeck-add-card-batch (&optional words &rest options)
  "Open a buffer for batch word entry.
WORDS, when non-nil, are inserted one per line.
OPTIONS is a plist supporting :buffer-name, :title, :on-confirm, :on-cancel,
and :message-prefix."
  (interactive)
  (let ((buffer (get-buffer-create
                 (or (plist-get options :buffer-name)
                     mnemodeck-add-card-batch-buffer-name))))
    (with-current-buffer buffer
      (mnemodeck-add-card-batch-mode)
      (setq header-line-format (or (plist-get options :title) "MnemoDeck Batch Add")
            mnemodeck-add-card-batch--on-confirm (plist-get options :on-confirm)
            mnemodeck-add-card-batch--on-cancel (plist-get options :on-cancel))
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
             (substitute-command-keys "\\[mnemodeck-add-card-batch-confirm]")
             (substitute-command-keys "\\[mnemodeck-add-card-batch-cancel]"))))

(provide 'mnemodeck-deck)
;;; mnemodeck-deck.el ends here

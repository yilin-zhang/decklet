;;; decklet-deck.el --- Deck operations for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Core card/deck operations shared by UI modules.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)

(require 'decklet-core)
(require 'decklet-schedular)
(require 'decklet-db)

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

(defvar decklet-add-card-batch-font-lock-keywords
  '(("^#.*$" . font-lock-comment-face))
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
  (decklet--require-card word)
  (decklet-db--select-card-hint word))

(defun decklet--current-card-hint ()
  "Return the hint for the current review word, if any."
  (when decklet-current-word
    (decklet--require-card-hint decklet-current-word)))

(defun decklet-rate-card (word grade)
  "Update the card for WORD with review GRADE (1-4)."
  (let* ((row (decklet--require-card word))
         (meta (decklet-db--row->card-meta row))
         (updated (decklet--update-card-with-grade word meta grade)))
    (decklet-db--upsert-card word updated)
    (decklet--refresh-counter)))

(defun decklet-rename-word (old-word new-word)
  "Rename OLD-WORD to NEW-WORD and return the normalized new value."
  (let ((new-word (decklet-db--update-word old-word new-word)))
    (when (and decklet-current-word (string-equal old-word decklet-current-word))
      (setq decklet-current-word new-word))
    (when (and decklet-last-added-word (string-equal old-word decklet-last-added-word))
      (setq decklet-last-added-word new-word))
    (when decklet-due-words
      (setq decklet-due-words
            (cl-substitute new-word old-word decklet-due-words :test #'string=)))
    new-word))

(defun decklet-update-card-hint (word hint)
  "Update the card for WORD with HINT."
  (decklet--require-card word)
  (decklet-db--update-hint word hint))

(defun decklet-delete-card (word)
  "Delete the card for WORD from the deck."
  (decklet-db--delete-card word)
  (when decklet-due-words
    (setq decklet-due-words (delete word decklet-due-words)))
  (decklet--refresh-counter))

(defun decklet-archive-card (word)
  "Archive the card for WORD without deleting it."
  (decklet-db--archive-card word (fsrs-now))
  (when decklet-due-words
    (setq decklet-due-words (delete word decklet-due-words)))
  (decklet--refresh-counter))

(defun decklet-unarchive-card (word)
  "Unarchive the card for WORD and return it to the active deck."
  (decklet-db--unarchive-card word)
  ;; No need to refresh `decklet-due-words' here
  (decklet--refresh-counter))

(defun decklet-prompt-edit-card-fields (word &optional edit-word edit-hint)
  "Edit WORD fields based on EDIT-WORD and EDIT-HINT flags.
Return the updated word."
  (let ((row (decklet--require-card word)))
    (pcase-let ((`(,_word ,_added ,_last ,_due ,_state ,_step ,_stability ,_difficulty ,hint ,_back) row))
      (when edit-word
        (let ((new-word (read-string (format "Word (%s): " word) word)))
          (unless (string-equal new-word word)
            (decklet-rename-word word new-word)
            (setq word new-word))))
      (when edit-hint
        (let ((new-hint (read-string (format "Hint (%s): " word) (or hint ""))))
          (unless (string-equal new-hint (or hint ""))
            (decklet-update-card-hint word new-hint))))
      word)))

(defun decklet--add-hint-precheck ()
  "Get the target word for adding hint, or signal an error if none."
  (or decklet-last-added-word
      (user-error "No word to add a hint to")))

(defun decklet--add-card (word)
  "Add WORD as a new card and return a status message."
  (setq word (decklet-db--normalize-word word))
  (let* ((meta (decklet--load-card-meta word))
         (is-new (and meta (decklet-card-meta-is-new meta))))
    (setq decklet-last-added-word word)
    (if (and meta
             (or (not is-new)
                 (not decklet-add-and-refresh)))
        (format "Word \"%s\" already exists in the deck. " word)
      (let ((now (fsrs-now)))
        (unless meta
          (setq meta (make-decklet-card-meta)))
        (setf (decklet-card-meta-added-date meta) now)
        (setf (decklet-card-meta-due meta) now)
        (decklet-db--upsert-card word meta)
        ;; No need to refresh `decklet-due-words' here
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

(defun decklet-add-hint (hint)
  "Add HINT to the last added word."
  (interactive
   (let ((target (decklet--add-hint-precheck)))
     (list
      (read-string (format "Hint for \"%s\": " target)
                   (decklet--require-card-hint target)))))
  (let ((target (decklet--add-hint-precheck)))
    (decklet-update-card-hint target hint)
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
starting with `#' is treated as a hint line for the most recent word.
Hint lines are joined with newlines."
  (let ((lines (decklet--batch-clean-lines))
        (cards nil)
        (current-word nil)
        (current-hints nil))
    (dolist (line lines)
      (if (string-prefix-p "#" line)
          (progn
            (unless current-word
              (user-error "Hint line must follow a word line: %s" line))
            (push (string-trim (substring line 1)) current-hints))
        (when current-word
          (push (list :word current-word
                      :hint (when current-hints
                              (string-join (nreverse current-hints) "\n")))
                cards))
        (setq current-word line
              current-hints nil)))
    (when current-word
      (push (list :word current-word
                  :hint (when current-hints
                          (string-join (nreverse current-hints) "\n")))
            cards))
    (nreverse cards)))

(defun decklet-add-card-batch-confirm ()
  "Confirm batch import for the current buffer."
  (interactive)
  (let ((cards (decklet--batch-collect-cards)))
    (dolist (card cards)
      (let ((word (plist-get card :word))
            (hint (plist-get card :hint)))
        (decklet-add-card word)
        (when hint
          (decklet-update-card-hint word hint))))
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

(defcustom decklet-card-back-buffer-major-mode 'text-mode
  "Major mode used for the card back popup buffer."
  :type 'function
  :group 'decklet)

(defvar-local decklet-card-back--word nil
  "Word associated with the current card back buffer.")

(defvar-local decklet-card-back--on-save nil
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
  "Save the card back content, close its window, and kill the buffer.
Signals a user error when the buffer is read-only."
  (interactive)
  (when buffer-read-only
    (user-error "Buffer is read-only; press E to edit"))
  (let ((word decklet-card-back--word)
        (on-save decklet-card-back--on-save))
    (unless word
      (user-error "No word associated with this buffer"))
    (let ((content (buffer-substring-no-properties (point-min) (point-max))))
      (decklet-db--update-back word content)
      (quit-window t)
      (when (functionp on-save)
        (funcall on-save)))))

(defun decklet-card-back-cancel ()
  "Discard edits, close the card back window, and kill the buffer."
  (interactive)
  (quit-window t))

(defun decklet-card-back--make-editable ()
  "Switch the current card back buffer from read-only to editable."
  (interactive)
  (setq buffer-read-only nil)
  (message "Card back is now editable. C-c C-c to save, C-c C-k to cancel."))

(defun decklet-card-back--open (word read-only-p &optional on-save)
  "Open the card back popup buffer for WORD.
When READ-ONLY-P is non-nil the buffer is read-only; otherwise it is editable.
ON-SAVE, when provided, is called with no arguments after a successful save."
  (let* ((back (decklet-db--select-card-back word))
         (buf-name (decklet-card-back--buffer-name word))
         (buffer (get-buffer-create buf-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (funcall decklet-card-back-buffer-major-mode)
        (setq-local decklet-card-back--word word)
        (setq-local decklet-card-back--on-save on-save)
        (when back
          (insert back))
        (goto-char (point-min))
        (setq buffer-read-only read-only-p))
      (local-set-key (kbd "C-c C-c") #'decklet-card-back-save)
      (local-set-key (kbd "C-c C-k") #'decklet-card-back-cancel)
      (local-set-key (kbd "E") #'decklet-card-back--make-editable))
    (pop-to-buffer buffer)))

(defun decklet-show-card-back (word &optional on-save)
  "Show the card back for WORD in a read-only popup buffer.
ON-SAVE is called after the user edits and saves via E then C-c C-c."
  (interactive (list (decklet--resolve-word nil "Word: ")))
  (decklet--require-card word)
  (decklet-card-back--open word t on-save))

(defun decklet-edit-card-back (word &optional on-save)
  "Open the card back for WORD in an editable popup buffer.
ON-SAVE is called after saving."
  (interactive (list (decklet--resolve-word nil "Word: ")))
  (decklet--require-card word)
  (decklet-card-back--open word nil on-save))

(provide 'decklet-deck)
;;; decklet-deck.el ends here

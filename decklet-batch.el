;;; decklet-batch.el --- Batch card entry for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yilin Zhang

;;; Commentary:

;; A text buffer for adding many cards at once: one word per line, with
;; optional `#' hint lines and `:tag' lines attached to the word above.
;; Confirming writes every card in one transaction and fires each
;; lifecycle hook once with the whole batch.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'sqlite)
(require 'subr-x)

(require 'decklet-core)
(require 'decklet-db)
(require 'decklet-deck)

(defvar decklet-add-card-batch-buffer-name "*Decklet Batch Add*"
  "Buffer name used for batch card entry.")

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

(defface decklet-add-card-batch-word-face
  '((t :inherit decklet-color-word :weight bold))
  "Face for word lines in batch card entry."
  :group 'decklet)

(defconst decklet-add-card-batch-font-lock-keywords
  `(("^[ \t]*:.*$" . 'decklet-color-tags)
    (,decklet--batch-hint-re
     (0 'font-lock-comment-face)
     (1 'default t))
    ("^[ \t]*\\([^ \t\n].*\\)$"
     (1 (unless (string-match-p "^[ \t]*[#:]"
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

(defun decklet--batch-clean-lines ()
  "Return non-empty trimmed lines from the current buffer.
Lines that are empty or contain only whitespace are removed."
  (seq-filter
   (lambda (line) (not (string-empty-p line)))
   (mapcar #'string-trim
           (split-string (buffer-string) "\n" nil))))

(defun decklet--batch-collect-cards ()
  "Parse the batch buffer into word, hint and optional tags plists.
Lines starting with # add hint text; lines starting with : contain
space-separated :tag tokens.  Both attach to the preceding word and
may be interleaved.  Validate the entire buffer before writing cards."
  (let ((cards nil) (current nil))
    (dolist (line (decklet--batch-clean-lines))
      (cond
       ((string-prefix-p "#" line)
        (unless current (user-error "Hint line must follow a word: %s" line))
        (let ((hint (string-trim (substring line 1))))
          (plist-put current :hint
                     (if (plist-get current :hint)
                         (concat (plist-get current :hint) "\n" hint)
                       hint))))
       ((string-prefix-p ":" line)
        (unless current (user-error "Tag line must follow a word: %s" line))
        (let ((tags (mapcar
                     (lambda (token)
                       (unless (and (string-prefix-p ":" token) (> (length token) 1))
                         (user-error "Expected :tag token, got: %s" token))
                       (substring token 1))
                     (split-string line "[[:space:]]+" t))))
          (plist-put current :tags
                     (decklet-normalize-tags (append (plist-get current :tags) tags)))))
       (t
        (when current (push current cards))
        (setq current (list :word line :hint nil)))))
    (when current (push current cards))
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
         (field-events nil)
         (added 0)
         (refreshed 0)
         (exists 0))
    ;; `with-sqlite-transaction' rolls back on any non-local exit,
    ;; including a `quit', so no transaction is left open behind us.
    (with-sqlite-transaction conn
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
              (push (list :card-id card-id :field 'hint) field-events))
            (when (plist-member card :tags)
              (let ((old (decklet-get-card-tags card-id)))
                (unless (equal old (decklet-add-card-tags card-id (plist-get card :tags)))
                  (push (list :card-id card-id :field 'tags) field-events))))))))
    (when added-events
      (decklet-run-hook-isolated 'decklet-cards-added-functions
                                 (nreverse added-events)))
    (when field-events
      (decklet-run-hook-isolated 'decklet-cards-field-updated-functions
                                 (nreverse field-events)))
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

(provide 'decklet-batch)
;;; decklet-batch.el ends here

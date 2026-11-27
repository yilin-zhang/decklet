;;; decklet-batch.el --- Batch card entry for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yilin Zhang

;;; Commentary:

;; A text buffer for adding many cards at once.  Each line holds one
;; word, optionally followed by `#' hint lines and `:tag' lines.
;; Confirming writes every card in one transaction and fires each
;; lifecycle hook once with the whole batch.

;;; Code:

(require 'cl-lib)
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
  :interactive nil
  ;; A `#' is special only at the start of a line, where it marks a hint.
  ;; The comment variables are set by hand, because `#' comment syntax
  ;; in the syntax table would also catch words such as "C#".
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "#+[ \t]*")
  (setq-local font-lock-defaults '(decklet-add-card-batch-font-lock-keywords))
  (font-lock-refresh-defaults))

(defun decklet--batch-collect-cards ()
  "Parse the batch buffer into plists of :word, :hint and :tags.
The Commentary describes the line format.  A malformed line signals a
`user-error' before any card is written."
  (let ((cards nil) (current nil))
    ;; Respect any active narrowing so users can import just that region.
    (dolist (line (split-string (buffer-string) "\n" t "[ \t\r]+"))
      (cond
       ((string-prefix-p "#" line)
        (unless current (user-error "Hint line must follow a word: %s" line))
        (let ((hint (string-trim (substring line 1))))
          (unless (string-empty-p hint)
            (plist-put current :hint
                       (if (plist-get current :hint)
                           (concat (plist-get current :hint) "\n" hint)
                         hint)))))
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

(defun decklet-batch--close-buffer (buffer)
  "Close BUFFER's window and kill BUFFER, or kill BUFFER directly."
  (when (buffer-live-p buffer)
    (if-let* ((window (get-buffer-window buffer 0)))
        (quit-window t window)
      (kill-buffer buffer))))

(defun decklet-add-card-batch-confirm ()
  "Add every card in the batch buffer and report what happened.
Each lifecycle hook fires once with the events of the whole batch."
  (interactive nil decklet-add-card-batch-mode)
  (unless (derived-mode-p 'decklet-add-card-batch-mode)
    (user-error "Not in a Decklet batch buffer"))
  (let* ((batch-buffer (current-buffer))
         (narrowed (buffer-narrowed-p))
         (done t))
    (decklet-with-db
      (let* ((cards (decklet--batch-collect-cards))
             (conn (decklet-db--ensure))
             (added-events nil)
             (field-events nil)
             (added 0)
             (refreshed 0)
             (exists 0))
        (with-sqlite-transaction conn
          ;; Each hook fires once for the whole batch, after the commit.
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
                  ('refreshed (cl-incf refreshed)
                              (push (list :card-id card-id :field 'added-date)
                                    field-events))
                  ('exists    (cl-incf exists)))
                ;; Fill hint only when the card has none yet, so re-importing
                ;; does not overwrite a hand-written hint.
                (when (and hint
                           (null (decklet-get-card-hint card-id))
                           (decklet-set-card-hint card-id hint))
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
        ;; When narrowed, remove only the imported region and keep the buffer
        ;; open (skipping `:on-confirm') if other entries remain outside it.
        (when (and narrowed (buffer-live-p batch-buffer))
          (with-current-buffer batch-buffer
            (let ((inhibit-read-only t))
              (delete-region (point-min) (point-max))
              (widen))
            (setq done (string-blank-p (buffer-string)))))
        (when (and done (functionp decklet-add-card-batch--on-confirm))
          (condition-case err
              (funcall decklet-add-card-batch--on-confirm
                       (mapcar (lambda (card) (plist-get card :word)) cards))
            (error
             (display-warning
              'decklet
              (format "Batch confirmation callback failed: %s"
                      (error-message-string err))
              :error))))
        (message "Imported %d: %d added, %d refreshed, %d already existed%s"
                 (length cards) added refreshed exists
                 (if done "" " (remaining entries kept)"))))
    (when done
      (decklet-batch--close-buffer batch-buffer))))

(defun decklet-add-card-batch-cancel ()
  "Cancel batch import and close the buffer."
  (interactive nil decklet-add-card-batch-mode)
  (unless (derived-mode-p 'decklet-add-card-batch-mode)
    (user-error "Not in a Decklet batch buffer"))
  (message "Batch import canceled")
  (decklet-batch--close-buffer (current-buffer)))

(defun decklet-add-card-batch (&optional words &rest options)
  "Open a buffer for batch word entry.
WORDS, when non-nil, are inserted one per line.
OPTIONS is a plist supporting :buffer-name, :title, :on-confirm and
:message-prefix."
  (interactive)
  (let ((buffer (get-buffer-create
                 (or (plist-get options :buffer-name)
                     decklet-add-card-batch-buffer-name))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'decklet-add-card-batch-mode)
        (decklet-add-card-batch-mode))
      (setq header-line-format
            (replace-regexp-in-string
             "%" "%%" (or (plist-get options :title) "Decklet Batch Add"))
            decklet-add-card-batch--on-confirm (plist-get options :on-confirm))
      (when (or words options)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (when words
            (insert (string-join words "\n") "\n")))
        (goto-char (point-min))))
    (pop-to-buffer buffer)
    (message "%sType %s to confirm, %s to cancel."
             (if (string-empty-p (or (plist-get options :message-prefix) ""))
                 ""
               (concat (plist-get options :message-prefix) " "))
             (substitute-command-keys "\\[decklet-add-card-batch-confirm]")
             (substitute-command-keys "\\[decklet-add-card-batch-cancel]"))))

(provide 'decklet-batch)
;;; decklet-batch.el ends here

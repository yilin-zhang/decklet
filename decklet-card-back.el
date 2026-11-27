;;; decklet-card-back.el --- Card back popup for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yilin Zhang

;;; Commentary:

;; Popup buffer for viewing and editing a card's back.  Saving the
;; buffer writes the card back to the database, and killing a modified
;; buffer prompts first.

;;; Code:

(require 'decklet-core)
(require 'decklet-db)
(require 'decklet-deck)

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
      (decklet-with-db
        (decklet-set-card-back card-id content)
        (set-buffer-modified-p nil)
        (message "Wrote card back of word \"%s\""
                 (decklet-get-card-word card-id))))))

(defun decklet-card-back--write-contents ()
  "`write-contents-functions' handler for `decklet-card-back-mode'.
Save the card back to the DB and return non-nil, which tells Emacs
the buffer has been written."
  (decklet-save-card-back)
  t)

(defun decklet-card-back--kill-buffer-query ()
  "`kill-buffer-query-functions' handler for `decklet-card-back-mode'.
Offer to save a modified buffer, and return nil if the user cancels."
  (if (not (buffer-modified-p))
      t
    (pcase (read-char-choice
            (format "Card back \"%s\" modified; (s)ave, (d)iscard, or (c)ancel? "
                    (buffer-name))
            '(?s ?d ?c))
      (?s (decklet-save-card-back) t)
      (?d (set-buffer-modified-p nil) t)
      (?c nil))))

(defun decklet-card-back--close-at-session-end ()
  "Kill the unmodified card back popups if this is the last session buffer.
Review and edit call this while their buffer is being killed."
  (unless (decklet-db--session-buffers (current-buffer))
    (dolist (buffer (buffer-list))
      (when (and (buffer-local-value 'decklet-card-back-mode buffer)
                 (not (buffer-modified-p buffer)))
        (kill-buffer buffer)))))

(define-minor-mode decklet-card-back-mode
  "Minor mode for editing a Decklet card back in a popup."
  :lighter " DeckletEdit"
  (if decklet-card-back-mode
      (progn
        (add-hook 'write-contents-functions
                  #'decklet-card-back--write-contents nil t)
        (add-hook 'kill-buffer-query-functions
                  #'decklet-card-back--kill-buffer-query nil t))
    (remove-hook 'write-contents-functions
                 #'decklet-card-back--write-contents t)
    (remove-hook 'kill-buffer-query-functions
                 #'decklet-card-back--kill-buffer-query t)))

(defun decklet-show-card-back (word)
  "Open the card back popup buffer for WORD."
  (interactive (list (decklet-prompt-word "Word: ")))
  (let* ((card (decklet-with-db
                 (or (decklet-db--select-card-row-by-word word)
                     (user-error "No card found for \"%s\"" word))))
         (card-id (plist-get card :card-id))
         (back (plist-get card :back))
         (buf-name (format "*Decklet Card Back: %s*" word))
         (buffer (get-buffer-create buf-name)))
    ;; Keep unsaved edits in the popup and show them as is.
    (if (and (buffer-modified-p buffer)
             (eql (buffer-local-value 'decklet-card-back--card-id buffer)
                  card-id))
        (pop-to-buffer buffer)
      (decklet-card-back--load buffer card-id back)
      (pop-to-buffer buffer))))

(defun decklet-card-back--load (buffer card-id back)
  "Fill BUFFER with CARD-ID's card BACK and enable the popup mode."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (erase-buffer)
      (funcall decklet-card-back-buffer-major-mode)
      (setq-local decklet-card-back--card-id card-id)
      (when back
        (insert back))
      (goto-char (point-min)))
    ;; An existing back opens read-only.
    (setq buffer-read-only (and back t))
    ;; Loading is not an edit, so killing the buffer must not prompt.
    (set-buffer-modified-p nil)
    (decklet-card-back-mode 1)))

(provide 'decklet-card-back)
;;; decklet-card-back.el ends here

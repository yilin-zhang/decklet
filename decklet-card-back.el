;;; decklet-card-back.el --- Card back popup for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yilin Zhang

;;; Commentary:

;; Popup buffer for viewing and editing a card's back.  The buffer is
;; backed by the database rather than a file: saving writes the card
;; back, and killing a modified buffer prompts first.

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

(defvar-local decklet-card-back--release-session nil
  "Disposer for this buffer's DB session lease, or nil when not held.
Held while `decklet-card-back-mode' is on: the popup buffer can
outlive the mode, so the lease has to be released when the mode is
switched off rather than only when the buffer is killed.")

(define-minor-mode decklet-card-back-mode
  "Minor mode for editing a Decklet card back in a popup."
  :lighter " DeckletEdit"
  (if decklet-card-back-mode
      (progn
        (unless decklet-card-back--release-session
          (setq decklet-card-back--release-session
                (decklet-db-acquire-session-buffer)))
        (add-hook 'write-contents-functions
                  #'decklet-card-back--write-contents nil t)
        (add-hook 'kill-buffer-query-functions
                  #'decklet-card-back--kill-buffer-query nil t))
    (when decklet-card-back--release-session
      (funcall decklet-card-back--release-session)
      (setq decklet-card-back--release-session nil))
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
    ;; A popup with unsaved edits is the user's work in progress, not a
    ;; stale view: show it as is instead of reloading over it.
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
    ;; read-only by default
    (setq buffer-read-only (and back t))
    ;; Loading content from the DB isn't a user edit; clear the modified
    ;; flag so `decklet-card-back--kill-buffer-query' doesn't prompt on a
    ;; buffer the user hasn't actually touched.
    (set-buffer-modified-p nil)
    (decklet-card-back-mode 1)))

(provide 'decklet-card-back)
;;; decklet-card-back.el ends here

;;; decklet-card-back-test.el --- Tests for decklet-card-back.el -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

(defun decklet-card-back-test--open (word)
  "Open WORD's card-back popup without touching windows and return its buffer."
  (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
    (decklet-show-card-back word))
  (let ((card-id (decklet-test--card-id word)))
    (seq-find (lambda (buffer)
                (eql card-id (buffer-local-value 'decklet-card-back--card-id buffer)))
              (buffer-list))))

(defun decklet-card-back-test--kill (buf)
  "Kill BUF, discarding any unsaved edits."
  (when (buffer-live-p buf)
    (with-current-buffer buf (set-buffer-modified-p nil))
    (kill-buffer buf)))

(ert-deftest decklet-test-card-back-kill-asks-before-losing-edits ()
  "Killing a modified card back asks to save, discard, or cancel.
Save writes the edit, discard keeps the stored back, and cancel keeps
the buffer and its edit."
  (pcase-dolist (`(,choice ,alive ,stored) '((?s nil "new-back")
                                             (?d nil "old-back")
                                             (?c t "old-back")))
    (decklet-test--with-temp-db
      (decklet--add-card "bright")
      (decklet-set-card-back (decklet-test--card-id "bright") "old-back")
      (let ((buf (decklet-card-back-test--open "bright")))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (let ((inhibit-read-only t))
                  (erase-buffer)
                  (insert "new-back")))
              (cl-letf (((symbol-function 'read-char-choice) (lambda (&rest _) choice)))
                (kill-buffer buf))
              (should (eq alive (buffer-live-p buf)))
              (when alive (should (buffer-modified-p buf)))
              (should (equal stored (decklet-get-card-back
                                     (decklet-test--card-id "bright")))))
          (decklet-card-back-test--kill buf))))))

(ert-deftest decklet-test-card-back-reopen-keeps-unsaved-edits ()
  "Reopening a modified card back keeps its unsaved edits, even after rename."
  (decklet-test--with-temp-db
    (let* ((id (plist-get (decklet--add-card "glow") :card-id))
           (buf (decklet-card-back-test--open "glow")))
      (unwind-protect
          (progn
            (with-current-buffer buf (insert "draft"))
            (should (eq buf (decklet-card-back-test--open "glow")))
            (decklet-set-card-word id "gleam")
            (should (eq buf (decklet-card-back-test--open "gleam")))
            (with-current-buffer buf
              (should (buffer-modified-p))
              (should (string= "draft" (buffer-string)))))
        (decklet-card-back-test--kill buf)))))

(ert-deftest decklet-test-card-back-delete-and-narrow-preserve-content ()
  "Saving while narrowed writes the full buffer; deleting preserves modified drafts."
  (decklet-test--with-temp-db
    (let* ((id (plist-get (decklet--add-card "glow") :card-id))
           (clean-id (plist-get (decklet--add-card "clean") :card-id))
           (buf (decklet-card-back-test--open "glow"))
           (clean-buf (decklet-card-back-test--open "clean"))
           (reopened nil))
      (unwind-protect
          (progn
            (with-current-buffer buf
              (insert "line1\nline2")
              (undo-boundary)
              (narrow-to-region (point-min) (+ (point-min) 5))
              (decklet-save-card-back))
            (should (equal "line1\nline2" (decklet-get-card-back id)))
            ;; Undoing past a save must still mark the popup as modified.
            (with-current-buffer buf
              (widen)
              (undo)
              (should (buffer-modified-p))
              (insert "line1\nline2\ndraft"))
            (decklet-delete-card clean-id)
            (should-not (buffer-live-p clean-buf))
            (decklet-delete-card id)
            (should (buffer-live-p buf))
            (decklet--add-card "glow")
            (setq reopened (decklet-card-back-test--open "glow"))
            (should-not (eq reopened buf))
            (with-current-buffer buf
              (should-not (memq #'decklet-save-card-back write-contents-functions))
              (should (string= "line1\nline2\ndraft" (buffer-string)))))
        (decklet-card-back-test--kill buf)
        (decklet-card-back-test--kill clean-buf)
        (decklet-card-back-test--kill reopened)))))

(ert-deftest decklet-test-card-back-save-outside-session-closes-connection ()
  "Saving a card back with no review or edit open writes it and disconnects.
The save opens the connection itself, so it must not leave it open."
  (decklet-test--with-temp-db
    (decklet--add-card "calm")
    (let ((buf (decklet-card-back-test--open "calm")))
      (decklet-db--disconnect)
      (unwind-protect
          (progn
            (with-current-buffer buf
              (insert "quiet")
              (decklet-save-card-back))
            (should-not decklet-db--conn)
            (should (equal "quiet" (decklet-get-card-back
                                    (decklet-test--card-id "calm")))))
        (decklet-card-back-test--kill buf)))))

(provide 'decklet-card-back-test)
;;; decklet-card-back-test.el ends here

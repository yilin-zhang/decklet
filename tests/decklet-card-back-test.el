;;; decklet-card-back-test.el --- This file tests decklet-card-back.el. -*- lexical-binding: t; -*-

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
  "Reopening a modified card back shows the edits instead of reloading."
  (decklet-test--with-temp-db
    (decklet--add-card "glow")
    (let ((buf (decklet-card-back-test--open "glow")))
      (unwind-protect
          (progn
            (with-current-buffer buf (insert "draft"))
            (decklet-card-back-test--open "glow")
            (with-current-buffer buf
              (should (buffer-modified-p))
              (should (string= "draft" (buffer-string)))))
        (decklet-card-back-test--kill buf)))))

(provide 'decklet-card-back-test)
;;; decklet-card-back-test.el ends here

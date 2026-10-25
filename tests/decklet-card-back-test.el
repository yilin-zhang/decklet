;;; decklet-card-back-test.el --- This file tests decklet-card-back.el. -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

;;; Card back popup

(defmacro decklet-card-back-test--show (word)
  "Open the card-back popup for WORD without touching the window layout."
  `(cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
     (decklet-show-card-back ,word)))

(defun decklet-card-back-test--card-back-buffer (word)
  "Return the open card-back buffer associated with WORD."
  (let ((card-id (decklet-test--card-id word)))
    (seq-find (lambda (buffer)
                (eql card-id
                     (buffer-local-value 'decklet-card-back--card-id buffer)))
              (buffer-list))))

(ert-deftest decklet-test-card-back-show-readonly-with-content ()
  "A card that has a back opens read-only, showing the stored content."
  (decklet-test--with-temp-db
    (decklet-db--update-back
     (decklet-test--add-card-meta "bright" :state :new :timestamp "20250101T000000Z")
     "shining example")
    (decklet-card-back-test--show "bright")
    (let ((buf (decklet-card-back-test--card-back-buffer "bright")))
      (unwind-protect
          (with-current-buffer buf
            (should decklet-db--session-buffer)
            (should buffer-read-only)
            (should (string= "shining example"
                             (buffer-substring-no-properties (point-min) (point-max)))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest decklet-test-card-back-show-editable-when-absent ()
  "A card with no back opens an editable buffer."
  (decklet-test--with-temp-db
    (decklet-test--add-card-meta "glow" :state :new :timestamp "20250101T000000Z")
    (decklet-card-back-test--show "glow")
    (let ((buf (decklet-card-back-test--card-back-buffer "glow")))
      (unwind-protect
          (with-current-buffer buf
            (should decklet-db--session-buffer)
            (should-not buffer-read-only))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest decklet-test-card-back-show-resets-readonly-when-cleared ()
  "Reopening a card-back buffer after its back is cleared drops stale read-only."
  (decklet-test--with-temp-db
    (let ((id (decklet-test--add-card-meta "bright" :state :new
                                           :timestamp "20250101T000000Z")))
      (decklet-db--update-back id "old back")
      (decklet-card-back-test--show "bright")
      (with-current-buffer (decklet-card-back-test--card-back-buffer "bright")
        (should buffer-read-only))
      (decklet-db--update-back id nil)
      (decklet-card-back-test--show "bright")
      (let ((buf (decklet-card-back-test--card-back-buffer "bright")))
        (unwind-protect
            (with-current-buffer buf
              (should-not buffer-read-only)
              (should (string-empty-p (buffer-string))))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

(ert-deftest decklet-test-card-back-save-errors-without-card ()
  "Saving a card back with no associated card signals a user error."
  (with-temp-buffer
    (should-error (decklet-save-card-back) :type 'user-error)))

(defun decklet-card-back-test--open-dirty-card-back (word original new)
  "Seed WORD and return a modified card-back buffer.
ORIGINAL is the stored back and NEW replaces its text in the open popup.
The caller is responsible for killing the buffer."
  (decklet-db--update-back
   (decklet-test--add-card-meta word :state :new :timestamp "20250101T000000Z")
   original)
  (decklet-card-back-test--show word)
  (let ((buf (decklet-card-back-test--card-back-buffer word)))
    (with-current-buffer buf
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert new)
      (set-buffer-modified-p t))
    buf))

(defmacro decklet-card-back-test--kill-with-choice (buf choice)
  "Kill BUF answering the save/discard/cancel prompt with CHOICE (a char)."
  `(cl-letf (((symbol-function 'read-char-choice) (lambda (_p _c) ,choice)))
     (kill-buffer ,buf)))

(ert-deftest decklet-test-card-back-kill-query-save ()
  "Answering `save' writes the new card-back content and kills its buffer."
  (decklet-test--with-temp-db
    (let ((buf (decklet-card-back-test--open-dirty-card-back "bright" "old-back" "new-back")))
      (unwind-protect
          (progn
            (decklet-card-back-test--kill-with-choice buf ?s)
            (should-not (buffer-live-p buf))
            (should (string= "new-back"
                             (decklet-db--select-card-back (decklet-test--card-id "bright")))))
        (when (buffer-live-p buf)
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest decklet-test-card-back-kill-query-discard ()
  "Answering `discard' kills the card-back buffer without writing.
The database retains its old back."
  (decklet-test--with-temp-db
    (let ((buf (decklet-card-back-test--open-dirty-card-back "bright" "old-back" "new-back")))
      (unwind-protect
          (progn
            (decklet-card-back-test--kill-with-choice buf ?d)
            (should-not (buffer-live-p buf))
            (should (string= "old-back"
                             (decklet-db--select-card-back (decklet-test--card-id "bright")))))
        (when (buffer-live-p buf)
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest decklet-test-card-back-kill-query-cancel ()
  "Answering `cancel' leaves the card-back buffer alive and modified.
The database retains its old back."
  (decklet-test--with-temp-db
    (let ((buf (decklet-card-back-test--open-dirty-card-back "bright" "old-back" "new-back")))
      (unwind-protect
          (progn
            (decklet-card-back-test--kill-with-choice buf ?c)
            (should (buffer-live-p buf))
            (should (buffer-modified-p buf))
            (should (string= "old-back"
                             (decklet-db--select-card-back (decklet-test--card-id "bright")))))
        (when (buffer-live-p buf)
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

;;; Card back reopen

(ert-deftest decklet-test-card-back-reopen-keeps-unsaved-edits ()
  "Reopening a modified card back shows the edits instead of reloading."
  (decklet-test--with-temp-db
    (decklet-test--add-card-meta "glow" :state :new :timestamp "20250101T000000Z")
    (decklet-card-back-test--show "glow")
    (let ((buf (decklet-card-back-test--card-back-buffer "glow")))
      (unwind-protect
          (progn
            (with-current-buffer buf (insert "draft"))
            (decklet-card-back-test--show "glow")
            (with-current-buffer buf
              (should (buffer-modified-p))
              (should (string= "draft" (buffer-string)))))
        (when (buffer-live-p buf)
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(provide 'decklet-card-back-test)
;;; decklet-card-back-test.el ends here

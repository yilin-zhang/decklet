;;; decklet-deck-test.el --- This file tests decklet-deck.el and card display. -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

;;; Effective state derivation

(ert-deftest decklet-test-deck-card-effective-state ()
  "A card is `:new' until its first review, then mirrors its stored state.
Holds for both the raw state+last-review form and the card-meta form."
  (should (eq (decklet-card-effective-state :learning nil) :new))
  (should (eq (decklet-card-effective-state :learning "") :new))
  (should (eq (decklet-card-effective-state :learning "2025-01-01T00:00:00Z") :learning))
  (should (eq (decklet-card-effective-state :relearning "2025-01-01T00:00:00Z") :relearning))
  (should (eq (decklet-card-effective-state :review "2025-01-01T00:00:00Z") :review))
  (should (eq (decklet-card-effective-state :unknown "2025-01-01T00:00:00Z") :review))
  (should (eq (decklet-card-meta-effective-state
               (make-decklet-card-meta :state :learning :last-review nil))
              :new))
  (should (eq (decklet-card-meta-effective-state
               (make-decklet-card-meta :state :learning :last-review "2025-01-01T00:00:00Z"))
              :learning)))

;;; Field setters

(ert-deftest decklet-test-deck-field-setters-fire-hook-only-on-change ()
  "Hint/back setters notify only for normalized value changes."
  (decklet-test--with-temp-db
    (let ((id (decklet-test--add-card-meta "glow" :state :learning
                                           :timestamp "20250101T000000Z"))
          (events nil))
      (let ((decklet-cards-field-updated-functions
             (list (lambda (evs) (setq events (append events evs))))))
        (should (decklet-set-card-hint id "old hint"))
        (should-not (decklet-set-card-hint id " old hint "))
        (should (decklet-set-card-back id "old back"))
        (should-not (decklet-set-card-back id "old back")))
      (should (equal (mapcar (lambda (e) (plist-get e :field)) events) '(hint back))))))

;;; Card identity

(ert-deftest decklet-test-deck-add-card-refresh-preserves-id ()
  "Re-adding an existing new card refreshes it in place with the same id."
  (decklet-test--with-temp-db
    (let ((decklet-add-and-refresh t))
      (decklet--add-card "alpha")
      (let ((first (decklet-test--card-id "alpha")))
        (decklet--add-card "alpha")
        (should (= first (decklet-test--card-id "alpha")))))))

(ert-deftest decklet-test-deck-delete-and-readd-mints-new-id ()
  "Deleting then re-adding a word gives the new card a fresh id."
  (decklet-test--with-temp-db
    (decklet--add-card "beta")
    (let ((first (decklet-test--card-id "beta")))
      (decklet-delete-card first)
      (decklet--add-card "beta")
      (should-not (= first (decklet-test--card-id "beta"))))))

;;; Card back popup

(defmacro decklet-deck-test--show (word)
  "Open the card-back popup for WORD without touching the window layout."
  `(cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
     (decklet-show-card-back ,word)))

(defun decklet-deck-test--card-back-buffer (word)
  "Return the open card-back buffer associated with WORD."
  (let ((card-id (decklet-test--card-id word)))
    (seq-find (lambda (buffer)
                (eql card-id
                     (buffer-local-value 'decklet-card-back--card-id buffer)))
              (buffer-list))))

(ert-deftest decklet-test-deck-card-back-show-readonly-with-content ()
  "A card that has a back opens read-only, showing the stored content."
  (decklet-test--with-temp-db
    (decklet-db--update-back
     (decklet-test--add-card-meta "bright" :state :new :timestamp "20250101T000000Z")
     "shining example")
    (decklet-deck-test--show "bright")
    (let ((buf (decklet-deck-test--card-back-buffer "bright")))
      (unwind-protect
          (with-current-buffer buf
            (should decklet-db--dependent-buffer)
            (should buffer-read-only)
            (should (string= "shining example"
                             (buffer-substring-no-properties (point-min) (point-max)))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest decklet-test-deck-card-back-show-editable-when-absent ()
  "A card with no back opens an editable buffer."
  (decklet-test--with-temp-db
    (decklet-test--add-card-meta "glow" :state :new :timestamp "20250101T000000Z")
    (decklet-deck-test--show "glow")
    (let ((buf (decklet-deck-test--card-back-buffer "glow")))
      (unwind-protect
          (with-current-buffer buf
            (should decklet-db--dependent-buffer)
            (should-not buffer-read-only))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest decklet-test-deck-card-back-show-resets-readonly-when-cleared ()
  "Reopening a card-back buffer after its back is cleared drops stale read-only."
  (decklet-test--with-temp-db
    (let ((id (decklet-test--add-card-meta "bright" :state :new
                                           :timestamp "20250101T000000Z")))
      (decklet-db--update-back id "old back")
      (decklet-deck-test--show "bright")
      (with-current-buffer (decklet-deck-test--card-back-buffer "bright")
        (should buffer-read-only))
      (decklet-db--update-back id nil)
      (decklet-deck-test--show "bright")
      (let ((buf (decklet-deck-test--card-back-buffer "bright")))
        (unwind-protect
            (with-current-buffer buf
              (should-not buffer-read-only)
              (should (string-empty-p (buffer-string))))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

(ert-deftest decklet-test-deck-save-card-back-errors-without-card ()
  "Saving a card back with no associated card signals a user error."
  (with-temp-buffer
    (should-error (decklet-save-card-back) :type 'user-error)))

(defun decklet-deck-test--open-dirty-card-back (word original new)
  "Seed WORD and return a modified card-back buffer.
ORIGINAL is the stored back and NEW replaces its text in the open popup.
The caller is responsible for killing the buffer."
  (decklet-db--update-back
   (decklet-test--add-card-meta word :state :new :timestamp "20250101T000000Z")
   original)
  (decklet-deck-test--show word)
  (let ((buf (decklet-deck-test--card-back-buffer word)))
    (with-current-buffer buf
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert new)
      (set-buffer-modified-p t))
    buf))

(defmacro decklet-deck-test--kill-with-choice (buf choice)
  "Kill BUF answering the save/discard/cancel prompt with CHOICE (a char)."
  `(cl-letf (((symbol-function 'read-char-choice) (lambda (_p _c) ,choice)))
     (kill-buffer ,buf)))

(ert-deftest decklet-test-deck-card-back-kill-query-save ()
  "Answering `save' writes the new card-back content and kills its buffer."
  (decklet-test--with-temp-db
    (let ((buf (decklet-deck-test--open-dirty-card-back "bright" "old-back" "new-back")))
      (unwind-protect
          (progn
            (decklet-deck-test--kill-with-choice buf ?s)
            (should-not (buffer-live-p buf))
            (should (string= "new-back"
                             (decklet-db--select-card-back (decklet-test--card-id "bright")))))
        (when (buffer-live-p buf)
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest decklet-test-deck-card-back-kill-query-discard ()
  "Answering `discard' kills the card-back buffer without writing.
The database retains its old back."
  (decklet-test--with-temp-db
    (let ((buf (decklet-deck-test--open-dirty-card-back "bright" "old-back" "new-back")))
      (unwind-protect
          (progn
            (decklet-deck-test--kill-with-choice buf ?d)
            (should-not (buffer-live-p buf))
            (should (string= "old-back"
                             (decklet-db--select-card-back (decklet-test--card-id "bright")))))
        (when (buffer-live-p buf)
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest decklet-test-deck-card-back-kill-query-cancel ()
  "Answering `cancel' leaves the card-back buffer alive and modified.
The database retains its old back."
  (decklet-test--with-temp-db
    (let ((buf (decklet-deck-test--open-dirty-card-back "bright" "old-back" "new-back")))
      (unwind-protect
          (progn
            (decklet-deck-test--kill-with-choice buf ?c)
            (should (buffer-live-p buf))
            (should (buffer-modified-p buf))
            (should (string= "old-back"
                             (decklet-db--select-card-back (decklet-test--card-id "bright")))))
        (when (buffer-live-p buf)
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

;;; Batch collection parsing

(ert-deftest decklet-test-deck-batch-collect-cards-with-hints ()
  "Batch parsing attaches hint lines to the preceding word.
It recognizes the `#' prefix and joins multi-line hints."
  (with-temp-buffer
    (insert "\n  lucid  \n# adj.\n\n\t\n# lucid rain\n  dirt\n# ...\n")
    (should (equal (decklet--batch-collect-cards)
                   '((:word "lucid" :hint "adj.\nlucid rain")
                     (:word "dirt" :hint "..."))))))

(ert-deftest decklet-test-deck-batch-collect-cards-rejects-orphan-hint ()
  "A hint line with no preceding word is an error."
  (with-temp-buffer
    (insert "# lonely hint\nlucid\n")
    (should-error (decklet--batch-collect-cards))))

(provide 'decklet-deck-test)
;;; decklet-deck-test.el ends here

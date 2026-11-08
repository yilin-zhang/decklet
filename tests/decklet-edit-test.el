;;; decklet-edit-test.el --- This file tests decklet-edit.el. -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

(defmacro decklet-edit-test--with-buffer (&rest body)
  "Run BODY inside a live `decklet-edit-mode' buffer backed by the test DB.
Marks and filter are reset for the duration; the buffer is killed on exit.
BODY can refer to `buf', the edit buffer."
  (declare (indent 0) (debug t))
  `(let ((decklet-edit--marked (make-hash-table :test 'equal))
         (decklet-edit--filter 'all)
         (buf (get-buffer-create "*decklet-edit-test*")))
     (unwind-protect
         (with-current-buffer buf
           (decklet-edit-mode)
           (decklet-edit-refresh)
           ,@body)
       (when (buffer-live-p buf)
         (with-current-buffer buf (setq kill-buffer-query-functions nil))
         (kill-buffer buf)))))

(defun decklet-edit-test--confirm (fn)
  "Call FN with `yes-or-no-p' forced to t."
  (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
    (funcall fn)))

;;; Delete

(ert-deftest decklet-test-edit-delete-acts-on-marks-or-point ()
  "Delete removes the marked cards, or the card at point when none is marked."
  (decklet-test--with-temp-db
    (dolist (w '("alpha" "beta" "gamma" "delta")) (decklet--add-card w))
    (decklet-edit-test--with-buffer
      (decklet-edit--goto-card-id (decklet-test--card-id "alpha"))
      (decklet-edit-mark-at-point)
      (decklet-edit--goto-card-id (decklet-test--card-id "beta"))
      (decklet-edit-mark-at-point)
      (decklet-edit--goto-card-id (decklet-test--card-id "gamma"))
      (decklet-edit-test--confirm #'decklet-edit-delete-card)
      (should (equal '("delta" "gamma") (sort (decklet-list-words) #'string<)))
      (should (= 0 (hash-table-count decklet-edit--marked)))
      (decklet-edit--goto-card-id (decklet-test--card-id "gamma"))
      (decklet-edit-test--confirm #'decklet-edit-delete-card)
      (should (equal '("delta") (decklet-list-words))))))

(ert-deftest decklet-test-edit-delete-cancelled-is-noop ()
  "Declining the delete confirmation leaves the deck and marks untouched."
  (decklet-test--with-temp-db
    (decklet-test--add-card-meta "alpha")
    (decklet-edit-test--with-buffer
      (decklet-edit--goto-card-id (decklet-test--card-id "alpha"))
      (decklet-edit-mark-at-point)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (decklet-edit-delete-card))
      (should (decklet-db--select-card-row-by-word "alpha"))
      (should (= 1 (hash-table-count decklet-edit--marked))))))

;;; Archive

(ert-deftest decklet-test-edit-archive-then-unarchive-via-filter ()
  "Archiving hides a card from the active deck.
Under the archived filter, the same command unarchives it."
  (decklet-test--with-temp-db
    (decklet-test--add-card-meta "alpha")
    (decklet-edit-test--with-buffer
      (decklet-edit--goto-card-id (decklet-test--card-id "alpha"))
      (decklet-edit-test--confirm #'decklet-edit-archive-card)
      (should (= 1 (length (decklet-db--select-card-rows 'archived nil))))
      (decklet-edit-filter-toggle-archive)
      (decklet-edit--goto-card-id (decklet-test--card-id "alpha"))
      (decklet-edit-test--confirm #'decklet-edit-archive-card)
      (should (= 0 (length (decklet-db--select-card-rows 'archived nil)))))))

(ert-deftest decklet-test-edit-filter-tag-refuses-other-buffers ()
  "Filtering by tag outside the edit buffer leaves that buffer untouched."
  (decklet-test--with-temp-db
    (decklet--add-card "gamma")
    (with-temp-buffer
      (insert "user text\n")
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "")))
        (should-error (decklet-edit-filter-tag) :type 'user-error))
      (should (string= "user text\n" (buffer-string))))))

(provide 'decklet-edit-test)
;;; decklet-edit-test.el ends here

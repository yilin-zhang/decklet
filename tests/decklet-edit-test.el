;;; decklet-edit-test.el --- Tests for decklet-edit.el -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

(defmacro decklet-edit-test--with-buffer (&rest body)
  "Run BODY inside a live `decklet-edit-mode' buffer backed by the test DB.
The buffer is killed on exit.  BODY can refer to `buf', the edit buffer."
  (declare (indent 0) (debug t))
  `(let* ((decklet-edit-buffer-name "*decklet-edit-test*")
          (buf (get-buffer-create decklet-edit-buffer-name)))
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
  "Delete removes the marked cards, or the card at point when none is marked.
Declining the confirmation deletes nothing and keeps the marks.  Marks on
cards deleted elsewhere do not break bulk delete, and switching filters
clears marks so hidden cards cannot be deleted."
  (decklet-test--with-temp-db
    (dolist (w '("alpha" "beta" "gamma" "delta")) (decklet--add-card w))
    (decklet-edit-test--with-buffer
      (decklet-edit--goto-card-id (decklet-test--card-id "alpha"))
      (decklet-edit-mark-at-point)
      (decklet-edit--goto-card-id (decklet-test--card-id "beta"))
      (decklet-edit-mark-at-point)
      ;; Declining keeps everything and leaves the marks intact.
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (decklet-edit-delete-card))
      (should (= 4 (length (decklet-list-words))))
      ;; A mark on a card deleted elsewhere drops cleanly before bulk delete.
      (decklet-delete-card (decklet-test--card-id "alpha"))
      (decklet-edit--goto-card-id (decklet-test--card-id "gamma"))
      (decklet-edit-test--confirm #'decklet-edit-delete-card)
      (should (equal '("delta" "gamma") (sort (decklet-list-words) #'string<)))
      ;; Switching filters clears marks so hidden active cards stay safe.
      (decklet-edit--goto-card-id (decklet-test--card-id "delta"))
      (decklet-edit-mark-at-point)
      (decklet-edit-filter-toggle-archive)
      (should-error (decklet-edit-test--confirm #'decklet-edit-delete-card)
                    :type 'user-error)
      (should (equal '("delta" "gamma") (sort (decklet-list-words) #'string<)))
      ;; With no marks left, delete removes the card at point.
      (decklet-edit-filter-toggle-archive)
      (decklet-edit--goto-card-id (decklet-test--card-id "gamma"))
      (decklet-edit-test--confirm #'decklet-edit-delete-card)
      (should (equal '("delta") (decklet-list-words))))))

;;; Filter

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

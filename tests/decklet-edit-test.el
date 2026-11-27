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
  "Delete removes the marked cards, or the card at point when none is marked.
Declining the confirmation deletes nothing and keeps the marks."
  (decklet-test--with-temp-db
    (dolist (w '("alpha" "beta" "gamma" "delta")) (decklet--add-card w))
    (decklet-edit-test--with-buffer
      (decklet-edit--goto-card-id (decklet-test--card-id "alpha"))
      (decklet-edit-mark-at-point)
      (decklet-edit--goto-card-id (decklet-test--card-id "beta"))
      (decklet-edit-mark-at-point)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (decklet-edit-delete-card))
      (should (= 4 (length (decklet-list-words))))
      (should (= 2 (hash-table-count decklet-edit--marked)))
      (decklet-edit--goto-card-id (decklet-test--card-id "gamma"))
      (decklet-edit-test--confirm #'decklet-edit-delete-card)
      (should (equal '("delta" "gamma") (sort (decklet-list-words) #'string<)))
      (should (= 0 (hash-table-count decklet-edit--marked)))
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

;;; Startup

(ert-deftest decklet-test-edit-refused-connection-leaves-no-buffer ()
  "Refusing the DB connection aborts `decklet-edit' before creating its buffer."
  (decklet-test--with-temp-db
    (let* ((decklet-edit-buffer-name "*decklet-edit-refused-test*")
           (start-hook-ran nil)
           (decklet-edit-start-hook (list (lambda () (setq start-hook-ran t))))
           (decklet-db-pre-connect-hook
            (list (lambda () (user-error "Refused")))))
      (should-error (decklet-edit) :type 'user-error)
      (should-not start-hook-ran)
      (should-not (get-buffer decklet-edit-buffer-name))
      (should-not decklet-db--conn))))

(provide 'decklet-edit-test)
;;; decklet-edit-test.el ends here

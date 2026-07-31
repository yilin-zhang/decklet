;;; decklet-edit-test.el --- Tests for decklet-edit.el -*- lexical-binding: t; -*-

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

;;; Mode setup

(ert-deftest decklet-test-edit-mode-registers-owner ()
  "`decklet-edit-mode' marks its buffer as a Decklet session owner."
  (with-temp-buffer
    (decklet-edit-mode)
    (should decklet-db--owner-buffer)))

;;; Marking

(ert-deftest decklet-test-edit-mark-region-marks-covered-rows ()
  "`decklet-edit--mark-region' marks every card row between two positions."
  (decklet-test--with-temp-db
   (dolist (w '("alpha" "beta" "gamma")) (decklet-test--add-card-meta w))
   (decklet-edit-test--with-buffer
    (let ((alpha (decklet-test--card-id "alpha"))
          (beta (decklet-test--card-id "beta"))
          (gamma (decklet-test--card-id "gamma"))
          (end (save-excursion
                 (decklet-edit--goto-card-id (decklet-test--card-id "beta"))
                 (line-end-position))))
      (decklet-edit--mark-region (point-min) end)
      (should (gethash alpha decklet-edit--marked))
      (should (gethash beta decklet-edit--marked))
      (should-not (gethash gamma decklet-edit--marked))))))

(ert-deftest decklet-test-edit-mark-adds-row-and-indicator-overlays ()
  "Marking a row records its card id and adds two overlays (row + indicator)."
  (decklet-test--with-temp-db
   (decklet-test--add-card-meta "alpha")
   (decklet-edit-test--with-buffer
    (goto-char (point-min))
    (decklet-edit-mark-at-point)
    (should (gethash (decklet-test--card-id "alpha") decklet-edit--marked))
    (should (= 2 (length (seq-filter (lambda (o) (overlay-get o 'decklet-mark))
                                     (overlays-in (point-min) (point-max)))))))))

;;; Navigation helpers

(ert-deftest decklet-test-edit-goto-card-id ()
  "`decklet-edit--goto-card-id' moves to the matching row."
  (decklet-test--with-temp-db
   (dolist (w '("alpha" "beta")) (decklet-test--add-card-meta w))
   (decklet-edit-test--with-buffer
    (let ((beta (decklet-test--card-id "beta")))
      (should (decklet-edit--goto-card-id beta))
      (should (eql (tabulated-list-get-id) beta))))))

(ert-deftest decklet-test-edit-preserving-window-position-binds-flag-in-body ()
  "The outer `decklet-edit--preserving-window-position' binds the flag for its
body; nested calls see it set and unwind it on exit.  No window is needed."
  (let ((decklet-edit--preserving-point nil)
        (flag-values '()))
    (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) nil)))
      (decklet-edit--preserving-window-position
       (push decklet-edit--preserving-point flag-values)
       (decklet-edit--preserving-window-position
        (push decklet-edit--preserving-point flag-values))))
    (should (equal flag-values '(t t)))
    (should (null decklet-edit--preserving-point))))

;;; Sorting and rendering

(ert-deftest decklet-test-edit-db-sort-key-maps-ui-column ()
  "A tabulated-list sort key on a UI column maps to its DB column."
  (should (equal (decklet-edit--db-sort-key '("Last Review" . t))
                 '("last_review" . t))))

(ert-deftest decklet-test-edit-entries-render-multiline-inline ()
  "Multi-line words and hints are rendered inline with a ↵ glyph, and a card
with a back shows the back marker."
  (cl-letf (((symbol-function 'decklet-db--select-card-rows)
             (lambda (&rest _)
               '((:card-id 42 :word "line1\nline2" :added "20250101T000000Z"
                           :last-review nil :due "20250102T000000Z"
                           :state "learning" :step nil :stability nil
                           :difficulty nil :hint "hint1\nhint2" :back nil)))))
    (let* ((decklet-edit--filter 'all)
	   (decklet-edit-sidecar-columns
	    (list (list :name "Image" :width 5 :value (lambda (_row) "♣"))))
	   (tabulated-list-sort-key nil)
	   (columns (cadr (car (decklet-edit--entries)))))
      (should (string= (aref columns 0) "line1↵line2"))
      (should (string= (aref columns 1) "hint1↵hint2"))
      (should (string= (aref columns 3) "♣")))))

(ert-deftest decklet-test-edit-tabulated-format-includes-sidecar-columns ()
  "Sidecar columns are inserted after the built-in Back column."
  (let* ((decklet-edit-sidecar-columns
          (list (list :name "Image" :width 5 :value (lambda (_row) nil))))
         (format (decklet-edit--tabulated-list-format)))
    (should (equal "Back" (car (aref format 2))))
    (should (equal "Image" (car (aref format 3))))
    (should (equal "State" (car (aref format 4))))))

;;; Delete

(ert-deftest decklet-test-edit-delete-at-point-when-unmarked ()
  "With no cards marked, delete acts on the card under point only."
  (decklet-test--with-temp-db
   (decklet-test--add-card-meta "alpha")
   (decklet-test--add-card-meta "beta")
   (decklet-edit-test--with-buffer
    (decklet-edit--goto-card-id (decklet-test--card-id "alpha"))
    (decklet-edit-test--confirm #'decklet-edit-delete-card)
    (should-not (decklet-db--select-card-row-by-word "alpha"))
    (should (decklet-db--select-card-row-by-word "beta")))))

(ert-deftest decklet-test-edit-delete-marked-cards-clears-marks ()
  "When cards are marked, delete acts on all of them and clears the marks."
  (decklet-test--with-temp-db
   (dolist (w '("alpha" "beta" "gamma")) (decklet-test--add-card-meta w))
   (decklet-edit-test--with-buffer
    (decklet-edit--goto-card-id (decklet-test--card-id "alpha"))
    (decklet-edit-mark-at-point)
    (decklet-edit--goto-card-id (decklet-test--card-id "beta"))
    (decklet-edit-mark-at-point)
    (decklet-edit-test--confirm #'decklet-edit-delete-card)
    (should-not (decklet-db--select-card-row-by-word "alpha"))
    (should-not (decklet-db--select-card-row-by-word "beta"))
    (should (decklet-db--select-card-row-by-word "gamma"))
    (should (= 0 (hash-table-count decklet-edit--marked))))))

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

(ert-deftest decklet-test-edit-delete-moves-point-to-nearest-survivor ()
  "Deleting the card at point lands point on the nearest surviving row,
preferring the following row on a tie."
  (decklet-test--with-temp-db
   (dolist (w '("alpha" "beta" "gamma")) (decklet-test--add-card-meta w))
   (decklet-edit-test--with-buffer
    ;; Rows sort by word: alpha, beta, gamma.  Delete the middle one.
    (decklet-edit--goto-card-id (decklet-test--card-id "beta"))
    (let ((gamma (decklet-test--card-id "gamma")))
      (decklet-edit-test--confirm #'decklet-edit-delete-card)
      (should (eql (tabulated-list-get-id) gamma))))))

;;; Archive

(ert-deftest decklet-test-edit-archive-then-unarchive-via-filter ()
  "Archive hides a card from the active deck; under the archived filter the
same command unarchives it."
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

(provide 'decklet-edit-test)
;;; decklet-edit-test.el ends here

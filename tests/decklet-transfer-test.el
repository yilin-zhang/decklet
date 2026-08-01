;;; decklet-transfer-test.el --- Tests for decklet-transfer.el -*- lexical-binding: t; -*-

(require 'decklet-test-helpers)

;;; JSON import

(ert-deftest decklet-test-transfer-import-adds-cards ()
  "Import inserts each record, preserves the archived flag, and reads the
optional back field (absent back becomes nil)."
  (decklet-test--with-temp-db
   (let ((stats (decklet-test--import
                 '(((word . "alpha") (added_date . "20250101T010101Z")
                    (last_review . nil) (due . "20250101T010101Z")
                    (archived_at . nil) (state . "learning") (step . 0)
                    (stability . nil) (difficulty . nil) (hint . "first")
                    (back . nil))
                   ((word . "beta") (added_date . "20250102T010101Z")
                    (last_review . "20250102T010101Z") (due . "20250103T010101Z")
                    (archived_at . "20250104T010101Z") (state . "review")
                    (step . 0) (stability . 10.0) (difficulty . 3.0)
                    (hint . "second") (back . "back of beta"))))))
     (should (= 2 (plist-get stats :added)))
     (should (= 0 (plist-get stats :overwritten)))
     (should (= 0 (plist-get stats :skipped))))
   (should (= 1 (length (decklet-db--select-card-rows 'all nil))))
   (should (= 1 (length (decklet-db--select-card-rows 'archived nil))))
   (should (null (decklet-db--select-card-back (decklet-test--card-id "alpha"))))
   (should (string= "back of beta"
                    (decklet-db--select-card-back (decklet-test--card-id "beta"))))))

(ert-deftest decklet-test-transfer-import-conflict-skip-then-overwrite ()
  "On a word conflict, :skip keeps the existing card and :overwrite replaces it."
  (decklet-test--with-temp-db
   (decklet-db--update-hint
    (decklet-test--add-card-meta "alpha" :timestamp "20250101T000000Z"
                                 :due "20250102T000000Z")
    "old")
   (let ((row '((word . "alpha") (added_date . "20250110T000000Z")
                (last_review . "20250110T000000Z") (due . "20250111T000000Z")
                (archived_at . nil) (state . "review") (step . 0)
                (stability . 1.0) (difficulty . 1.0) (hint . "new"))))
     (cl-letf (((symbol-function 'decklet-transfer--import-read-conflict-choice)
                (lambda (_w) (cons :skip nil))))
       (let ((stats (decklet-test--import (list row))))
	 (should (= 0 (plist-get stats :added)))
	 (should (= 1 (plist-get stats :skipped)))))
     (should (string= "old" (plist-get (decklet-db--select-card-row-by-word "alpha") :hint)))
     (cl-letf (((symbol-function 'decklet-transfer--import-read-conflict-choice)
                (lambda (_w) (cons :overwrite nil))))
       (should (= 1 (plist-get (decklet-test--import (list row)) :overwritten))))
     (should (string= "new" (plist-get (decklet-db--select-card-row-by-word "alpha") :hint))))))

(ert-deftest decklet-test-transfer-import-overwrite-hint-back-tristate ()
  "On overwrite, explicit JSON null or blank clears hint/back; an absent field
preserves the existing value."
  (decklet-test--with-temp-db
   (cl-flet ((seed ()
               (let ((id (decklet-test--add-card-meta
                          "alpha" :timestamp "20250101T000000Z"
                          :due "20250102T000000Z")))
                 (decklet-db--update-hint id "old-hint")
                 (decklet-db--update-back id "old-back")))
             (overwrite (extra)
               (cl-letf (((symbol-function 'decklet-transfer--import-read-conflict-choice)
                          (lambda (_w) (cons :overwrite nil))))
		 (decklet-test--import
		  (list (append '((word . "alpha") (added_date . "20250110T000000Z")
				  (last_review . "20250110T000000Z")
				  (due . "20250111T000000Z") (state . "review")
				  (step . 0) (stability . 1.0) (difficulty . 1.0))
                                extra)))))
             (alpha (key) (plist-get (decklet-db--select-card-row-by-word "alpha") key)))
     ;; Explicit JSON null clears.
     (seed) (overwrite '((hint . nil) (back . nil)))
     (should (null (alpha :hint)))
     (should (null (alpha :back)))
     ;; Blank / whitespace-only clears.
     (seed) (overwrite '((hint . "") (back . "   \n\t")))
     (should (null (alpha :hint)))
     (should (null (alpha :back)))
     ;; Absent fields preserve.
     (seed) (overwrite nil)
     (should (string= "old-hint" (alpha :hint)))
     (should (string= "old-back" (alpha :back))))))

(ert-deftest decklet-test-transfer-import-rejects-duplicate-word-in-file ()
  "Two records sharing a word abort the whole import before any write, so no
ghost card-id leaks to `decklet-cards-added-functions'."
  (decklet-test--with-temp-db
   (let* ((rec '((word . "alpha") (added_date . "20250110T000000Z")
                 (last_review . "20250110T000000Z")
                 (due . "20250111T000000Z") (state . "review") (step . 0)
                 (stability . 1.0) (difficulty . 1.0)))
          (added-events nil)
          (decklet-cards-added-functions
           (list (lambda (events) (setq added-events events)))))
     (should-error (decklet-test--import (list rec rec)) :type 'user-error)
     (should (null added-events))
     (should (null (decklet-db--select-card-row-by-word "alpha"))))))

(ert-deftest decklet-test-transfer-import-rejects-invalid-state ()
  "Import rejects an unknown scheduler state before writing any card."
  (decklet-test--with-temp-db
   (should-error (decklet-test--import
                  '(((word . "bad-state") (added_date . "20250101T010101Z")
                     (due . "20250101T010101Z") (state . "bogus"))))
                 :type 'user-error)
   (should-not (decklet-db--select-card-row-by-word "bad-state"))))

(ert-deftest decklet-test-transfer-import-rejects-json-false-values ()
  "JSON false is an invalid field value, not an alias for a missing key."
  (decklet-test--with-temp-db
   (let ((file (expand-file-name "false.json" tmp-dir)))
     (with-temp-file file
       (insert "[{\"word\":\"bad\",\"state\":false}]"))
     (should-error (decklet-db-import-json file) :type 'user-error)
     (should-not (decklet-get-card-id-by-word "bad")))))

(ert-deftest decklet-test-transfer-import-requires-array-root ()
  "An object root is rejected even when it is empty."
  (decklet-test--with-temp-db
   (let ((file (expand-file-name "object.json" tmp-dir)))
     (with-temp-file file (insert "{}"))
     (should-error (decklet-db-import-json file) :type 'user-error))))

(ert-deftest decklet-test-transfer-import-rejects-invalid-scheduler-metadata ()
  "Import rejects malformed timestamps and scheduler numbers before writing."
  (decklet-test--with-temp-db
   (dolist (record '(((word . "bad-date") (due . "tomorrow"))
                     ((word . "bad-step") (step . "one"))
                     ((word . "bad-stability") (stability . -1))
                     ((word . "bad-difficulty") (difficulty . 11))))
     (should-error (decklet-test--import (list record)) :type 'user-error))
   (should (null (decklet-list-words)))))

(ert-deftest decklet-test-transfer-import-rejects-inconsistent-fsrs-metadata ()
  "Import rejects new/review state combinations FSRS cannot schedule safely."
  (decklet-test--with-temp-db
   (dolist (record
            '(((word . "new-as-review") (state . "review"))
              ((word . "new-with-memory") (state . "learning")
               (stability . 1.0) (difficulty . 3.0))
              ((word . "review-without-memory") (state . "review")
               (last_review . "20250101T010101Z"))))
     (should-error (decklet-test--import (list record)) :type 'user-error))
   (should-not (decklet-list-words))))

(ert-deftest decklet-test-transfer-overwrite-notifies-card-change ()
  "Overwriting an imported card emits one refresh event after commit."
  (decklet-test--with-temp-db
   (let* ((card-id (decklet-test--add-card-meta
                    "alpha" :timestamp "20250101T000000Z"
                    :stability 1.0 :difficulty 3.0))
          (events nil)
          (decklet-cards-field-updated-functions
           (list (lambda (received) (setq events received))))
          (record '((word . "alpha") (added_date . "20250110T000000Z")
                    (last_review . "20250110T000000Z")
                    (due . "20250111T000000Z") (state . "review")
                    (step . nil) (stability . 2.0) (difficulty . 4.0))))
     (cl-letf (((symbol-function 'decklet-transfer--import-read-conflict-choice)
                (lambda (_word) (cons :overwrite nil))))
       (decklet-test--import (list record)))
     (should (equal events (list (list :card-id card-id :field 'import)))))))

(ert-deftest decklet-test-transfer-import-new-state-is-schedulable ()
  "An imported `new' state is stored as learning and can be rated."
  (decklet-test--with-temp-db
   (decklet-test--import '(((word . "sprout") (added_date . "20250101T010101Z")
                            (last_review . nil) (due . "20250101T010101Z")
                            (archived_at . nil) (state . "new") (step . 0)
                            (stability . nil) (difficulty . nil))))
   (let ((row (decklet-db--select-card-row-by-word "sprout")))
     (should (equal (plist-get row :state) "learning"))
     (should (decklet-rate-card (plist-get row :card-id) 3)))))

;;; JSON export and round-trip

(ert-deftest decklet-test-transfer-export-writes-all-cards ()
  "Export emits one object per card, ordered by added-date then word, with
content fields populated."
  (decklet-test--with-temp-db
   (let ((file (expand-file-name "export.json" tmp-dir))
         (sun (decklet-test--add-card-meta "sun" :timestamp "20250101T010101Z"
                                           :stability 5.0 :difficulty 3.0)))
     (decklet-db--update-hint sun "star")
     (decklet-db--update-back sun "notes about sun")
     (decklet-test--add-card-meta "moon" :timestamp "20250101T010101Z")
     (decklet-db-export-json file)
     (let* ((data (with-temp-buffer
                    (insert-file-contents file)
                    (json-parse-buffer :object-type 'alist :array-type 'list)))
            (sun-row (cl-find "sun" data :key (lambda (r) (alist-get 'word r))
                              :test #'equal)))
       (should (= 2 (length data)))
       (should (equal (mapcar (lambda (r) (alist-get 'word r)) data) '("moon" "sun")))
       (should (equal (alist-get 'hint sun-row) "star"))
       (should (equal (alist-get 'back sun-row) "notes about sun"))
       (should (equal (alist-get 'state sun-row) "review"))))))

(ert-deftest decklet-test-transfer-export-import-round-trip ()
  "Exporting then importing into an emptied DB preserves content, scheduling,
and archive state."
  (decklet-test--with-temp-db
   (let ((export-file (expand-file-name "round-trip.json" tmp-dir))
         (river (decklet-test--add-card-meta "river" :timestamp "20250101T010101Z"
                                             :stability 8.5 :difficulty 4.2)))
     (decklet-db--update-hint river "flows")
     (decklet-db--update-back river "water body")
     (let ((lake (decklet-test--add-card-meta "lake" :timestamp "20250201T010101Z"
                                              :last-review nil :state :learning :step 0)))
       (decklet-db--update-hint lake "still")
       (decklet-archive-card lake))
     (decklet-db-export-json export-file)
     (sqlite-execute (decklet-db--ensure) "DELETE FROM cards;")
     (should (= 2 (plist-get (decklet-db-import-json export-file) :added)))
     (let ((row (decklet-db--select-card-row-by-word "river")))
       (should (equal (plist-get row :hint) "flows"))
       (should (equal (plist-get row :back) "water body"))
       (should (equal (plist-get row :state) "review"))
       (should (= (plist-get row :stability) 8.5))
       (should (= (plist-get row :difficulty) 4.2)))
     (should (= 1 (length (decklet-db--select-card-rows 'archived nil))))
     (let ((row (decklet-db--select-card-row-by-word "lake")))
       (should (equal (plist-get row :hint) "still"))
       (should (equal (plist-get row :step) 0))))))


(provide 'decklet-transfer-test)
;;; decklet-transfer-test.el ends here

;;; decklet-transfer-test.el --- This file tests decklet-transfer.el. -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

;;; JSON import

(ert-deftest decklet-test-transfer-import-adds-cards ()
  "Import stores each item's content, scheduling and archive state.
An absent back is nil, and a `new' card is stored ready to be rated."
  (decklet-test--with-temp-db
    (let ((stats (decklet-test--import
                  '(((word . "alpha") (added_date . "20250101T010101Z")
                     (last_review . nil) (due . "20250101T010101Z")
                     (archived_at . nil) (state . "new") (step . 0)
                     (stability . nil) (difficulty . nil) (hint . "first")
                     (back . nil))
                    ((word . "beta") (added_date . "20250102T010101Z")
                     (last_review . "20250102T010101Z") (due . "20250103T010101Z")
                     (archived_at . "20250104T010101Z") (state . "review")
                     (step . 0) (stability . 10.0) (difficulty . 3.0)
                     (hint . "second") (tags . ["astro"]) (back . "back of beta"))))))
      (should (equal '(:added 2 :overwritten 0 :skipped 0)
                     (list :added (plist-get stats :added)
                           :overwritten (plist-get stats :overwritten)
                           :skipped (plist-get stats :skipped)))))
    (let ((alpha (decklet-test--card-id "alpha"))
          (beta (decklet-test--card-id "beta")))
      (should (equal (list alpha) (mapcar (lambda (r) (plist-get r :card-id))
                                          (decklet-db--select-card-rows 'all nil))))
      (should (equal (list beta) (mapcar (lambda (r) (plist-get r :card-id))
                                         (decklet-db--select-card-rows 'archived nil))))
      (should (equal "first" (decklet-get-card-hint alpha)))
      (should (null (decklet-get-card-back alpha)))
      (should (equal "back of beta" (decklet-get-card-back beta)))
      (should (equal '("astro") (decklet-get-card-tags beta)))
      (should (= 10.0 (decklet-card-meta-stability (decklet-get-card-meta beta))))
      (should (decklet-rate-card alpha 3)))))

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
  "Overwrite distinguishes absent fields from blank or null values.
Blank and null clear hint/back and `[]' clears tags, while an absent
field preserves the existing value."
  (decklet-test--with-temp-db
    (cl-flet ((seed ()
                (let ((id (decklet-test--add-card-meta
                           "alpha" :timestamp "20250101T000000Z"
                           :due "20250102T000000Z")))
                  (decklet-db--update-hint id "old-hint")
                  (decklet-db--update-back id "old-back")
                  (decklet-set-card-tags id '("old-tag"))))
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
      (seed) (overwrite '((hint . "") (back . "   \n\t") (tags . [])))
      (should (null (alpha :hint)))
      (should (null (alpha :back)))
      (should (null (alpha :tags)))
      ;; Absent fields preserve.
      (seed) (overwrite nil)
      (should (string= "old-hint" (alpha :hint)))
      (should (string= "old-back" (alpha :back)))
      (should (equal '("old-tag") (alpha :tags))))))

(ert-deftest decklet-test-transfer-import-rejects-duplicate-word-in-file ()
  "Duplicate words abort an import before any write.
No ghost card-id leaks to `decklet-cards-added-functions'."
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

(ert-deftest decklet-test-transfer-import-rejects-malformed-files ()
  "A file with any malformed item is rejected before anything is written.
Each case pairs a valid item with one bad root, value, or FSRS state
combination that FSRS could not schedule."
  (decklet-test--with-temp-db
    (let ((file (expand-file-name "bad.json" tmp-dir)))
      (dolist (bad '("{}"
                     "{\"word\":\"bad\",\"state\":false}"
                     "{\"word\":\"bad\",\"state\":\"bogus\"}"
                     "{\"word\":\"bad\",\"due\":\"tomorrow\"}"
                     "{\"word\":\"bad\",\"step\":\"one\"}"
                     "{\"word\":\"bad\",\"stability\":-1}"
                     "{\"word\":\"bad\",\"difficulty\":11}"
                     "{\"word\":\"bad\",\"state\":\"learning\",\"stability\":1.0,\"difficulty\":3.0}"
                     "{\"word\":\"bad\",\"state\":\"review\",\"last_review\":\"20250101T010101Z\"}"
                     "{\"word\":\"bad\",\"tags\":[\"has space\"]}"))
        (with-temp-file file
          (insert (if (equal bad "{}") bad (format "[{\"word\":\"good\"},%s]" bad))))
        (should-error (decklet-db-import-json file) :type 'user-error)
        (should-not (decklet-list-words))))))

(ert-deftest decklet-test-transfer-import-normalizes-timestamps-to-utc ()
  "Import rewrites offset timestamps into the canonical UTC form.
The DB compares timestamps as strings, so a stored offset would make
an overdue card look like it falls due hours later."
  (decklet-test--with-temp-db
    (let ((due (format-time-string "%FT%T+08:00" (time-subtract nil 3600) "UTC-8")))
      (decklet-test--import
       (list `((word . "alpha") (state . "review")
               (last_review . "20250101T000000Z") (due . ,due)
               (stability . 5.0) (difficulty . 5.0))))
      (let ((meta (decklet-get-card-meta (decklet-test--card-id "alpha"))))
        (should (string= "2025-01-01T00:00:00Z" (decklet-card-meta-last-review meta)))
        (should (string-suffix-p "Z" (decklet-card-meta-due meta)))
        (should (= 0 (round (fsrs-timestamp-difference
                             (decklet-card-meta-due meta) due)))))
      (should (equal (list (decklet-test--card-id "alpha"))
                     (decklet-db--select-due-card-ids))))))

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

;;; JSON export

(ert-deftest decklet-test-transfer-export-writes-documented-format ()
  "Export writes one object per card in the documented item format.
Cards are ordered by added date and then word."
  (decklet-test--with-temp-db
    (let ((file (expand-file-name "export.json" tmp-dir))
          (sun (decklet-test--add-card-meta "sun" :timestamp "2025-01-01T01:01:01Z"
                                            :step 0 :stability 5.0 :difficulty 3.0)))
      (decklet-set-card-hint sun "star")
      (decklet-set-card-back sun "notes about sun")
      (decklet-set-card-tags sun '("astro"))
      (decklet-test--add-card-meta "moon" :timestamp "2025-01-01T01:01:01Z")
      (decklet-db-export-json file)
      (let ((data (with-temp-buffer
                    (insert-file-contents file)
                    (json-parse-buffer :object-type 'alist :array-type 'list
                                       :null-object nil))))
        (should (equal '("moon" "sun") (mapcar (lambda (r) (alist-get 'word r)) data)))
        (should (equal (sort (copy-sequence (cadr data))
                             (lambda (a b) (string< (car a) (car b))))
                       '((added_date . "2025-01-01T01:01:01Z")
                         (archived_at)
                         (back . "notes about sun")
                         (difficulty . 3.0)
                         (due . "2025-01-01T01:01:01Z")
                         (hint . "star")
                         (last_review . "2025-01-01T01:01:01Z")
                         (stability . 5.0)
                         (state . "review")
                         (step . 0)
                         (tags "astro")
                         (word . "sun"))))))))

(provide 'decklet-transfer-test)
;;; decklet-transfer-test.el ends here

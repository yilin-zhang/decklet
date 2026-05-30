;;; decklet-db-test.el --- Tests for decklet-db.el -*- lexical-binding: t; -*-

(require 'decklet-test-helpers)

;;; Input normalization

(ert-deftest decklet-test-db-normalize-word ()
  "Word normalization trims, collapses newlines, and rejects blanks."
  (should (string= (decklet-db--normalize-word "  lucid  ") "lucid"))
  (should (string= (decklet-db--normalize-word "  lucid\n\nrain  ") "lucid rain"))
  (should-error (decklet-db--normalize-word "  "))
  (should-error (decklet-db--normalize-word "")))

(ert-deftest decklet-test-db-normalize-optional-text ()
  "Optional text trims and maps blank/nil to nil."
  (should (equal (decklet-db--normalize-optional-text nil) nil))
  (should (equal (decklet-db--normalize-optional-text "  ") nil))
  (should (string= (decklet-db--normalize-optional-text "  foo bar  ") "foo bar")))

;;; Basic round-trip

(ert-deftest decklet-test-db-upsert-then-select ()
  "A card upserted by word can be read back by word."
  (decklet-test--with-temp-db
   (decklet-test--add-card-meta "lucid")
   (let ((row (decklet-db--select-card-row-by-word "lucid")))
     (should row)
     (should (string= (plist-get row :word) "lucid")))))

;;; Connection lifecycle (owner / dependent buffers)

(ert-deftest decklet-test-db-dependent-buffer-keeps-connection-open ()
  "A registered dependent buffer holds the connection open until it is killed."
  (decklet-test--with-temp-db
   (decklet-db--ensure)
   (decklet-test--with-temp-buffers (buf)
				    (with-current-buffer buf
				      (decklet-db-register-dependent-buffer)
				      (should decklet-db--dependent-buffer))
				    (decklet-db--disconnect-if-idle)
				    (should decklet-db--conn)
				    (kill-buffer buf)
				    (should-not decklet-db--conn))))

(ert-deftest decklet-test-db-owner-close-keeps-session-while-another-owner-live ()
  "Killing one owner leaves other owners, attached buffers, and the DB alive."
  (decklet-test--with-temp-db
   (decklet-db--ensure)
   (decklet-test--with-temp-buffers (review edit attached)
				    (with-current-buffer review (decklet-review-mode))
				    (with-current-buffer edit (decklet-edit-mode))
				    (with-current-buffer attached (decklet-card-back-mode 1))
				    (kill-buffer review)
				    (should-not (buffer-live-p review))
				    (should (buffer-live-p edit))
				    (should (buffer-live-p attached))
				    (should decklet-db--conn))))

(ert-deftest decklet-test-db-disconnect-kills-dependents-and-closes-db ()
  "`decklet-disconnect' kills dependents, fires the pre-disconnect hook once,
and closes the connection."
  (decklet-test--with-temp-db
   (decklet-db--ensure)
   (decklet-test--with-temp-buffers (buf-a buf-b)
				    (dolist (buf (list buf-a buf-b))
				      (with-current-buffer buf (decklet-db-register-dependent-buffer)))
				    (let* ((hook-count 0)
					   (decklet-db-pre-disconnect-hook (list (lambda () (cl-incf hook-count)))))
				      (decklet-disconnect)
				      (should-not (buffer-live-p buf-a))
				      (should-not (buffer-live-p buf-b))
				      (should-not decklet-db--conn)
				      (should (= hook-count 1))))))

(ert-deftest decklet-test-db-disconnect-aborts-when-buffer-cancels-kill ()
  "A dependent buffer refusing to die aborts disconnect: connection stays open
and the pre-disconnect hook does not run."
  (decklet-test--with-temp-db
   (decklet-db--ensure)
   (decklet-test--with-temp-buffers (buf)
				    (with-current-buffer buf
				      (decklet-db-register-dependent-buffer)
				      (add-hook 'kill-buffer-query-functions #'ignore nil t))
				    (let* ((hook-count 0)
					   (decklet-db-pre-disconnect-hook (list (lambda () (cl-incf hook-count)))))
				      (should-error (decklet-disconnect) :type 'user-error)
				      (should (buffer-live-p buf))
				      (should decklet-db--conn)
				      (should (= hook-count 0))))))

;;; Archive / unarchive

(ert-deftest decklet-test-db-archive-and-unarchive ()
  "Archiving hides a card from the active set; unarchiving restores it."
  (decklet-test--with-temp-db
   (let ((id (decklet-test--add-card-meta "archive-me")))
     (should (= 1 (length (decklet-db--select-card-rows 'all nil))))
     (decklet-db--archive-card id (decklet-test--ts (current-time)))
     (should (= 0 (length (decklet-db--select-card-rows 'all nil))))
     (should (= 1 (length (decklet-db--select-card-rows 'archived nil))))
     (decklet-db--unarchive-card id)
     (should (= 1 (length (decklet-db--select-card-rows 'all nil)))))))

;;; Due-card selection and counts

(ert-deftest decklet-test-db-select-due-card-ids-honors-review-order ()
  "The due queue follows `decklet-review-order': learning, then new, then review."
  (decklet-test--with-temp-db
   (let* ((decklet-review-order '((:learning . (sort :due :asc))
                                  (:new     . (sort :added :desc))
                                  (:review  . (sort :due :asc))))
          (now (current-time))
          (at (lambda (secs) (decklet-test--ts (time-add now (seconds-to-time secs))))))
     (decklet-db--upsert-card
      "learn-a" (make-decklet-card-meta
                 :added-date (funcall at -7200) :last-review (funcall at -3600)
                 :due (funcall at -600) :state :learning))
     (decklet-db--upsert-card
      "new-a" (make-decklet-card-meta
               :added-date (funcall at 0) :last-review nil
               :due (funcall at 0) :state :learning))
     (decklet-db--upsert-card
      "review-a" (make-decklet-card-meta
                  :added-date (funcall at -7200) :last-review (funcall at -3600)
                  :due (funcall at 1800) :state :review))
     (should (equal (decklet-db--select-due-card-ids)
                    (mapcar #'decklet-test--card-id '("learn-a" "new-a" "review-a")))))))

(ert-deftest decklet-test-db-counts-per-slot ()
  "`decklet-db--counts' tallies reviewed-today, due-review, due-learning, and new."
  (decklet-test--with-temp-db
   (let* ((now (current-time))
          (ts-now (decklet-test--ts now))
          (ts-old "20250101T000000Z")
          (ts-future (decklet-test--ts (time-add now (seconds-to-time 86400)))))
     (decklet-db--upsert-card "reviewed"
                              (make-decklet-card-meta :added-date ts-old :last-review ts-now
                                                      :due ts-future :state :review))
     (decklet-db--upsert-card "due-review"
                              (make-decklet-card-meta :added-date ts-old :last-review ts-old
                                                      :due ts-old :state :review))
     (decklet-db--upsert-card "due-learning"
                              (make-decklet-card-meta :added-date ts-old :last-review ts-old
                                                      :due ts-old :state :learning))
     (decklet-db--upsert-card "new-card"
                              (make-decklet-card-meta :added-date ts-old :due ts-old :state :new))
     (let ((counts (decklet-db--counts)))
       (should (= 1 (plist-get counts :reviewed)))
       (should (= 1 (plist-get counts :due-review)))
       (should (= 1 (plist-get counts :due-learning)))
       (should (= 1 (plist-get counts :new)))))))

(ert-deftest decklet-test-db-due-counts-by-date-splits-overdue-and-range ()
  "`decklet-db-due-counts-by-date' separates overdue cards from in-range ones.
This is the public API the calendar extension relies on."
  (decklet-test--with-temp-db
   (let* ((now (current-time))
          (day-start (decklet-day-start-time now))
          (cutoff (decklet--next-day-start-time now))
          (ts-added (decklet-test--ts (time-subtract now (seconds-to-time 7200))))
          (ts-last (decklet-test--ts (time-subtract now (seconds-to-time 1800)))))
     (decklet-db--upsert-card
      "overdue-card"
      (make-decklet-card-meta
       :added-date ts-added :last-review ts-last
       :due (decklet-test--ts (time-subtract day-start (seconds-to-time 60)))
       :state :review))
     (decklet-db--upsert-card
      "range-card"
      (make-decklet-card-meta
       :added-date ts-added :last-review ts-last
       :due (decklet-test--ts (time-add day-start (seconds-to-time 3600)))
       :state :review))
     (let ((result (decklet-db-due-counts-by-date day-start cutoff)))
       (should (= 1 (plist-get result :overdue)))
       (should (= 1 (apply #'+ (mapcar #'cadr (plist-get result :rows)))))))))

;;; Review-order validation

(ert-deftest decklet-test-db-review-order-rejects-duplicate-target ()
  "A target used in more than one order step is rejected."
  (should-error
   (decklet-db--review-validate-order
    '((:review . shuffle) (:review . (sort :due :asc))))))

(ert-deftest decklet-test-db-review-order-rejects-invalid-learning-sort-field ()
  "Learning cards may only be sorted by :due or :added."
  (should-error
   (decklet-db--review-validate-order
    '((:learning . (sort :stability :desc))))))

;;; JSON import

(ert-deftest decklet-test-db-import-adds-cards ()
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

(ert-deftest decklet-test-db-import-conflict-skip-then-overwrite ()
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
     (cl-letf (((symbol-function 'decklet-db--import-read-conflict-choice)
                (lambda (_w) (cons :skip nil))))
       (let ((stats (decklet-test--import (list row))))
	 (should (= 0 (plist-get stats :added)))
	 (should (= 1 (plist-get stats :skipped)))))
     (should (string= "old" (plist-get (decklet-db--select-card-row-by-word "alpha") :hint)))
     (cl-letf (((symbol-function 'decklet-db--import-read-conflict-choice)
                (lambda (_w) (cons :overwrite nil))))
       (should (= 1 (plist-get (decklet-test--import (list row)) :overwritten))))
     (should (string= "new" (plist-get (decklet-db--select-card-row-by-word "alpha") :hint))))))

(ert-deftest decklet-test-db-import-overwrite-hint-back-tristate ()
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
               (cl-letf (((symbol-function 'decklet-db--import-read-conflict-choice)
                          (lambda (_w) (cons :overwrite nil))))
		 (decklet-test--import
		  (list (append '((word . "alpha") (added_date . "20250110T000000Z")
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

(ert-deftest decklet-test-db-import-rejects-duplicate-word-in-file ()
  "Two records sharing a word abort the whole import before any write, so no
ghost card-id leaks to `decklet-cards-added-functions'."
  (decklet-test--with-temp-db
   (let* ((rec '((word . "alpha") (added_date . "20250110T000000Z")
                 (due . "20250111T000000Z") (state . "review") (step . 0)
                 (stability . 1.0) (difficulty . 1.0)))
          (added-events nil)
          (decklet-cards-added-functions
           (list (lambda (events) (setq added-events events)))))
     (should-error (decklet-test--import (list rec rec)) :type 'user-error)
     (should (null added-events))
     (should (null (decklet-db--select-card-row-by-word "alpha"))))))

(ert-deftest decklet-test-db-import-rejects-invalid-state ()
  "Import rejects an unknown scheduler state before writing any card."
  (decklet-test--with-temp-db
   (should-error (decklet-test--import
                  '(((word . "bad-state") (added_date . "20250101T010101Z")
                     (due . "20250101T010101Z") (state . "bogus"))))
                 :type 'user-error)
   (should-not (decklet-db--select-card-row-by-word "bad-state"))))

(ert-deftest decklet-test-db-import-new-state-is-schedulable ()
  "An imported `new' state is stored as learning and can be rated."
  (decklet-test--with-temp-db
   (decklet-test--import '(((word . "sprout") (added_date . "20250101T010101Z")
                            (last_review . nil) (due . "20250101T010101Z")
                            (archived_at . nil) (state . "new") (step . 0)
                            (stability . nil) (difficulty . nil))))
   (let ((row (decklet-db--select-card-row-by-word "sprout")))
     (should (equal (plist-get row :state) "learning"))
     (should (decklet-rate-card (plist-get row :card-id) 3)))))

(ert-deftest decklet-test-db-import-record-step-default-by-state ()
  "A missing step defaults to nil for review cards and 0 for learning-like ones."
  (let ((review (plist-get (decklet-db--import-record->card
                            '((word . "review-word") (state . "review")))
                           :meta))
        (learning (plist-get (decklet-db--import-record->card
                              '((word . "learning-word") (state . "learning")))
                             :meta)))
    (should (null (decklet-card-meta-step review)))
    (should (= 0 (decklet-card-meta-step learning)))))

(ert-deftest decklet-test-db-import-conflict-choice-overwrite-all ()
  "Choosing overwrite-all returns the current action and persists the global
choice; cancelling the global prompt re-asks and resolves only the current word."
  (cl-letf (((symbol-function 'read-char-choice) (lambda (_p _c) ?A))
            ((symbol-function 'yes-or-no-p) (lambda (_p) t)))
    (should (equal (decklet-db--import-read-conflict-choice "alpha")
		   '(:overwrite . :overwrite))))
  (let ((calls 0))
    (cl-letf (((symbol-function 'read-char-choice)
               (lambda (_p _c) (cl-incf calls) (if (= calls 1) ?a ?o)))
              ((symbol-function 'yes-or-no-p) (lambda (_p) nil)))
      (should (equal (decklet-db--import-read-conflict-choice "beta")
		     '(:overwrite . nil))))))

;;; JSON export and round-trip

(ert-deftest decklet-test-db-export-writes-all-cards ()
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

(ert-deftest decklet-test-db-export-import-round-trip ()
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

;;; Card back — DB layer

(ert-deftest decklet-test-db-card-back-update-select-and-isolation ()
  "Card back round-trips through update/select, blank normalizes to nil, and a
scheduling upsert never touches the back field."
  (decklet-test--with-temp-db
   (let ((id (decklet-test--add-card-meta "lucid" :state :new
                                          :timestamp "20250101T000000Z")))
     (should (null (decklet-db--select-card-back id)))
     (decklet-db--update-back id "clear and bright")
     (should (string= "clear and bright" (decklet-db--select-card-back id)))
     (decklet-db--update-back id "   ")
     (should (null (decklet-db--select-card-back id)))
     (decklet-db--update-back id "example sentence")
     (decklet-db--upsert-card "lucid"
                              (decklet-test--make-card-meta :timestamp "20250102T000000Z"))
     (should (string= "example sentence" (decklet-db--select-card-back id))))))

;;; Filename timestamp helper

(ert-deftest decklet-test-db-timestamp-utc-format ()
  "The UTC filename timestamp matches the compact YYYYMMDDTHHMMSSZ form."
  (should (string-match-p "\\`[0-9]\\{8\\}T[0-9]\\{6\\}Z\\'"
                          (decklet-db--timestamp-utc))))

(provide 'decklet-db-test)
;;; decklet-db-test.el ends here

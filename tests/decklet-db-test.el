;;; decklet-db-test.el --- Tests for decklet-db.el -*- lexical-binding: t; -*-

(require 'decklet-test-helpers)

;; ---------------------------------------------------------------------------
;; Normalization helpers
;; ---------------------------------------------------------------------------
;; These tests protect input sanitation rules.  Empty/blank words must fail,
;; while hint normalization should map blank strings to nil.

(ert-deftest decklet-test-normalize-word ()
  (should (string= (decklet-db--normalize-word "  lucid  ") "lucid"))
  (should (string= (decklet-db--normalize-word "  lucid\n\nrain  ") "lucid rain"))
  (should-error (decklet-db--normalize-word "  "))
  (should-error (decklet-db--normalize-word "")))

(ert-deftest decklet-test-normalize-optional-text ()
  (should (equal (decklet-db--normalize-optional-text nil) nil))
  (should (equal (decklet-db--normalize-optional-text "  ") nil))
  (should (string= (decklet-db--normalize-optional-text "  foo bar  ") "foo bar")))

;; ---------------------------------------------------------------------------
;; Basic DB lifecycle
;; ---------------------------------------------------------------------------
;; Verifies that DB initialization + upsert + select round-trip works for the
;; minimal card payload.

(ert-deftest decklet-test-db-ensure-and-upsert-select ()
  (decklet-test--with-temp-db
   (decklet-db--ensure)
   (decklet-db--upsert-card "lucid" (decklet-test--make-card-meta))
   (let ((row (decklet-db--select-card-row-by-word "lucid")))
     (should row)
     (should (string= (plist-get row :word) "lucid")))))

;; ---------------------------------------------------------------------------
;; Archive/unarchive flow
;; ---------------------------------------------------------------------------
;; Ensures archive filters behave correctly and that unarchive returns the card
;; to normal (non-archived) selection results.

(ert-deftest decklet-test-archive-filter-flow ()
  (decklet-test--with-temp-db
   (let ((ts (decklet-test--ts (current-time))))
     (decklet-db--upsert-card "archive-me"
                              (decklet-test--make-card-meta :timestamp ts))
     (let ((card-id (plist-get (decklet-db--select-card-row-by-word "archive-me") :card-id)))
       (should (= 1 (length (decklet-db--select-card-rows 'all nil))))
       (decklet-db--archive-card card-id ts)
       (should (= 0 (length (decklet-db--select-card-rows 'all nil))))
       (should (= 1 (length (decklet-db--select-card-rows 'archived nil))))
       (decklet-db--unarchive-card card-id)
       (should (= 1 (length (decklet-db--select-card-rows 'all nil))))))))

;; ---------------------------------------------------------------------------
;; Due-word selection with review-order
;; ---------------------------------------------------------------------------
;; Exercises the DB-level queue assembly:
;; - learning due "now" by exact timestamp,
;; - new/review due by review-day cutoff,
;; - final sequence respects configured review-order steps.

(ert-deftest decklet-test-select-due-card-ids-review-order ()
  ;; Bind a specific order to test that the queue sequence matches config,
  ;; independent of whatever the production default happens to be.
  (decklet-test--with-temp-db
   (let* ((decklet-review-order '((:learning . (sort :due :asc))
                                  (:new     . (sort :added :desc))
                                  (:review  . (sort :due :asc))))
          (now (current-time))
          (past-2h (time-subtract now (seconds-to-time (* 2 3600))))
          (past-1h (time-subtract now (seconds-to-time 3600)))
          (past-10m (time-subtract now (seconds-to-time 600)))
          (future-30m (time-add now (seconds-to-time 1800))))
     ;; Learning due now.
     (decklet-db--upsert-card
      "learn-a"
      (make-decklet-card-meta
       :added-date (decklet-test--ts past-2h)
       :last-review (decklet-test--ts past-1h)
       :due (decklet-test--ts past-10m)
       :state :learning))
     ;; New card (last_review nil), due by today's review cutoff.
     (decklet-db--upsert-card
      "new-a"
      (make-decklet-card-meta
       :added-date (decklet-test--ts now)
       :last-review nil
       :due (decklet-test--ts now)
       :state :learning))
     ;; Review card due later today (still included in review target).
     (decklet-db--upsert-card
      "review-a"
      (make-decklet-card-meta
       :added-date (decklet-test--ts past-2h)
       :last-review (decklet-test--ts past-1h)
       :due (decklet-test--ts future-30m)
       :state :review))

     (should (equal (decklet-db--select-due-card-ids)
                    (mapcar (lambda (word)
                              (plist-get (decklet-db--select-card-row-by-word word) :card-id))
                            '("learn-a" "new-a" "review-a")))))))

;; ---------------------------------------------------------------------------
;; Review-order validation
;; ---------------------------------------------------------------------------
;; These tests guard schema rules for `decklet-review-order`.
;; Duplicate targets should fail early, and learning/new sort fields are
;; intentionally restricted.

(ert-deftest decklet-test-review-order-validate-rejects-duplicates ()
  (should-error
   (decklet-db--review-validate-order
    '((:review . shuffle)
      (:review . (sort :due :asc))))))

(ert-deftest decklet-test-review-order-validate-rejects-invalid-learning-sort-field ()
  (should-error
   (decklet-db--review-validate-order
    '((:learning . (sort :stability :desc))))))

;; ---------------------------------------------------------------------------
;; Review target clause generation
;; ---------------------------------------------------------------------------
;; Validates that each target kind maps to expected WHERE conditions and
;; generates exactly one cutoff parameter.

(ert-deftest decklet-test-review-target-clause-shapes ()
  (let* ((now (current-time))
         (learning (decklet-db--review-target-clause :learning now))
         (relearning (decklet-db--review-target-clause :relearning now))
         (review (decklet-db--review-target-clause :review now))
         (new (decklet-db--review-target-clause :new now)))
    (should (string-match-p "state = \\?" (car learning)))
    (should (string-match-p "state = \\?" (car relearning)))
    (should (string-match-p "state = \\?" (car review)))
    (should (string-match-p "last_review IS NULL" (car new)))
    (should (= 2 (length (cdr learning))))
    (should (= 2 (length (cdr relearning))))
    (should (= 2 (length (cdr review))))
    (should (= 1 (length (cdr new))))))

;; ---------------------------------------------------------------------------
;; Edit filter SQL mapping
;; ---------------------------------------------------------------------------
;; Keeps tabulated-list filter commands stable by asserting exact SQL snippets.

(ert-deftest decklet-test-edit-filter-sql-clauses ()
  (pcase-let ((`(,review-sql . ,review-params) (decklet-db--edit-filter-sql 'review))
              (`(,learning-sql . ,learning-params) (decklet-db--edit-filter-sql 'learning))
              (`(,archived-sql . ,archived-params) (decklet-db--edit-filter-sql 'archived))
              (`(,all-sql . ,all-params) (decklet-db--edit-filter-sql 'all)))
    ;; Keep checks resilient to SQL formatting changes while asserting semantics.
    (should (string-match-p "archived_at IS NULL" review-sql))
    (should (string-match-p "state = \\?" review-sql))
    (should (equal review-params '("review")))

    (should (string-match-p "archived_at IS NULL" learning-sql))
    (should (string-match-p "state IN (\\?, \\?)" learning-sql))
    (should (equal learning-params '("learning" "relearning")))

    (should (string-match-p "archived_at IS NOT NULL" archived-sql))
    (should (equal archived-params nil))

    (should (string-match-p "archived_at IS NULL" all-sql))
    (should (equal all-params nil))))

;; ---------------------------------------------------------------------------
;; Edit sorting SQL generation
;; ---------------------------------------------------------------------------
;; Critical for table behavior: numeric columns use numeric coalesce (0),
;; while text/time columns use string coalesce ('').

(ert-deftest decklet-test-edit-order-sql-numeric-vs-text-columns ()
  ;; Assert only the numeric-vs-text COALESCE choice; the rowid
  ;; tie-breaker is orthogonal to this test's contract.
  (should (string-match-p
           "COALESCE(stability, 0) DESC"
           (decklet-db--edit-order-sql '("stability" . t))))
  (should (string-match-p
           "COALESCE(due, '') ASC"
           (decklet-db--edit-order-sql '("due" . nil)))))

;; ---------------------------------------------------------------------------
;; JSON import
;; ---------------------------------------------------------------------------
;; Covers:
;; - importing exported-format JSON rows,
;; - archived flag preservation,
;; - duplicate conflict handling (skip/overwrite + global choice).

(ert-deftest decklet-test-db-import-json-adds-and-preserves-archive ()
  (decklet-test--with-temp-db
   (let* ((file (expand-file-name "import.json" tmp-dir))
          (rows '(((word . "alpha")
                   (added_date . "20250101T010101Z")
                   (last_review . nil)
                   (due . "20250101T010101Z")
                   (archived_at . nil)
                   (state . "learning")
                   (step . 0)
                   (stability . nil)
                   (difficulty . nil)
                   (hint . "first"))
                  ((word . "beta")
                   (added_date . "20250102T010101Z")
                   (last_review . "20250102T010101Z")
                   (due . "20250103T010101Z")
                   (archived_at . "20250104T010101Z")
                   (state . "review")
                   (step . 0)
                   (stability . 10.0)
                   (difficulty . 3.0)
                   (hint . "second"))))
          (json-encoding-pretty-print t))
     (with-temp-file file
       (insert (json-encode rows)))
     (let ((stats (decklet-db-import-json file)))
       (should (= 2 (plist-get stats :added)))
       (should (= 0 (plist-get stats :overwritten)))
       (should (= 0 (plist-get stats :skipped))))
     (should (= 1 (length (decklet-db--select-card-rows 'all nil))))
     (should (= 1 (length (decklet-db--select-card-rows 'archived nil)))))))

(ert-deftest decklet-test-db-import-json-conflict-skip-and-overwrite ()
  (decklet-test--with-temp-db
   (let* ((file (expand-file-name "import-conflict.json" tmp-dir))
          (base-meta (decklet-test--make-card-meta
                      :timestamp "20250101T000000Z"
                      :due "20250102T000000Z"))
          (rows '(((word . "alpha")
                   (added_date . "20250110T000000Z")
                   (last_review . "20250110T000000Z")
                   (due . "20250111T000000Z")
                   (archived_at . nil)
                   (state . "review")
                   (step . 0)
                   (stability . 1.0)
                   (difficulty . 1.0)
                   (hint . "new"))))
          (json-encoding-pretty-print t))
     (decklet-db--upsert-card "alpha" base-meta)
     (decklet-db--update-hint
      (plist-get (decklet-db--select-card-row-by-word "alpha") :card-id) "old")
     (with-temp-file file
       (insert (json-encode rows)))
     ;; Conflict => skip
     (cl-letf (((symbol-function 'decklet-db--import-read-conflict-choice)
                (lambda (_word) (cons :skip nil))))
       (let ((stats (decklet-db-import-json file)))
         (should (= 0 (plist-get stats :added)))
         (should (= 0 (plist-get stats :overwritten)))
         (should (= 1 (plist-get stats :skipped)))))
     (should (string= "old" (plist-get (decklet-db--select-card-row-by-word "alpha") :hint)))
     ;; Conflict => overwrite
     (cl-letf (((symbol-function 'decklet-db--import-read-conflict-choice)
                (lambda (_word) (cons :overwrite nil))))
       (let ((stats (decklet-db-import-json file)))
         (should (= 0 (plist-get stats :added)))
         (should (= 1 (plist-get stats :overwritten)))
         (should (= 0 (plist-get stats :skipped)))))
     (should (string= "new" (plist-get (decklet-db--select-card-row-by-word "alpha") :hint))))))

(ert-deftest decklet-test-db-import-read-conflict-choice-global-confirm ()
  ;; Choosing all-overwrite and confirming should return current overwrite action
  ;; and persist global overwrite for remaining conflicts.
  (cl-letf (((symbol-function 'read-char-choice)
             (lambda (_prompt _chars) ?A))
            ((symbol-function 'yes-or-no-p)
             (lambda (_prompt) t)))
    (should (equal (decklet-db--import-read-conflict-choice "alpha")
                   '(:overwrite . :overwrite))))
  ;; If user cancels a global choice, function should ask again and still
  ;; resolve the current word action.
  (let ((calls 0))
    (cl-letf (((symbol-function 'read-char-choice)
               (lambda (_prompt _chars)
                 (setq calls (1+ calls))
                 (if (= calls 1) ?a ?o)))
              ((symbol-function 'yes-or-no-p)
               (lambda (_prompt) nil)))
      (should (equal (decklet-db--import-read-conflict-choice "beta")
                     '(:overwrite . nil))))))

(ert-deftest decklet-test-db-import-record-step-default-by-state ()
  ;; Missing step defaults to nil for review, 0 for learning-like states.
  (let ((review-meta (plist-get
                      (decklet-db--import-record->card
                       '((word . "review-word")
                         (state . "review")))
                      :meta))
        (learning-meta (plist-get
                        (decklet-db--import-record->card
                         '((word . "learning-word")
                           (state . "learning")))
                        :meta)))
    (should (null (decklet-card-meta-step review-meta)))
    (should (= 0 (decklet-card-meta-step learning-meta)))))

;; ---------------------------------------------------------------------------
;; Timestamp helper
;; ---------------------------------------------------------------------------
;; Ensure exported UTC timestamp helper always matches the filename-friendly
;; compact format used by backups and JSON exports.

(ert-deftest decklet-test-db-timestamp-utc-format ()
  (should (string-match-p
           "\\`[0-9]\\{8\\}T[0-9]\\{6\\}Z\\'"
           (decklet-db--timestamp-utc))))

;; ---------------------------------------------------------------------------
;; Counter query (decklet-db--counts)
;; ---------------------------------------------------------------------------
;; Verifies that the single aggregated query returns correct counts for each
;; slot: reviewed today, due review, due learning, and new cards.

(ert-deftest decklet-test-db-counts-correct-per-slot ()
  (decklet-test--with-temp-db
   (let* ((now (current-time))
          (ts-now (decklet-test--ts now))
          ;; Use a fixed old timestamp clearly outside today's review window.
          (ts-old "20250101T000000Z")
          (ts-future (decklet-test--ts (time-add now (seconds-to-time 86400)))))
     ;; Reviewed card: last_review within today's window, due in future.
     (decklet-db--upsert-card "reviewed"
                              (make-decklet-card-meta
                               :added-date ts-old :last-review ts-now
                               :due ts-future :state :review))
     ;; Due review card: state=review, last_review in the past, due in the past.
     (decklet-db--upsert-card "due-review"
                              (make-decklet-card-meta
                               :added-date ts-old :last-review ts-old
                               :due ts-old :state :review))
     ;; Due learning card: state=learning, last_review in the past, due in the past.
     (decklet-db--upsert-card "due-learning"
                              (make-decklet-card-meta
                               :added-date ts-old :last-review ts-old
                               :due ts-old :state :learning))
     ;; New card: no last_review.
     (decklet-db--upsert-card "new-card"
                              (make-decklet-card-meta
                               :added-date ts-old :due ts-old :state :new))
     (let ((counts (decklet-db--counts)))
       (should (= 1 (plist-get counts :reviewed)))
       (should (= 1 (plist-get counts :due-review)))
       (should (= 1 (plist-get counts :due-learning)))
       (should (= 1 (plist-get counts :new)))))))

;; ---------------------------------------------------------------------------
;; Card back — DB layer
;; ---------------------------------------------------------------------------
;; Covers back field updates and that
;; upsert-card never touches the back field (content/scheduling separation).

(ert-deftest decklet-test-card-back-update-and-select ()
  "update-back stores content and select-card-back retrieves it."
  (decklet-test--with-temp-db
   (let ((meta (make-decklet-card-meta
                :added-date "20250101T000000Z"
                :due "20250101T000000Z"
                :state :new)))
     (decklet-db--upsert-card "lucid" meta)
     (let ((card-id (plist-get (decklet-db--select-card-row-by-word "lucid") :card-id)))
       (should (null (decklet-db--select-card-back card-id)))
       (decklet-db--update-back card-id "clear and bright")
       (should (string= "clear and bright"
                        (decklet-db--select-card-back card-id)))))))

(ert-deftest decklet-test-card-back-select-nil-when-absent ()
  "select-card-back returns nil for a card with no back."
  (decklet-test--with-temp-db
   (decklet-db--upsert-card "fog"
                            (make-decklet-card-meta
                             :added-date "20250101T000000Z"
                             :due "20250101T000000Z"
                             :state :new))
   (should (null (decklet-db--select-card-back
                  (plist-get (decklet-db--select-card-row-by-word "fog") :card-id))))))

(ert-deftest decklet-test-card-back-blank-normalizes-to-nil ()
  "Storing a blank back normalizes it to nil."
  (decklet-test--with-temp-db
   (decklet-db--upsert-card "mist"
                            (make-decklet-card-meta
                             :added-date "20250101T000000Z"
                             :due "20250101T000000Z"
                             :state :new))
   (let ((card-id (plist-get (decklet-db--select-card-row-by-word "mist") :card-id)))
     (decklet-db--update-back card-id "   ")
     (should (null (decklet-db--select-card-back card-id))))))

(ert-deftest decklet-test-card-back-upsert-does-not-touch-back ()
  "upsert-card leaves back untouched; back must be set via update-back."
  (decklet-test--with-temp-db
   (let ((meta (make-decklet-card-meta
                :added-date "20250101T000000Z"
                :due "20250101T000000Z"
                :state :new)))
     (decklet-db--upsert-card "vivid" meta)
     ;; Back is nil after initial upsert.
     (let ((card-id (plist-get (decklet-db--select-card-row-by-word "vivid") :card-id)))
       (should (null (decklet-db--select-card-back card-id)))
       ;; Set back directly.
       (decklet-db--update-back card-id "example sentence")
       ;; Scheduling update does not clear it.
       (decklet-db--upsert-card
        "vivid"
        (make-decklet-card-meta
         :added-date "20250101T000000Z"
         :last-review "20250102T000000Z"
         :due "20250110T000000Z"
         :state :review))
       (should (string= "example sentence"
                        (decklet-db--select-card-back card-id)))))))

;; ---------------------------------------------------------------------------
;; Card back — JSON import/export
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-card-back-json-import-reads-back-field ()
  "JSON import populates the `back' field from the record."
  (decklet-test--with-temp-db
   (let* ((file (expand-file-name "import-back.json" tmp-dir))
          (rows '(((word . "crisp")
                   (added_date . "20250101T010101Z")
                   (last_review . nil)
                   (due . "20250101T010101Z")
                   (archived_at . nil)
                   (state . "new")
                   (step . 0)
                   (stability . nil)
                   (difficulty . nil)
                   (hint . nil)
                   (back . "fresh and clear"))))
          (json-encoding-pretty-print t))
     (with-temp-file file
       (insert (json-encode rows)))
     (decklet-db-import-json file)
     (should (string= "fresh and clear"
                      (decklet-db--select-card-back
                       (plist-get (decklet-db--select-card-row-by-word "crisp") :card-id)))))))

(ert-deftest decklet-test-card-back-json-import-nil-back ()
  "JSON import with null back leaves back as nil."
  (decklet-test--with-temp-db
   (let* ((file (expand-file-name "import-no-back.json" tmp-dir))
          (rows '(((word . "dim")
                   (added_date . "20250101T010101Z")
                   (last_review . nil)
                   (due . "20250101T010101Z")
                   (archived_at . nil)
                   (state . "new")
                   (step . 0)
                   (stability . nil)
                   (difficulty . nil)
                   (hint . nil)
                   (back . nil))))
          (json-encoding-pretty-print t))
     (with-temp-file file
       (insert (json-encode rows)))
     (decklet-db-import-json file)
     (should (null (decklet-db--select-card-back
                    (plist-get (decklet-db--select-card-row-by-word "dim") :card-id)))))))

;; ---------------------------------------------------------------------------
;; JSON export
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-db-export-json-writes-all-cards ()
  "Export produces a JSON array with one object per card."
  (decklet-test--with-temp-db
   (let* ((file (expand-file-name "export.json" tmp-dir))
          (meta (decklet-test--make-card-meta
                 :timestamp "20250101T010101Z"
                 :stability 5.0 :difficulty 3.0)))
     (decklet-db--upsert-card "sun" meta)
     (let ((sun-id (plist-get (decklet-db--select-card-row-by-word "sun") :card-id)))
       (decklet-db--update-hint sun-id "star")
       (decklet-db--update-back sun-id "notes about sun"))
     (decklet-db--upsert-card "moon" meta)
     (decklet-db-export-json file)
     (let* ((data (with-temp-buffer
                    (insert-file-contents file)
                    (json-parse-buffer :object-type 'alist
                                       :array-type 'list)))
            (words (mapcar (lambda (r) (alist-get 'word r)) data)))
       (should (= 2 (length data)))
       ;; Cards are ordered by added_date ASC, word ASC.
       (should (equal words '("moon" "sun")))
       ;; Verify fields on a card with all content populated.
       (let ((sun (cl-find "sun" data :key (lambda (r) (alist-get 'word r)) :test #'equal)))
         (should (equal (alist-get 'hint sun) "star"))
         (should (equal (alist-get 'back sun) "notes about sun"))
         (should (equal (alist-get 'state sun) "review")))))))

;; ---------------------------------------------------------------------------
;; JSON round-trip (export → import)
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-db-export-import-round-trip ()
  "Exporting then importing into a fresh DB preserves card data."
  (decklet-test--with-temp-db
   (let* ((export-file (expand-file-name "round-trip.json" tmp-dir))
          (meta1 (decklet-test--make-card-meta
                  :timestamp "20250101T010101Z"
                  :stability 8.5 :difficulty 4.2))
          (meta2 (decklet-test--make-card-meta
                  :timestamp "20250201T010101Z"
                  :last-review nil :state :learning :step 0)))
     ;; Populate source DB.
     (decklet-db--upsert-card "river" meta1)
     (let ((river-id (plist-get (decklet-db--select-card-row-by-word "river") :card-id)))
       (decklet-db--update-hint river-id "flows")
       (decklet-db--update-back river-id "water body"))
     (decklet-db--upsert-card "lake" meta2)
     (decklet-db--update-hint
      (plist-get (decklet-db--select-card-row-by-word "lake") :card-id) "still")
     (decklet-archive-card (plist-get (decklet-db--select-card-row-by-word "lake") :card-id))
     ;; Export.
     (decklet-db-export-json export-file)
     ;; Clear all cards to simulate a fresh DB.
     (sqlite-execute (decklet-db--ensure) "DELETE FROM cards;")
     ;; Import into the empty DB.
     (let ((stats (decklet-db-import-json export-file)))
       (should (= 2 (plist-get stats :added))))
     ;; Verify river (active, reviewed card with back and scheduling data).
     (let ((row (decklet-db--select-card-row-by-word "river")))
       (should row)
       (should (equal (plist-get row :hint) "flows"))
       (should (equal (plist-get row :back) "water body"))
       (should (equal (plist-get row :state) "review"))
       (should (= (plist-get row :stability) 8.5))
       (should (= (plist-get row :difficulty) 4.2)))
     ;; Verify lake (archived, new card without scheduling data).
     (should (= 1 (length (decklet-db--select-card-rows 'archived nil))))
     (let ((row (decklet-db--select-card-row-by-word "lake")))
       (should row)
       (should (equal (plist-get row :hint) "still"))
       (should (equal (plist-get row :step) 0))))))

;; ---------------------------------------------------------------------------
;; Due-count aggregation
;; ---------------------------------------------------------------------------
;; Verify that overdue and in-range due counts are split correctly for
;; `decklet-db-due-counts-by-date' — the public API that extensions
;; (e.g. decklet-calendar) rely on.

(ert-deftest decklet-test-db-due-counts-by-date-splits-overdue-and-range ()
  (decklet-test--with-temp-db
   (let* ((now (current-time))
          (day-start (decklet-day-start-time now))
          (cutoff (decklet--next-day-start-time now))
          (overdue-time (time-subtract day-start (seconds-to-time 60)))
          (in-range-time (time-add day-start (seconds-to-time 3600)))
          (ts-added (decklet-test--ts (time-subtract now (seconds-to-time 7200))))
          (ts-last (decklet-test--ts (time-subtract now (seconds-to-time 1800)))))
     (decklet-db--upsert-card
      "overdue-card"
      (make-decklet-card-meta
       :added-date ts-added
       :last-review ts-last
       :due (decklet-test--ts overdue-time)
       :state :review))
     (decklet-db--upsert-card
      "range-card"
      (make-decklet-card-meta
       :added-date ts-added
       :last-review ts-last
       :due (decklet-test--ts in-range-time)
       :state :review))
     (let* ((result (decklet-db-due-counts-by-date day-start cutoff))
            (rows (plist-get result :rows))
            (overdue (plist-get result :overdue))
            (in-range-count (apply #'+ (mapcar #'cadr rows))))
       (should (= overdue 1))
       (should (= in-range-count 1))))))

(provide 'decklet-db-test)
;;; decklet-db-test.el ends here

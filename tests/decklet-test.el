;;; decklet-test.el --- Tests for Decklet -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'decklet)

(defmacro decklet-test--with-temp-db (&rest body)
  "Run BODY with an isolated temporary Decklet database."
  (declare (indent 0) (debug t))
  `(let* ((tmp-dir (make-temp-file "decklet-test-" t))
          (decklet-directory (file-name-as-directory tmp-dir))
          (decklet-db-file (expand-file-name "decklet.sqlite" tmp-dir))
          (decklet-backup-directory (expand-file-name "backups" tmp-dir))
          (decklet-db--conn nil)
          (decklet--fsrs-scheduler nil)
          (decklet-review-order '((:sort :due :asc :learning)
                                    (:sort :added :desc :new)
                                    (:sort :due :asc :review))))
     (unwind-protect
         (progn
           ,@body)
       (when (and (boundp 'decklet-db--conn) decklet-db--conn)
         (sqlite-close decklet-db--conn)
         (setq decklet-db--conn nil))
       (delete-directory tmp-dir t))))

(defun decklet-test--ts (time)
  "Convert TIME to Decklet timestamp string."
  (decklet--time->fsrs-timestamp time))

(defun decklet-test--make-meta (&rest plist)
  "Create a card meta object from PLIST."
  (apply #'make-decklet-card-meta plist))

;; ---------------------------------------------------------------------------
;; Normalization helpers
;; ---------------------------------------------------------------------------
;; These tests protect input sanitation rules.  Empty/blank words must fail,
;; while hint normalization should map blank strings to nil.

(ert-deftest decklet-test-normalize-word ()
  (should (string= (decklet-db--normalize-word "  lucid  ") "lucid"))
  (should-error (decklet-db--normalize-word "  "))
  (should-error (decklet-db--normalize-word "")))

(ert-deftest decklet-test-normalize-hint ()
  (should (equal (decklet-db--normalize-hint nil) nil))
  (should (equal (decklet-db--normalize-hint "  ") nil))
  (should (string= (decklet-db--normalize-hint "  foo bar  ") "foo bar")))

(ert-deftest decklet-test-card-display-state-derivation ()
  (should (eq (decklet-card-display-state :learning nil) :new))
  (should (eq (decklet-card-display-state :learning "") :new))
  (should (eq (decklet-card-display-state :learning "2025-01-01T00:00:00Z") :learning))
  (should (eq (decklet-card-display-state :relearning "2025-01-01T00:00:00Z") :relearning))
  (should (eq (decklet-card-display-state :review "2025-01-01T00:00:00Z") :review))
  (should (eq (decklet-card-display-state :unknown "2025-01-01T00:00:00Z") :review)))

(ert-deftest decklet-test-card-meta-display-state-derivation ()
  (should
   (eq (decklet-card-meta-display-state
        (decklet-test--make-meta :state :learning :last-review nil))
       :new))
  (should
   (eq (decklet-card-meta-display-state
        (decklet-test--make-meta :state :learning
                                 :last-review "2025-01-01T00:00:00Z"))
       :learning)))

;; ---------------------------------------------------------------------------
;; Basic DB lifecycle
;; ---------------------------------------------------------------------------
;; Verifies that DB initialization + upsert + select round-trip works for the
;; minimal card payload.

(ert-deftest decklet-test-db-ensure-and-upsert-select ()
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (let* ((now (current-time))
           (meta (decklet-test--make-meta
                  :added-date (decklet-test--ts now)
                  :last-review (decklet-test--ts now)
                  :due (decklet-test--ts now)
                  :state :review
                  :hint "sample")))
      (decklet-db--upsert-card "lucid" meta)
      (let ((row (decklet-db--select-card "lucid")))
        (should row)
        (should (string= (car row) "lucid"))))))

;; ---------------------------------------------------------------------------
;; Archive/unarchive flow
;; ---------------------------------------------------------------------------
;; Ensures archive filters behave correctly and that unarchive returns the card
;; to normal (non-archived) selection results.

(ert-deftest decklet-test-archive-filter-flow ()
  (decklet-test--with-temp-db
    (let* ((now (current-time))
           (ts (decklet-test--ts now))
           (meta (decklet-test--make-meta
                  :added-date ts :last-review ts :due ts :state :review)))
      (decklet-db--upsert-card "archive-me" meta)
      (should (= 1 (length (decklet-db--select-cards 'all nil))))
      (decklet-db--archive-card "archive-me" ts)
      (should (= 0 (length (decklet-db--select-cards 'all nil))))
      (should (= 1 (length (decklet-db--select-cards 'archived nil))))
      (decklet-db--unarchive-card "archive-me")
      (should (= 1 (length (decklet-db--select-cards 'all nil)))))))

;; ---------------------------------------------------------------------------
;; Due-word selection with review-order
;; ---------------------------------------------------------------------------
;; Exercises the DB-level queue assembly:
;; - learning due "now" by exact timestamp,
;; - new/review due by review-day cutoff,
;; - final sequence respects configured review-order steps.

(ert-deftest decklet-test-select-due-words-review-order ()
  (decklet-test--with-temp-db
    (let* ((now (current-time))
           (past-2h (time-subtract now (seconds-to-time (* 2 3600))))
           (past-1h (time-subtract now (seconds-to-time 3600)))
           (past-10m (time-subtract now (seconds-to-time 600)))
           (future-30m (time-add now (seconds-to-time 1800))))
      ;; Learning due now.
      (decklet-db--upsert-card
       "learn-a"
       (decklet-test--make-meta
        :added-date (decklet-test--ts past-2h)
        :last-review (decklet-test--ts past-1h)
        :due (decklet-test--ts past-10m)
        :state :learning))
      ;; New card (last_review nil), due by today's review cutoff.
      (decklet-db--upsert-card
       "new-a"
       (decklet-test--make-meta
        :added-date (decklet-test--ts now)
        :last-review nil
        :due (decklet-test--ts now)
        :state :learning))
      ;; Review card due later today (still included in review target).
      (decklet-db--upsert-card
       "review-a"
       (decklet-test--make-meta
        :added-date (decklet-test--ts past-2h)
        :last-review (decklet-test--ts past-1h)
        :due (decklet-test--ts future-30m)
        :state :review))

      (should (equal (decklet-db--select-due-words)
                     '("learn-a" "new-a" "review-a"))))))

;; ---------------------------------------------------------------------------
;; Review-order validation
;; ---------------------------------------------------------------------------
;; These tests guard schema rules for `decklet-review-order`.
;; Duplicate targets should fail early, and learning/new sort fields are
;; intentionally restricted.

(ert-deftest decklet-test-review-order-validate-rejects-duplicates ()
  (should-error
   (decklet-db--review-validate-order
    '((:shuffle :review)
      (:sort :due :asc :review)))))

(ert-deftest decklet-test-review-order-validate-rejects-invalid-learning-sort-field ()
  (should-error
   (decklet-db--review-validate-order
    '((:sort :stability :desc :learning)))))

;; ---------------------------------------------------------------------------
;; Edit sorting SQL generation
;; ---------------------------------------------------------------------------
;; Critical for table behavior: numeric columns use numeric coalesce (0),
;; while text/time columns use string coalesce ('').

(ert-deftest decklet-test-edit-order-sql-numeric-vs-text-columns ()
  (should (string-match-p
           "ORDER BY COALESCE(stability, 0) DESC, rowid DESC"
           (decklet-db--edit-order-sql '("Stability" . t))))
  (should (string-match-p
           "ORDER BY COALESCE(due, '') ASC, rowid ASC"
           (decklet-db--edit-order-sql '("Due" . nil)))))

;; ---------------------------------------------------------------------------
;; Backup naming + list ordering
;; ---------------------------------------------------------------------------
;; These tests target backup file conventions:
;; - suffix collision resolution,
;; - newest-first ordering by embedded UTC timestamp,
;; - timestamp extraction from suffixed filenames.

(ert-deftest decklet-test-backup-target-adds-numeric-suffix ()
  (decklet-test--with-temp-db
    (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
           (base (file-name-base decklet-db-file))
           (timestamp "20260206T120000Z")
           (existing (expand-file-name
                      (format "%s-%s.sqlite" base timestamp)
                      backup-dir)))
      (make-directory backup-dir t)
      (with-temp-file existing (insert "dummy"))
      (should (string= (decklet-db--backup-target backup-dir base timestamp)
                       (expand-file-name
                        (format "%s-%s-1.sqlite" base timestamp)
                        backup-dir))))))

(ert-deftest decklet-test-backup-files-sorted-by-timestamp-desc ()
  (decklet-test--with-temp-db
    (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
           (base (file-name-base decklet-db-file))
           (older (expand-file-name
                   (format "%s-20250101T010101Z.sqlite" base)
                   backup-dir))
           (middle (expand-file-name
                    (format "%s-20250102T010101Z.sqlite" base)
                    backup-dir))
           (newest (expand-file-name
                    (format "%s-20250103T010101Z.sqlite" base)
                    backup-dir)))
      (make-directory backup-dir t)
      (dolist (f (list middle newest older))
        (with-temp-file f (insert "dummy")))
      (should (equal (decklet-db--backup-files)
                     (list newest middle older))))))

(ert-deftest decklet-test-backup-timestamp-parses-suffixed-filenames ()
  (decklet-test--with-temp-db
    (let* ((base (file-name-base decklet-db-file))
           (file (expand-file-name
                  (format "%s-20260101T123456Z-2.sqlite" base)
                  temporary-file-directory))
           (parsed (decklet-db--backup-timestamp file)))
      (should parsed)
      (should (string= (format-time-string "%Y%m%dT%H%M%SZ" parsed "UTC0")
                       "20260101T123456Z")))))

;; Ensure exported UTC timestamp helper always matches the filename-friendly
;; compact format used by backups and JSON exports.
(ert-deftest decklet-test-db-timestamp-utc-format ()
  (should (string-match-p
           "\\`[0-9]\\{8\\}T[0-9]\\{6\\}Z\\'"
           (decklet-db--timestamp-utc))))

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
      (should (= 1 (length (decklet-db--select-cards 'all nil))))
      (should (= 1 (length (decklet-db--select-cards 'archived nil)))))))

(ert-deftest decklet-test-db-import-json-conflict-skip-and-overwrite ()
  (decklet-test--with-temp-db
    (let* ((file (expand-file-name "import-conflict.json" tmp-dir))
           (base-meta (decklet-test--make-meta
                       :added-date "20250101T000000Z"
                       :last-review "20250101T000000Z"
                       :due "20250102T000000Z"
                       :state :review
                       :hint "old"))
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
      (with-temp-file file
        (insert (json-encode rows)))
      ;; Conflict => skip
      (cl-letf (((symbol-function 'decklet-db--import-read-conflict-choice)
                 (lambda (_word) (cons :skip nil))))
        (let ((stats (decklet-db-import-json file)))
          (should (= 0 (plist-get stats :added)))
          (should (= 0 (plist-get stats :overwritten)))
          (should (= 1 (plist-get stats :skipped)))))
      (should (string= "old" (nth 8 (decklet-db--select-card "alpha"))))
      ;; Conflict => overwrite
      (cl-letf (((symbol-function 'decklet-db--import-read-conflict-choice)
                 (lambda (_word) (cons :overwrite nil))))
        (let ((stats (decklet-db-import-json file)))
          (should (= 0 (plist-get stats :added)))
          (should (= 1 (plist-get stats :overwritten)))
          (should (= 0 (plist-get stats :skipped)))))
      (should (string= "new" (nth 8 (decklet-db--select-card "alpha")))))))

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
  (pcase-let ((`(,_word ,review-meta ,_archived)
               (decklet-db--import-record->card
                '((word . "review-word")
                  (state . "review"))))
              (`(,_word2 ,learning-meta ,_archived2)
               (decklet-db--import-record->card
                '((word . "learning-word")
                  (state . "learning")))))
    (should (null (decklet-card-meta-step review-meta)))
    (should (= 0 (decklet-card-meta-step learning-meta)))))

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
    (should (string-match-p "state = 'review'" review-sql))
    (should (equal review-params nil))

    (should (string-match-p "archived_at IS NULL" learning-sql))
    (should (string-match-p "state IN ('learning', 'relearning')" learning-sql))
    (should (equal learning-params nil))

    (should (string-match-p "archived_at IS NOT NULL" archived-sql))
    (should (equal archived-params nil))

    (should (string-match-p "archived_at IS NULL" all-sql))
    (should (equal all-params nil))))

;; ---------------------------------------------------------------------------
;; Review target clause generation
;; ---------------------------------------------------------------------------
;; Validates that each target kind maps to expected WHERE conditions and
;; generates exactly one cutoff parameter.

(ert-deftest decklet-test-review-target-clause-shapes ()
  (let* ((now (current-time))
         (learning (decklet-db--review-target-clause :learning now))
         (review (decklet-db--review-target-clause :review now))
         (new (decklet-db--review-target-clause :new now)))
    (should (string-match-p "state IN ('learning', 'relearning')" (car learning)))
    (should (string-match-p "state = 'review'" (car review)))
    (should (string-match-p "last_review IS NULL" (car new)))
    (should (= 1 (length (cdr learning))))
    (should (= 1 (length (cdr review))))
    (should (= 1 (length (cdr new))))))

;; ---------------------------------------------------------------------------
;; Backup prune behavior
;; ---------------------------------------------------------------------------
;; Here we test both non-interactive prune by max-count, and interactive
;; confirmation refusal.

(ert-deftest decklet-test-backup-prune-max-count-without-confirm ()
  (decklet-test--with-temp-db
    (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
           (base (file-name-base decklet-db-file))
           (decklet-backup-retain-days 365)
           (decklet-backup-prune-min-count 999)
           (decklet-backup-prune-max-count 2)
           (decklet-backup-prune-confirm nil)
           (files (list
                   (expand-file-name (format "%s-20250101T010101Z.sqlite" base) backup-dir)
                   (expand-file-name (format "%s-20250102T010101Z.sqlite" base) backup-dir)
                   (expand-file-name (format "%s-20250103T010101Z.sqlite" base) backup-dir)
                   (expand-file-name (format "%s-20250104T010101Z.sqlite" base) backup-dir))))
      (make-directory backup-dir t)
      (cl-loop for f in files
               for idx from 0
               do (with-temp-file f (insert "dummy"))
               do (set-file-times f (time-subtract (current-time)
                                                   (days-to-time (+ 10 idx)))))
      (decklet-db--backup-prune backup-dir base)
      (let ((remaining (sort (directory-files backup-dir t "\\.sqlite\\'") #'string<)))
        (should (= 2 (length remaining)))
        ;; Should keep the two newest by file mtime.
        ;; In this fixture, 20250101/20250102 were given newer mtimes.
        (should (equal (mapcar #'file-name-nondirectory remaining)
                       (list (format "%s-20250101T010101Z.sqlite" base)
                             (format "%s-20250102T010101Z.sqlite" base))))))))

(ert-deftest decklet-test-backup-prune-respects-confirm-no ()
  (decklet-test--with-temp-db
    (let* ((backup-dir (file-name-as-directory decklet-backup-directory))
           (base (file-name-base decklet-db-file))
           (decklet-backup-retain-days 365)
           (decklet-backup-prune-min-count 1)
           (decklet-backup-prune-max-count 1)
           (decklet-backup-prune-confirm t)
           (files (list
                   (expand-file-name (format "%s-20250101T010101Z.sqlite" base) backup-dir)
                   (expand-file-name (format "%s-20250102T010101Z.sqlite" base) backup-dir))))
      (make-directory backup-dir t)
      (dolist (f files)
        (with-temp-file f (insert "dummy")))
      ;; Mock confirmation prompt: user declines, so nothing should be deleted.
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil)))
        (decklet-db--backup-prune backup-dir base))
      (should (= 2 (length (directory-files backup-dir t "\\.sqlite\\'")))))))

;; ---------------------------------------------------------------------------
;; Backup idempotency
;; ---------------------------------------------------------------------------
;; Calling interactive backup twice without DB changes should create exactly one
;; backup file.

(ert-deftest decklet-test-db-backup-skip-when-unchanged ()
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    ;; Create a real DB change so first backup has content.
    (let* ((now (decklet-test--ts (current-time)))
           (meta (decklet-test--make-meta
                  :added-date now :last-review now :due now :state :review)))
      (decklet-db--upsert-card "backup-word" meta))
    (decklet-db-backup)
    (let ((count-1 (length (decklet-db--backup-files))))
      (should (= 1 count-1))
      ;; No DB writes between backups; second call should not add files.
      (decklet-db-backup)
      (should (= count-1 (length (decklet-db--backup-files)))))))

;; ---------------------------------------------------------------------------
;; Completion binding hook behavior
;; ---------------------------------------------------------------------------
;; The restore completion wrapper supports dynamic var bindings for completion
;; UIs (e.g., vertico sorting override).  We mock `completing-read` to prove
;; those bindings are in effect.

(ert-deftest decklet-test-read-backup-choice-binds-completion-vars ()
  (let ((decklet-backup-restore-completion-setup
         (lambda () '((decklet-test--temp-binding . 42))))
        (captured nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt choices &optional predicate require-match initial-input hist def)
                 (setq captured (list :prompt prompt
                                      :choices choices
                                      :predicate predicate
                                      :require-match require-match
                                      :initial-input initial-input
                                      :hist hist
                                      :default def))
                 ;; Read from dynamic binding explicitly.
                 (number-to-string (symbol-value 'decklet-test--temp-binding)))))
      (should (string= (decklet-db--read-backup-choice '("a" "b") "a") "42"))
      ;; Assert important completion contract was preserved.
      (should (equal (plist-get captured :choices) '("a" "b")))
      (should (equal (plist-get captured :default) "a"))
      (should (eq (plist-get captured :require-match) t)))))

;; ---------------------------------------------------------------------------
;; Review flow: grade handling and hook transitions
;; ---------------------------------------------------------------------------
;; These tests focus on the central grade handler used by 1/2/3/4 commands.
;; We explicitly mock side-effect functions (`decklet-rate-card`,
;; `decklet-review-next-card`) so we can verify behavior without UI coupling.

(ert-deftest decklet-test-review-handle-grade-triggers-daily-goal-hook-on-transition ()
  (let ((decklet-current-word "goal-word")
        (hook-count 0)
        (rated nil)
        (next-count 0)
        ;; First check: before rating -> not reached.
        ;; Second check: after rating -> reached.
        (goal-states '(nil t)))
    (let ((decklet-review-daily-goal-reached-hook
           (list (lambda () (setq hook-count (1+ hook-count))))))
      (cl-letf (((symbol-function 'decklet-review--daily-goal-reached-p)
                 (lambda ()
                   (prog1 (car goal-states)
                     (setq goal-states (cdr goal-states)))))
                ((symbol-function 'decklet-rate-card)
                 (lambda (word grade)
                   (setq rated (list word grade))))
                ((symbol-function 'decklet-review-next-card)
                 (lambda ()
                   (setq next-count (1+ next-count)))))
        (decklet-review--handle-grade 3)))
    (should (equal rated '("goal-word" 3)))
    (should (= 1 hook-count))
    (should (= 1 next-count))))

(ert-deftest decklet-test-review-handle-grade-does-not-trigger-hook-without-transition ()
  (let ((decklet-current-word "steady-word")
        (hook-count 0)
        ;; reached before and after rating -> no transition
        (goal-states '(t t)))
    (let ((decklet-review-daily-goal-reached-hook
           (list (lambda () (setq hook-count (1+ hook-count))))))
      (cl-letf (((symbol-function 'decklet-review--daily-goal-reached-p)
                 (lambda ()
                   (prog1 (car goal-states)
                     (setq goal-states (cdr goal-states)))))
                ((symbol-function 'decklet-rate-card) (lambda (&rest _) nil))
                ((symbol-function 'decklet-review-next-card) (lambda () nil)))
        (decklet-review--handle-grade 1)))
    (should (= 0 hook-count))))

;; ---------------------------------------------------------------------------
;; Review flow: next-card sequencing and hook execution
;; ---------------------------------------------------------------------------
;; Ensures `decklet-review-next-card` consumes queue state in order and runs
;; next-card hook once per transition.

(ert-deftest decklet-test-review-next-card-consumes-due-queue-and-runs-hook ()
  (let ((decklet-due-words '("w1" "w2"))
        (decklet-current-word nil)
        (hook-count 0))
    (let ((decklet-review-next-card-hook
           (list (lambda () (setq hook-count (1+ hook-count))))))
      (cl-letf (((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
                ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil))
                ((symbol-function 'decklet-review-quit) (lambda () nil)))
        (decklet-review-next-card)))
    (should (equal decklet-current-word "w1"))
    (should (equal decklet-due-words '("w2")))
    (should (= 1 hook-count))))

;; ---------------------------------------------------------------------------
;; Edit flow: batch operations and delegation branches
;; ---------------------------------------------------------------------------
;; These tests verify branch behavior in `decklet-edit-delete` and
;; `decklet-edit-archive` without requiring tabulated-list UI setup.

(ert-deftest decklet-test-edit-mark-with-region-marks-selected-lines ()
  (with-temp-buffer
    (insert "a\nb\nc\n")
    (let ((decklet-edit--marked (make-hash-table :test 'equal))
          (decklet-edit--mark-overlays (make-hash-table :test 'equal)))
      (cl-letf (((symbol-function 'tabulated-list-get-id)
                 (lambda ()
                   (pcase (line-number-at-pos)
                     (1 "a")
                     (2 "b")
                     (3 "c")
                     (_ nil)))))
        (decklet-edit--mark-region (point-min)
                                   (save-excursion
                                     (goto-char (point-min))
                                     (forward-line 2)
                                     (point))))
      (should (gethash "a" decklet-edit--marked))
      (should (gethash "b" decklet-edit--marked))
      (should-not (gethash "c" decklet-edit--marked)))))

(ert-deftest decklet-test-edit-mark-uses-region-branch-when-active ()
  (let ((called nil)
        (deactivated nil)
        (moved nil))
    (cl-letf (((symbol-function 'use-region-p) (lambda () t))
              ((symbol-function 'region-beginning) (lambda () 10))
              ((symbol-function 'region-end) (lambda () 20))
              ((symbol-function 'decklet-edit--mark-region)
               (lambda (beg end)
                 (setq called (list beg end))))
              ((symbol-function 'deactivate-mark)
               (lambda () (setq deactivated t)))
              ((symbol-function 'goto-char)
               (lambda (pos) (setq moved pos)))
              ((symbol-function 'beginning-of-line) (lambda () nil))
              ((symbol-function 'forward-line) (lambda (&rest _) nil)))
      (decklet-edit-mark))
    (should (equal called '(10 20)))
    (should deactivated)
    (should (= moved 20))))

(ert-deftest decklet-test-edit-delete-marked-branch-runs-batch-delete ()
  (let ((deleted '())
         (ensured nil)
         (cleared nil)
         (refreshed nil)
         (restored nil))
    (cl-letf (((symbol-function 'decklet-edit--marked-words)
               (lambda () '("a" "b")))
              ((symbol-function 'decklet-edit--nearest-surviving-word)
               (lambda (_words) "next-word"))
              ((symbol-function 'count-screen-lines)
               (lambda (&rest _) 7))
              ((symbol-function 'decklet-edit--ensure-not-current)
               (lambda (words) (setq ensured words)))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'decklet-delete-card)
               (lambda (word) (push word deleted)))
              ((symbol-function 'decklet-edit--clear-marks)
               (lambda () (setq cleared t)))
              ((symbol-function 'decklet-edit-refresh)
               (lambda () (setq refreshed t)))
              ((symbol-function 'decklet-edit--line-of-word)
               (lambda (word)
                 (when (string= word "next-word")
                   5)))
              ((symbol-function 'decklet-edit--restore-position)
               (lambda (line win-line)
                 (setq restored (list line win-line))))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (decklet-edit-delete))
    (should (equal ensured '("a" "b")))
    (should (equal (sort deleted #'string<) '("a" "b")))
    (should cleared)
    (should refreshed)
    (should (equal restored '(5 7)))))

(ert-deftest decklet-test-edit-nearest-surviving-word-prefers-forward-on-tie ()
  (with-temp-buffer
    (insert "a\nb\nc\nd\n")
    (goto-char (point-min))
    (forward-line 2)
    (cl-letf (((symbol-function 'tabulated-list-get-id)
               (lambda ()
                 (pcase (line-number-at-pos)
                   (1 "a")
                   (2 "b")
                   (3 "c")
                   (4 "d")
                   (_ nil)))))
      (should (string= (decklet-edit--nearest-surviving-word '("c")) "d"))
      (should (string= (decklet-edit--nearest-surviving-word '("b" "c")) "d")))))

(ert-deftest decklet-test-edit-delete-without-marks-delegates-to-single-delete ()
  (let ((delegated nil))
    (cl-letf (((symbol-function 'decklet-edit--marked-words) (lambda () nil))
              ((symbol-function 'decklet-edit-delete-card)
               (lambda () (setq delegated t))))
      (decklet-edit-delete))
    (should delegated)))

(ert-deftest decklet-test-edit-archive-uses-unarchive-in-archived-filter ()
  (let ((decklet-edit--filter 'archived)
         (unarchived nil)
         (archived nil))
    (cl-letf (((symbol-function 'decklet-edit--marked-words) (lambda () nil))
              ((symbol-function 'decklet-edit-unarchive-card)
               (lambda () (setq unarchived t)))
              ((symbol-function 'decklet-edit-archive-card)
               (lambda () (setq archived t))))
      (decklet-edit-archive))
    (should unarchived)
    (should-not archived)))

(ert-deftest decklet-test-edit-archive-marked-in-archived-filter-unarchives-and-restores ()
  (let ((decklet-edit--filter 'archived)
        (unarchived '())
        (archived nil)
        (ensured nil)
        (cleared nil)
        (refreshed nil)
        (restored nil))
    (cl-letf (((symbol-function 'decklet-edit--marked-words)
               (lambda () '("a" "b")))
              ((symbol-function 'decklet-edit--nearest-surviving-word)
               (lambda (_words) "next-word"))
              ((symbol-function 'count-screen-lines)
               (lambda (&rest _) 6))
              ((symbol-function 'decklet-edit--ensure-not-current)
               (lambda (words) (setq ensured words)))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'decklet-unarchive-card)
               (lambda (word) (push word unarchived)))
              ((symbol-function 'decklet-archive-card)
               (lambda (&rest _) (setq archived t)))
              ((symbol-function 'decklet-edit--clear-marks)
               (lambda () (setq cleared t)))
              ((symbol-function 'decklet-edit-refresh)
               (lambda () (setq refreshed t)))
              ((symbol-function 'decklet-edit--line-of-word)
               (lambda (word)
                 (when (string= word "next-word")
                   4)))
              ((symbol-function 'decklet-edit--restore-position)
               (lambda (line win-line)
                 (setq restored (list line win-line))))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (decklet-edit-archive))
    (should (equal ensured '("a" "b")))
    (should (equal (sort unarchived #'string<) '("a" "b")))
    (should-not archived)
    (should cleared)
    (should refreshed)
    (should (equal restored '(4 6)))))

(ert-deftest decklet-test-edit-archive-marked-in-all-filter-archives-and-restores ()
  (let ((decklet-edit--filter 'all)
        (unarchived nil)
        (archived '())
        (ensured nil)
        (cleared nil)
        (refreshed nil)
        (restored nil))
    (cl-letf (((symbol-function 'decklet-edit--marked-words)
               (lambda () '("a" "b")))
              ((symbol-function 'decklet-edit--nearest-surviving-word)
               (lambda (_words) "next-word"))
              ((symbol-function 'count-screen-lines)
               (lambda (&rest _) 8))
              ((symbol-function 'decklet-edit--ensure-not-current)
               (lambda (words) (setq ensured words)))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'decklet-unarchive-card)
               (lambda (&rest _) (setq unarchived t)))
              ((symbol-function 'decklet-archive-card)
               (lambda (word) (push word archived)))
              ((symbol-function 'decklet-edit--clear-marks)
               (lambda () (setq cleared t)))
              ((symbol-function 'decklet-edit-refresh)
               (lambda () (setq refreshed t)))
              ((symbol-function 'decklet-edit--line-of-word)
               (lambda (word)
                 (when (string= word "next-word")
                   6)))
              ((symbol-function 'decklet-edit--restore-position)
               (lambda (line win-line)
                 (setq restored (list line win-line))))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (decklet-edit-archive))
    (should (equal ensured '("a" "b")))
    (should (equal (sort archived #'string<) '("a" "b")))
    (should-not unarchived)
    (should cleared)
    (should refreshed)
    (should (equal restored '(6 8)))))

(ert-deftest decklet-test-edit-delete-marked-without-survivor-skips-restore ()
  (let ((restored nil))
    (cl-letf (((symbol-function 'decklet-edit--marked-words)
               (lambda () '("a" "b")))
              ((symbol-function 'decklet-edit--nearest-surviving-word)
               (lambda (_words) nil))
              ((symbol-function 'count-screen-lines)
               (lambda (&rest _) 3))
              ((symbol-function 'decklet-edit--ensure-not-current)
               (lambda (&rest _) nil))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'decklet-delete-card)
               (lambda (&rest _) nil))
              ((symbol-function 'decklet-edit--clear-marks)
               (lambda () nil))
              ((symbol-function 'decklet-edit-refresh)
               (lambda () nil))
              ((symbol-function 'decklet-edit--line-of-word)
               (lambda (_word) nil))
              ((symbol-function 'decklet-edit--restore-position)
               (lambda (&rest _) (setq restored t)))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (decklet-edit-delete))
    (should-not restored)))

(ert-deftest decklet-test-edit-delete-marked-cancelled-skips-side-effects ()
  (let ((deleted nil)
        (cleared nil)
        (refreshed nil)
        (restored nil)
        (ensured nil))
    (cl-letf (((symbol-function 'decklet-edit--marked-words)
               (lambda () '("a" "b")))
              ((symbol-function 'decklet-edit--nearest-surviving-word)
               (lambda (_words) "next-word"))
              ((symbol-function 'count-screen-lines)
               (lambda (&rest _) 5))
              ((symbol-function 'decklet-edit--ensure-not-current)
               (lambda (words) (setq ensured words)))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
              ((symbol-function 'decklet-delete-card)
               (lambda (&rest _) (setq deleted t)))
              ((symbol-function 'decklet-edit--clear-marks)
               (lambda () (setq cleared t)))
              ((symbol-function 'decklet-edit-refresh)
               (lambda () (setq refreshed t)))
              ((symbol-function 'decklet-edit--line-of-word)
               (lambda (&rest _) 3))
              ((symbol-function 'decklet-edit--restore-position)
               (lambda (&rest _) (setq restored t)))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (decklet-edit-delete))
    (should (equal ensured '("a" "b")))
    (should-not deleted)
    (should-not cleared)
    (should-not refreshed)
    (should-not restored)))

(ert-deftest decklet-test-edit-archive-marked-cancelled-skips-side-effects ()
  (let ((decklet-edit--filter 'all)
        (archived nil)
        (unarchived nil)
        (cleared nil)
        (refreshed nil)
        (restored nil)
        (ensured nil))
    (cl-letf (((symbol-function 'decklet-edit--marked-words)
               (lambda () '("a" "b")))
              ((symbol-function 'decklet-edit--nearest-surviving-word)
               (lambda (_words) "next-word"))
              ((symbol-function 'count-screen-lines)
               (lambda (&rest _) 5))
              ((symbol-function 'decklet-edit--ensure-not-current)
               (lambda (words) (setq ensured words)))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
              ((symbol-function 'decklet-archive-card)
               (lambda (&rest _) (setq archived t)))
              ((symbol-function 'decklet-unarchive-card)
               (lambda (&rest _) (setq unarchived t)))
              ((symbol-function 'decklet-edit--clear-marks)
               (lambda () (setq cleared t)))
              ((symbol-function 'decklet-edit-refresh)
               (lambda () (setq refreshed t)))
              ((symbol-function 'decklet-edit--line-of-word)
               (lambda (&rest _) 3))
              ((symbol-function 'decklet-edit--restore-position)
               (lambda (&rest _) (setq restored t)))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (decklet-edit-archive))
    (should (equal ensured '("a" "b")))
    (should-not archived)
    (should-not unarchived)
    (should-not cleared)
    (should-not refreshed)
    (should-not restored)))

;; ---------------------------------------------------------------------------
;; Review rendering internals (lightweight, no window coupling)
;; ---------------------------------------------------------------------------
;; We only test the pure list-assembly behavior here.  This protects the
;; separator-collapse rule without requiring full buffer rendering.

(ert-deftest decklet-test-review-collect-component-items-collapses-separators ()
  (cl-letf (((symbol-function 'decklet-review-component-separator)
             (lambda () "SEP"))
            ((symbol-function 'decklet-test--component-a)
             (lambda () "A"))
            ((symbol-function 'decklet-test--component-b)
             (lambda () "B")))
    (let* ((result (decklet-review--collect-component-items
                    '(decklet-review-component-separator
                      decklet-test--component-a
                      decklet-review-component-separator
                      decklet-review-component-separator
                      decklet-test--component-b)))
           (items (car result)))
      ;; Leading separator should be skipped.
      ;; Consecutive separators should collapse into one.
      (should (equal (mapcar #'car items) '("A" "SEP" "B")))
      (should (equal (mapcar #'cdr items) '(nil t nil))))))

;; ---------------------------------------------------------------------------
;; Hint timer state machine
;; ---------------------------------------------------------------------------
;; `decklet-review--start-hint-timer' should not schedule multiple timers.

(ert-deftest decklet-test-review-start-hint-timer-is-idempotent ()
  (let ((decklet-review--hint-timer nil)
        (calls 0)
        (decklet-review-hint-delay 0.1))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (&rest _)
                 (setq calls (1+ calls))
                 'fake-timer)))
      (decklet-review--start-hint-timer)
      (decklet-review--start-hint-timer))
    (should (= calls 1))
    (should (eq decklet-review--hint-timer 'fake-timer))))

;; ---------------------------------------------------------------------------
;; Calendar-facing DB aggregation
;; ---------------------------------------------------------------------------
;; Keep this at DB layer: verify overdue and in-range due counts are split
;; correctly for `decklet-db--due-counts-by-date'.

(ert-deftest decklet-test-db-due-counts-by-date-splits-overdue-and-range ()
  (decklet-test--with-temp-db
    (let* ((now (current-time))
           (day-start (decklet--day-start-time now))
           (cutoff (decklet--next-day-start-time now))
           (overdue-time (time-subtract day-start (seconds-to-time 60)))
           (in-range-time (time-add day-start (seconds-to-time 3600)))
           (ts-added (decklet-test--ts (time-subtract now (seconds-to-time 7200))))
           (ts-last (decklet-test--ts (time-subtract now (seconds-to-time 1800)))))
      ;; Overdue reviewed card.
      (decklet-db--upsert-card
       "overdue-card"
       (decklet-test--make-meta
        :added-date ts-added
        :last-review ts-last
        :due (decklet-test--ts overdue-time)
        :state :review))
      ;; Due in current [day-start, cutoff) window.
      (decklet-db--upsert-card
       "range-card"
       (decklet-test--make-meta
        :added-date ts-added
        :last-review ts-last
        :due (decklet-test--ts in-range-time)
        :state :review))
      (let* ((result (decklet-db--due-counts-by-date day-start cutoff))
             (rows (plist-get result :rows))
             (overdue (plist-get result :overdue))
             (in-range-count (apply #'+ (mapcar #'cadr rows))))
        (should (= overdue 1))
        (should (= in-range-count 1))))))

(provide 'decklet-test)
;;; decklet-test.el ends here

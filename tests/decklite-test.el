;;; decklite-test.el --- Tests for DeckLite -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'decklite)

(defmacro decklite-test--with-temp-db (&rest body)
  "Run BODY with an isolated temporary DeckLite database."
  (declare (indent 0) (debug t))
  `(let* ((tmp-dir (make-temp-file "decklite-test-" t))
          (decklite-directory (file-name-as-directory tmp-dir))
          (decklite-db-file (expand-file-name "decklite.sqlite" tmp-dir))
          (decklite-backup-directory (expand-file-name "backups" tmp-dir))
          (decklite-db--conn nil)
          (decklite--fsrs-scheduler nil)
          (decklite-review-order '((:sort :due :asc :learning)
                                    (:sort :added :desc :new)
                                    (:sort :due :asc :review))))
     (unwind-protect
         (progn
           ,@body)
       (when (and (boundp 'decklite-db--conn) decklite-db--conn)
         (sqlite-close decklite-db--conn)
         (setq decklite-db--conn nil))
       (delete-directory tmp-dir t))))

(defun decklite-test--ts (time)
  "Convert TIME to DeckLite timestamp string."
  (decklite--time->fsrs-timestamp time))

(defun decklite-test--make-meta (&rest plist)
  "Create a card meta object from PLIST."
  (apply #'make-decklite-card-meta plist))

;; ---------------------------------------------------------------------------
;; Normalization helpers
;; ---------------------------------------------------------------------------
;; These tests protect input sanitation rules.  Empty/blank words must fail,
;; while hint normalization should map blank strings to nil.

(ert-deftest decklite-test-normalize-word ()
  (should (string= (decklite-db--normalize-word "  lucid  ") "lucid"))
  (should-error (decklite-db--normalize-word "  "))
  (should-error (decklite-db--normalize-word "")))

(ert-deftest decklite-test-normalize-hint ()
  (should (equal (decklite-db--normalize-hint nil) nil))
  (should (equal (decklite-db--normalize-hint "  ") nil))
  (should (string= (decklite-db--normalize-hint "  foo bar  ") "foo bar")))

;; ---------------------------------------------------------------------------
;; Basic DB lifecycle
;; ---------------------------------------------------------------------------
;; Verifies that DB initialization + upsert + select round-trip works for the
;; minimal card payload.

(ert-deftest decklite-test-db-ensure-and-upsert-select ()
  (decklite-test--with-temp-db
    (decklite-db--ensure)
    (let* ((now (current-time))
           (meta (decklite-test--make-meta
                  :added-date (decklite-test--ts now)
                  :last-review (decklite-test--ts now)
                  :due (decklite-test--ts now)
                  :state :review
                  :hint "sample")))
      (decklite-db--upsert-card "lucid" meta)
      (let ((row (decklite-db--select-card "lucid")))
        (should row)
        (should (string= (car row) "lucid"))))))

;; ---------------------------------------------------------------------------
;; Archive/unarchive flow
;; ---------------------------------------------------------------------------
;; Ensures archive filters behave correctly and that unarchive returns the card
;; to normal (non-archived) selection results.

(ert-deftest decklite-test-archive-filter-flow ()
  (decklite-test--with-temp-db
    (let* ((now (current-time))
           (ts (decklite-test--ts now))
           (meta (decklite-test--make-meta
                  :added-date ts :last-review ts :due ts :state :review)))
      (decklite-db--upsert-card "archive-me" meta)
      (should (= 1 (length (decklite-db--select-cards 'all nil))))
      (decklite-db--archive-card "archive-me" ts)
      (should (= 0 (length (decklite-db--select-cards 'all nil))))
      (should (= 1 (length (decklite-db--select-cards 'archived nil))))
      (decklite-db--unarchive-card "archive-me")
      (should (= 1 (length (decklite-db--select-cards 'all nil)))))))

;; ---------------------------------------------------------------------------
;; Due-word selection with review-order
;; ---------------------------------------------------------------------------
;; Exercises the DB-level queue assembly:
;; - learning due "now" by exact timestamp,
;; - new/review due by review-day cutoff,
;; - final sequence respects configured review-order steps.

(ert-deftest decklite-test-select-due-words-review-order ()
  (decklite-test--with-temp-db
    (let* ((now (current-time))
           (past-2h (time-subtract now (seconds-to-time (* 2 3600))))
           (past-1h (time-subtract now (seconds-to-time 3600)))
           (past-10m (time-subtract now (seconds-to-time 600)))
           (future-30m (time-add now (seconds-to-time 1800))))
      ;; Learning due now.
      (decklite-db--upsert-card
       "learn-a"
       (decklite-test--make-meta
        :added-date (decklite-test--ts past-2h)
        :last-review (decklite-test--ts past-1h)
        :due (decklite-test--ts past-10m)
        :state :learning))
      ;; New card (last_review nil), due by today's review cutoff.
      (decklite-db--upsert-card
       "new-a"
       (decklite-test--make-meta
        :added-date (decklite-test--ts now)
        :last-review nil
        :due (decklite-test--ts now)
        :state :learning))
      ;; Review card due later today (still included in review target).
      (decklite-db--upsert-card
       "review-a"
       (decklite-test--make-meta
        :added-date (decklite-test--ts past-2h)
        :last-review (decklite-test--ts past-1h)
        :due (decklite-test--ts future-30m)
        :state :review))

      (should (equal (decklite-db--select-due-words)
                     '("learn-a" "new-a" "review-a"))))))

;; ---------------------------------------------------------------------------
;; Review-order validation
;; ---------------------------------------------------------------------------
;; These tests guard schema rules for `decklite-review-order`.
;; Duplicate targets should fail early, and learning/new sort fields are
;; intentionally restricted.

(ert-deftest decklite-test-review-order-validate-rejects-duplicates ()
  (should-error
   (decklite-db--review-validate-order
    '((:shuffle :review)
      (:sort :due :asc :review)))))

(ert-deftest decklite-test-review-order-validate-rejects-invalid-learning-sort-field ()
  (should-error
   (decklite-db--review-validate-order
    '((:sort :stability :desc :learning)))))

;; ---------------------------------------------------------------------------
;; Edit sorting SQL generation
;; ---------------------------------------------------------------------------
;; Critical for table behavior: numeric columns use numeric coalesce (0),
;; while text/time columns use string coalesce ('').

(ert-deftest decklite-test-edit-order-sql-numeric-vs-text-columns ()
  (should (string-match-p
           "ORDER BY COALESCE(stability, 0) DESC, rowid DESC"
           (decklite-db--edit-order-sql '("Stability" . t))))
  (should (string-match-p
           "ORDER BY COALESCE(due, '') ASC, rowid ASC"
           (decklite-db--edit-order-sql '("Due" . nil)))))

;; ---------------------------------------------------------------------------
;; Backup naming + list ordering
;; ---------------------------------------------------------------------------
;; These tests target backup file conventions:
;; - suffix collision resolution,
;; - newest-first ordering by embedded UTC timestamp,
;; - timestamp extraction from suffixed filenames.

(ert-deftest decklite-test-backup-target-adds-numeric-suffix ()
  (decklite-test--with-temp-db
    (let* ((backup-dir (file-name-as-directory decklite-backup-directory))
           (base (file-name-base decklite-db-file))
           (timestamp "20260206T120000Z")
           (existing (expand-file-name
                      (format "%s-%s.sqlite" base timestamp)
                      backup-dir)))
      (make-directory backup-dir t)
      (with-temp-file existing (insert "dummy"))
      (should (string= (decklite-db--backup-target backup-dir base timestamp)
                       (expand-file-name
                        (format "%s-%s-1.sqlite" base timestamp)
                        backup-dir))))))

(ert-deftest decklite-test-backup-files-sorted-by-timestamp-desc ()
  (decklite-test--with-temp-db
    (let* ((backup-dir (file-name-as-directory decklite-backup-directory))
           (base (file-name-base decklite-db-file))
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
      (should (equal (decklite-db--backup-files)
                     (list newest middle older))))))

(ert-deftest decklite-test-backup-timestamp-parses-suffixed-filenames ()
  (decklite-test--with-temp-db
    (let* ((base (file-name-base decklite-db-file))
           (file (expand-file-name
                  (format "%s-20260101T123456Z-2.sqlite" base)
                  temporary-file-directory))
           (parsed (decklite-db--backup-timestamp file)))
      (should parsed)
      (should (string= (format-time-string "%Y%m%dT%H%M%SZ" parsed "UTC0")
                       "20260101T123456Z")))))

;; Ensure exported UTC timestamp helper always matches the filename-friendly
;; compact format used by backups and JSON exports.
(ert-deftest decklite-test-db-timestamp-utc-format ()
  (should (string-match-p
           "\\`[0-9]\\{8\\}T[0-9]\\{6\\}Z\\'"
           (decklite-db--timestamp-utc))))

;; ---------------------------------------------------------------------------
;; JSON import
;; ---------------------------------------------------------------------------
;; Covers:
;; - importing exported-format JSON rows,
;; - archived flag preservation,
;; - duplicate conflict handling (skip/overwrite + global choice).

(ert-deftest decklite-test-db-import-json-adds-and-preserves-archive ()
  (decklite-test--with-temp-db
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
      (let ((stats (decklite-db-import-json file)))
        (should (= 2 (plist-get stats :added)))
        (should (= 0 (plist-get stats :overwritten)))
        (should (= 0 (plist-get stats :skipped))))
      (should (= 1 (length (decklite-db--select-cards 'all nil))))
      (should (= 1 (length (decklite-db--select-cards 'archived nil)))))))

(ert-deftest decklite-test-db-import-json-conflict-skip-and-overwrite ()
  (decklite-test--with-temp-db
    (let* ((file (expand-file-name "import-conflict.json" tmp-dir))
           (base-meta (decklite-test--make-meta
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
      (decklite-db--upsert-card "alpha" base-meta)
      (with-temp-file file
        (insert (json-encode rows)))
      ;; Conflict => skip
      (cl-letf (((symbol-function 'decklite-db--import-read-conflict-choice)
                 (lambda (_word) (cons :skip nil))))
        (let ((stats (decklite-db-import-json file)))
          (should (= 0 (plist-get stats :added)))
          (should (= 0 (plist-get stats :overwritten)))
          (should (= 1 (plist-get stats :skipped)))))
      (should (string= "old" (nth 8 (decklite-db--select-card "alpha"))))
      ;; Conflict => overwrite
      (cl-letf (((symbol-function 'decklite-db--import-read-conflict-choice)
                 (lambda (_word) (cons :overwrite nil))))
        (let ((stats (decklite-db-import-json file)))
          (should (= 0 (plist-get stats :added)))
          (should (= 1 (plist-get stats :overwritten)))
          (should (= 0 (plist-get stats :skipped)))))
      (should (string= "new" (nth 8 (decklite-db--select-card "alpha")))))))

(ert-deftest decklite-test-db-import-read-conflict-choice-global-confirm ()
  ;; Choosing all-overwrite and confirming should return current overwrite action
  ;; and persist global overwrite for remaining conflicts.
  (cl-letf (((symbol-function 'read-char-choice)
             (lambda (_prompt _chars) ?A))
            ((symbol-function 'yes-or-no-p)
             (lambda (_prompt) t)))
    (should (equal (decklite-db--import-read-conflict-choice "alpha")
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
      (should (equal (decklite-db--import-read-conflict-choice "beta")
                     '(:overwrite . nil))))))

(ert-deftest decklite-test-db-import-record-step-default-by-state ()
  ;; Missing step defaults to nil for review, 0 for learning-like states.
  (pcase-let ((`(,_word ,review-meta ,_archived)
               (decklite-db--import-record->card
                '((word . "review-word")
                  (state . "review"))))
              (`(,_word2 ,learning-meta ,_archived2)
               (decklite-db--import-record->card
                '((word . "learning-word")
                  (state . "learning")))))
    (should (null (decklite-card-meta-step review-meta)))
    (should (= 0 (decklite-card-meta-step learning-meta)))))

;; ---------------------------------------------------------------------------
;; Edit filter SQL mapping
;; ---------------------------------------------------------------------------
;; Keeps tabulated-list filter commands stable by asserting exact SQL snippets.

(ert-deftest decklite-test-edit-filter-sql-clauses ()
  (pcase-let ((`(,review-sql . ,review-params) (decklite-db--edit-filter-sql 'review))
              (`(,learning-sql . ,learning-params) (decklite-db--edit-filter-sql 'learning))
              (`(,archived-sql . ,archived-params) (decklite-db--edit-filter-sql 'archived))
              (`(,all-sql . ,all-params) (decklite-db--edit-filter-sql 'all)))
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

(ert-deftest decklite-test-review-target-clause-shapes ()
  (let* ((now (current-time))
         (learning (decklite-db--review-target-clause :learning now))
         (review (decklite-db--review-target-clause :review now))
         (new (decklite-db--review-target-clause :new now)))
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

(ert-deftest decklite-test-backup-prune-max-count-without-confirm ()
  (decklite-test--with-temp-db
    (let* ((backup-dir (file-name-as-directory decklite-backup-directory))
           (base (file-name-base decklite-db-file))
           (decklite-backup-retain-days 365)
           (decklite-backup-prune-min-count 999)
           (decklite-backup-prune-max-count 2)
           (decklite-backup-prune-confirm nil)
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
      (decklite-db--backup-prune backup-dir base)
      (let ((remaining (sort (directory-files backup-dir t "\\.sqlite\\'") #'string<)))
        (should (= 2 (length remaining)))
        ;; Should keep the two newest by file mtime.
        ;; In this fixture, 20250101/20250102 were given newer mtimes.
        (should (equal (mapcar #'file-name-nondirectory remaining)
                       (list (format "%s-20250101T010101Z.sqlite" base)
                             (format "%s-20250102T010101Z.sqlite" base))))))))

(ert-deftest decklite-test-backup-prune-respects-confirm-no ()
  (decklite-test--with-temp-db
    (let* ((backup-dir (file-name-as-directory decklite-backup-directory))
           (base (file-name-base decklite-db-file))
           (decklite-backup-retain-days 365)
           (decklite-backup-prune-min-count 1)
           (decklite-backup-prune-max-count 1)
           (decklite-backup-prune-confirm t)
           (files (list
                   (expand-file-name (format "%s-20250101T010101Z.sqlite" base) backup-dir)
                   (expand-file-name (format "%s-20250102T010101Z.sqlite" base) backup-dir))))
      (make-directory backup-dir t)
      (dolist (f files)
        (with-temp-file f (insert "dummy")))
      ;; Mock confirmation prompt: user declines, so nothing should be deleted.
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil)))
        (decklite-db--backup-prune backup-dir base))
      (should (= 2 (length (directory-files backup-dir t "\\.sqlite\\'")))))))

;; ---------------------------------------------------------------------------
;; Backup idempotency
;; ---------------------------------------------------------------------------
;; Calling interactive backup twice without DB changes should create exactly one
;; backup file.

(ert-deftest decklite-test-db-backup-skip-when-unchanged ()
  (decklite-test--with-temp-db
    (decklite-db--ensure)
    ;; Create a real DB change so first backup has content.
    (let* ((now (decklite-test--ts (current-time)))
           (meta (decklite-test--make-meta
                  :added-date now :last-review now :due now :state :review)))
      (decklite-db--upsert-card "backup-word" meta))
    (decklite-db-backup)
    (let ((count-1 (length (decklite-db--backup-files))))
      (should (= 1 count-1))
      ;; No DB writes between backups; second call should not add files.
      (decklite-db-backup)
      (should (= count-1 (length (decklite-db--backup-files)))))))

;; ---------------------------------------------------------------------------
;; Completion binding hook behavior
;; ---------------------------------------------------------------------------
;; The restore completion wrapper supports dynamic var bindings for completion
;; UIs (e.g., vertico sorting override).  We mock `completing-read` to prove
;; those bindings are in effect.

(ert-deftest decklite-test-read-backup-choice-binds-completion-vars ()
  (let ((decklite-backup-restore-completion-setup
         (lambda () '((decklite-test--temp-binding . 42))))
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
                 (number-to-string (symbol-value 'decklite-test--temp-binding)))))
      (should (string= (decklite-db--read-backup-choice '("a" "b") "a") "42"))
      ;; Assert important completion contract was preserved.
      (should (equal (plist-get captured :choices) '("a" "b")))
      (should (equal (plist-get captured :default) "a"))
      (should (eq (plist-get captured :require-match) t)))))

;; ---------------------------------------------------------------------------
;; Review flow: grade handling and hook transitions
;; ---------------------------------------------------------------------------
;; These tests focus on the central grade handler used by 1/2/3/4 commands.
;; We explicitly mock side-effect functions (`decklite-rate-card`,
;; `decklite-review-next-card`) so we can verify behavior without UI coupling.

(ert-deftest decklite-test-review-handle-grade-triggers-daily-goal-hook-on-transition ()
  (let ((decklite-current-word "goal-word")
        (hook-count 0)
        (rated nil)
        (next-count 0)
        ;; First check: before rating -> not reached.
        ;; Second check: after rating -> reached.
        (goal-states '(nil t)))
    (let ((decklite-review-daily-goal-reached-hook
           (list (lambda () (setq hook-count (1+ hook-count))))))
      (cl-letf (((symbol-function 'decklite-review--daily-goal-reached-p)
                 (lambda ()
                   (prog1 (car goal-states)
                     (setq goal-states (cdr goal-states)))))
                ((symbol-function 'decklite-rate-card)
                 (lambda (word grade)
                   (setq rated (list word grade))))
                ((symbol-function 'decklite-review-next-card)
                 (lambda ()
                   (setq next-count (1+ next-count)))))
        (decklite-review--handle-grade 3)))
    (should (equal rated '("goal-word" 3)))
    (should (= 1 hook-count))
    (should (= 1 next-count))))

(ert-deftest decklite-test-review-handle-grade-does-not-trigger-hook-without-transition ()
  (let ((decklite-current-word "steady-word")
        (hook-count 0)
        ;; reached before and after rating -> no transition
        (goal-states '(t t)))
    (let ((decklite-review-daily-goal-reached-hook
           (list (lambda () (setq hook-count (1+ hook-count))))))
      (cl-letf (((symbol-function 'decklite-review--daily-goal-reached-p)
                 (lambda ()
                   (prog1 (car goal-states)
                     (setq goal-states (cdr goal-states)))))
                ((symbol-function 'decklite-rate-card) (lambda (&rest _) nil))
                ((symbol-function 'decklite-review-next-card) (lambda () nil)))
        (decklite-review--handle-grade 1)))
    (should (= 0 hook-count))))

;; ---------------------------------------------------------------------------
;; Review flow: next-card sequencing and hook execution
;; ---------------------------------------------------------------------------
;; Ensures `decklite-review-next-card` consumes queue state in order and runs
;; next-card hook once per transition.

(ert-deftest decklite-test-review-next-card-consumes-due-queue-and-runs-hook ()
  (let ((decklite-due-words '("w1" "w2"))
        (decklite-current-word nil)
        (hook-count 0))
    (let ((decklite-review-next-card-hook
           (list (lambda () (setq hook-count (1+ hook-count))))))
      (cl-letf (((symbol-function 'decklite-review--reset-ui-state) (lambda () nil))
                ((symbol-function 'decklite-review--render-buffer) (lambda (&rest _) nil))
                ((symbol-function 'decklite-review-quit) (lambda () nil)))
        (decklite-review-next-card)))
    (should (equal decklite-current-word "w1"))
    (should (equal decklite-due-words '("w2")))
    (should (= 1 hook-count))))

;; ---------------------------------------------------------------------------
;; Edit flow: batch operations and delegation branches
;; ---------------------------------------------------------------------------
;; These tests verify branch behavior in `decklite-edit-delete` and
;; `decklite-edit-archive` without requiring tabulated-list UI setup.

(ert-deftest decklite-test-edit-delete-marked-branch-runs-batch-delete ()
  (let ((deleted '())
         (ensured nil)
         (cleared nil)
         (refreshed nil)
         (restored nil))
    (cl-letf (((symbol-function 'decklite-edit--marked-words)
               (lambda () '("a" "b")))
              ((symbol-function 'decklite-edit--nearest-surviving-word)
               (lambda (_words) "next-word"))
              ((symbol-function 'count-screen-lines)
               (lambda (&rest _) 7))
              ((symbol-function 'decklite-edit--ensure-not-current)
               (lambda (words) (setq ensured words)))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'decklite-delete-card)
               (lambda (word) (push word deleted)))
              ((symbol-function 'decklite-edit--clear-marks)
               (lambda () (setq cleared t)))
              ((symbol-function 'decklite-edit-refresh)
               (lambda () (setq refreshed t)))
              ((symbol-function 'decklite-edit--line-of-word)
               (lambda (word)
                 (when (string= word "next-word")
                   5)))
              ((symbol-function 'decklite-edit--restore-position)
               (lambda (line win-line)
                 (setq restored (list line win-line))))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (decklite-edit-delete))
    (should (equal ensured '("a" "b")))
    (should (equal (sort deleted #'string<) '("a" "b")))
    (should cleared)
    (should refreshed)
    (should (equal restored '(5 7)))))

(ert-deftest decklite-test-edit-nearest-surviving-word-prefers-forward-on-tie ()
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
      (should (string= (decklite-edit--nearest-surviving-word '("c")) "d"))
      (should (string= (decklite-edit--nearest-surviving-word '("b" "c")) "d")))))

(ert-deftest decklite-test-edit-delete-without-marks-delegates-to-single-delete ()
  (let ((delegated nil))
    (cl-letf (((symbol-function 'decklite-edit--marked-words) (lambda () nil))
              ((symbol-function 'decklite-edit-delete-card)
               (lambda () (setq delegated t))))
      (decklite-edit-delete))
    (should delegated)))

(ert-deftest decklite-test-edit-archive-uses-unarchive-in-archived-filter ()
  (let ((decklite-edit--filter 'archived)
         (unarchived nil)
         (archived nil))
    (cl-letf (((symbol-function 'decklite-edit--marked-words) (lambda () nil))
              ((symbol-function 'decklite-edit-unarchive-card)
               (lambda () (setq unarchived t)))
              ((symbol-function 'decklite-edit-archive-card)
               (lambda () (setq archived t))))
      (decklite-edit-archive))
    (should unarchived)
    (should-not archived)))

(ert-deftest decklite-test-edit-archive-marked-in-archived-filter-unarchives-and-restores ()
  (let ((decklite-edit--filter 'archived)
        (unarchived '())
        (archived nil)
        (ensured nil)
        (cleared nil)
        (refreshed nil)
        (restored nil))
    (cl-letf (((symbol-function 'decklite-edit--marked-words)
               (lambda () '("a" "b")))
              ((symbol-function 'decklite-edit--nearest-surviving-word)
               (lambda (_words) "next-word"))
              ((symbol-function 'count-screen-lines)
               (lambda (&rest _) 6))
              ((symbol-function 'decklite-edit--ensure-not-current)
               (lambda (words) (setq ensured words)))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'decklite-unarchive-card)
               (lambda (word) (push word unarchived)))
              ((symbol-function 'decklite-archive-card)
               (lambda (&rest _) (setq archived t)))
              ((symbol-function 'decklite-edit--clear-marks)
               (lambda () (setq cleared t)))
              ((symbol-function 'decklite-edit-refresh)
               (lambda () (setq refreshed t)))
              ((symbol-function 'decklite-edit--line-of-word)
               (lambda (word)
                 (when (string= word "next-word")
                   4)))
              ((symbol-function 'decklite-edit--restore-position)
               (lambda (line win-line)
                 (setq restored (list line win-line))))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (decklite-edit-archive))
    (should (equal ensured '("a" "b")))
    (should (equal (sort unarchived #'string<) '("a" "b")))
    (should-not archived)
    (should cleared)
    (should refreshed)
    (should (equal restored '(4 6)))))

(ert-deftest decklite-test-edit-archive-marked-in-all-filter-archives-and-restores ()
  (let ((decklite-edit--filter 'all)
        (unarchived nil)
        (archived '())
        (ensured nil)
        (cleared nil)
        (refreshed nil)
        (restored nil))
    (cl-letf (((symbol-function 'decklite-edit--marked-words)
               (lambda () '("a" "b")))
              ((symbol-function 'decklite-edit--nearest-surviving-word)
               (lambda (_words) "next-word"))
              ((symbol-function 'count-screen-lines)
               (lambda (&rest _) 8))
              ((symbol-function 'decklite-edit--ensure-not-current)
               (lambda (words) (setq ensured words)))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'decklite-unarchive-card)
               (lambda (&rest _) (setq unarchived t)))
              ((symbol-function 'decklite-archive-card)
               (lambda (word) (push word archived)))
              ((symbol-function 'decklite-edit--clear-marks)
               (lambda () (setq cleared t)))
              ((symbol-function 'decklite-edit-refresh)
               (lambda () (setq refreshed t)))
              ((symbol-function 'decklite-edit--line-of-word)
               (lambda (word)
                 (when (string= word "next-word")
                   6)))
              ((symbol-function 'decklite-edit--restore-position)
               (lambda (line win-line)
                 (setq restored (list line win-line))))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (decklite-edit-archive))
    (should (equal ensured '("a" "b")))
    (should (equal (sort archived #'string<) '("a" "b")))
    (should-not unarchived)
    (should cleared)
    (should refreshed)
    (should (equal restored '(6 8)))))

(ert-deftest decklite-test-edit-delete-marked-without-survivor-skips-restore ()
  (let ((restored nil))
    (cl-letf (((symbol-function 'decklite-edit--marked-words)
               (lambda () '("a" "b")))
              ((symbol-function 'decklite-edit--nearest-surviving-word)
               (lambda (_words) nil))
              ((symbol-function 'count-screen-lines)
               (lambda (&rest _) 3))
              ((symbol-function 'decklite-edit--ensure-not-current)
               (lambda (&rest _) nil))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'decklite-delete-card)
               (lambda (&rest _) nil))
              ((symbol-function 'decklite-edit--clear-marks)
               (lambda () nil))
              ((symbol-function 'decklite-edit-refresh)
               (lambda () nil))
              ((symbol-function 'decklite-edit--line-of-word)
               (lambda (_word) nil))
              ((symbol-function 'decklite-edit--restore-position)
               (lambda (&rest _) (setq restored t)))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (decklite-edit-delete))
    (should-not restored)))

(ert-deftest decklite-test-edit-delete-marked-cancelled-skips-side-effects ()
  (let ((deleted nil)
        (cleared nil)
        (refreshed nil)
        (restored nil)
        (ensured nil))
    (cl-letf (((symbol-function 'decklite-edit--marked-words)
               (lambda () '("a" "b")))
              ((symbol-function 'decklite-edit--nearest-surviving-word)
               (lambda (_words) "next-word"))
              ((symbol-function 'count-screen-lines)
               (lambda (&rest _) 5))
              ((symbol-function 'decklite-edit--ensure-not-current)
               (lambda (words) (setq ensured words)))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
              ((symbol-function 'decklite-delete-card)
               (lambda (&rest _) (setq deleted t)))
              ((symbol-function 'decklite-edit--clear-marks)
               (lambda () (setq cleared t)))
              ((symbol-function 'decklite-edit-refresh)
               (lambda () (setq refreshed t)))
              ((symbol-function 'decklite-edit--line-of-word)
               (lambda (&rest _) 3))
              ((symbol-function 'decklite-edit--restore-position)
               (lambda (&rest _) (setq restored t)))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (decklite-edit-delete))
    (should (equal ensured '("a" "b")))
    (should-not deleted)
    (should-not cleared)
    (should-not refreshed)
    (should-not restored)))

(ert-deftest decklite-test-edit-archive-marked-cancelled-skips-side-effects ()
  (let ((decklite-edit--filter 'all)
        (archived nil)
        (unarchived nil)
        (cleared nil)
        (refreshed nil)
        (restored nil)
        (ensured nil))
    (cl-letf (((symbol-function 'decklite-edit--marked-words)
               (lambda () '("a" "b")))
              ((symbol-function 'decklite-edit--nearest-surviving-word)
               (lambda (_words) "next-word"))
              ((symbol-function 'count-screen-lines)
               (lambda (&rest _) 5))
              ((symbol-function 'decklite-edit--ensure-not-current)
               (lambda (words) (setq ensured words)))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
              ((symbol-function 'decklite-archive-card)
               (lambda (&rest _) (setq archived t)))
              ((symbol-function 'decklite-unarchive-card)
               (lambda (&rest _) (setq unarchived t)))
              ((symbol-function 'decklite-edit--clear-marks)
               (lambda () (setq cleared t)))
              ((symbol-function 'decklite-edit-refresh)
               (lambda () (setq refreshed t)))
              ((symbol-function 'decklite-edit--line-of-word)
               (lambda (&rest _) 3))
              ((symbol-function 'decklite-edit--restore-position)
               (lambda (&rest _) (setq restored t)))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (decklite-edit-archive))
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

(ert-deftest decklite-test-review-collect-component-items-collapses-separators ()
  (cl-letf (((symbol-function 'decklite-review-component-separator)
             (lambda () "SEP"))
            ((symbol-function 'decklite-test--component-a)
             (lambda () "A"))
            ((symbol-function 'decklite-test--component-b)
             (lambda () "B")))
    (let* ((result (decklite-review--collect-component-items
                    '(decklite-review-component-separator
                      decklite-test--component-a
                      decklite-review-component-separator
                      decklite-review-component-separator
                      decklite-test--component-b)))
           (items (car result)))
      ;; Leading separator should be skipped.
      ;; Consecutive separators should collapse into one.
      (should (equal (mapcar #'car items) '("A" "SEP" "B")))
      (should (equal (mapcar #'cdr items) '(nil t nil))))))

;; ---------------------------------------------------------------------------
;; Hint timer state machine
;; ---------------------------------------------------------------------------
;; `decklite-review--start-hint-timer' should not schedule multiple timers.

(ert-deftest decklite-test-review-start-hint-timer-is-idempotent ()
  (let ((decklite-review--hint-timer nil)
        (calls 0)
        (decklite-review-hint-delay 0.1))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (&rest _)
                 (setq calls (1+ calls))
                 'fake-timer)))
      (decklite-review--start-hint-timer)
      (decklite-review--start-hint-timer))
    (should (= calls 1))
    (should (eq decklite-review--hint-timer 'fake-timer))))

;; ---------------------------------------------------------------------------
;; Calendar-facing DB aggregation
;; ---------------------------------------------------------------------------
;; Keep this at DB layer: verify overdue and in-range due counts are split
;; correctly for `decklite-db--due-counts-by-date'.

(ert-deftest decklite-test-db-due-counts-by-date-splits-overdue-and-range ()
  (decklite-test--with-temp-db
    (let* ((now (current-time))
           (day-start (decklite--day-start-time now))
           (cutoff (decklite--next-day-start-time now))
           (overdue-time (time-subtract day-start (seconds-to-time 60)))
           (in-range-time (time-add day-start (seconds-to-time 3600)))
           (ts-added (decklite-test--ts (time-subtract now (seconds-to-time 7200))))
           (ts-last (decklite-test--ts (time-subtract now (seconds-to-time 1800)))))
      ;; Overdue reviewed card.
      (decklite-db--upsert-card
       "overdue-card"
       (decklite-test--make-meta
        :added-date ts-added
        :last-review ts-last
        :due (decklite-test--ts overdue-time)
        :state :review))
      ;; Due in current [day-start, cutoff) window.
      (decklite-db--upsert-card
       "range-card"
       (decklite-test--make-meta
        :added-date ts-added
        :last-review ts-last
        :due (decklite-test--ts in-range-time)
        :state :review))
      (let* ((result (decklite-db--due-counts-by-date day-start cutoff))
             (rows (plist-get result :rows))
             (overdue (plist-get result :overdue))
             (in-range-count (apply #'+ (mapcar #'cadr rows))))
        (should (= overdue 1))
        (should (= in-range-count 1))))))

(provide 'decklite-test)
;;; decklite-test.el ends here

;;; decklet-review-test.el --- Tests for decklet-review.el -*- lexical-binding: t; -*-

(require 'decklet-test-helpers)

;; ---------------------------------------------------------------------------
;; Review flow: grade handling and hook transitions
;; ---------------------------------------------------------------------------
;; These tests focus on the central grade handler used by 1/2/3/4 commands.
;; We explicitly mock side-effect functions (`decklet-rate-card',
;; `decklet-review-next-card') so we can verify behavior without UI coupling.

(ert-deftest decklet-test-review-handle-grade-triggers-daily-goal-hook-on-transition ()
  (let ((decklet-current-word "goal-word")
        (decklet-review--trail nil)
        (decklet-review--trail-pointer 0)
        (hook-count 0)
        (rated nil)
        (advance-count 0)
        ;; First check: before rating -> not reached.
        ;; Second check: after rating -> reached.
        (goal-states '(nil t)))
    (let ((decklet-review-daily-goal-reached-hook
           (list (lambda () (setq hook-count (1+ hook-count))))))
      (cl-letf (((symbol-function 'decklet-review--daily-goal-reached-p)
                 (lambda ()
                   (prog1 (car goal-states)
                     (setq goal-states (cdr goal-states)))))
                ((symbol-function 'decklet-get-card-meta)
                 (lambda (_w) (make-decklet-card-meta)))
                ((symbol-function 'decklet-rate-card)
                 (lambda (word grade)
                   (setq rated (list word grade))))
                ((symbol-function 'decklet-review--advance)
                 (lambda ()
                   (setq advance-count (1+ advance-count)))))
        (decklet-review--handle-grade 3)))
    (should (equal rated '("goal-word" 3)))
    (should (= 1 hook-count))
    (should (= 1 advance-count))))

(ert-deftest decklet-test-review-handle-grade-does-not-trigger-hook-without-transition ()
  (let ((decklet-current-word "steady-word")
        (decklet-review--trail nil)
        (decklet-review--trail-pointer 0)
        (hook-count 0)
        ;; reached before and after rating -> no transition
        (goal-states '(t t)))
    (let ((decklet-review-daily-goal-reached-hook
           (list (lambda () (setq hook-count (1+ hook-count))))))
      (cl-letf (((symbol-function 'decklet-review--daily-goal-reached-p)
                 (lambda ()
                   (prog1 (car goal-states)
                     (setq goal-states (cdr goal-states)))))
                ((symbol-function 'decklet-get-card-meta)
                 (lambda (_w) (make-decklet-card-meta)))
                ((symbol-function 'decklet-rate-card) (lambda (&rest _) nil))
                ((symbol-function 'decklet-review--advance) (lambda () nil)))
        (decklet-review--handle-grade 1)))
    (should (= 0 hook-count))))

;; ---------------------------------------------------------------------------
;; Review flow: next-card sequencing and hook execution
;; ---------------------------------------------------------------------------
;; Ensures `decklet-review-next-card' consumes queue state in order and runs
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
;; Review rendering internals (lightweight, no window coupling)
;; ---------------------------------------------------------------------------
;; We only test the pure list-assembly behavior here.  This protects the
;; separator-collapse rule without requiring full buffer rendering.

(ert-deftest decklet-test-review-collect-component-items-collapses-separators ()
  (cl-letf (((symbol-function 'decklet-test--component-a)
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
      ;; Separator items store a placeholder for later replacement by the renderer.
      (should (equal (mapcar #'car items) '("A" "" "B")))
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
;; Undo: log and pointer
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-undo-log-entry-on-grade ()
  "Rating a card appends a log entry with pre-meta and grade."
  (let ((decklet-current-word "apple")
        (decklet-review--trail nil)
        (decklet-review--trail-pointer 0)
        (pre (make-decklet-card-meta :state :learning :step 0)))
    (cl-letf (((symbol-function 'decklet-review--daily-goal-reached-p)
               (lambda () nil))
              ((symbol-function 'decklet-get-card-meta)
               (lambda (_word) (copy-decklet-card-meta pre)))
              ((symbol-function 'decklet-rate-card) (lambda (&rest _) nil))
              ((symbol-function 'decklet-review--advance)
               (lambda () nil)))
      (decklet-review--handle-grade 3))
    (should (= 1 (length decklet-review--trail)))
    (should (= 1 decklet-review--trail-pointer))
    (let ((entry (nth 0 decklet-review--trail)))
      (should (equal "apple" (plist-get entry :word)))
      (should (= 3 (plist-get entry :grade)))
      (should (plist-get entry :pre-meta)))))

(ert-deftest decklet-test-review-undo-log-entry-on-skip ()
  "Skipping a card appends a log entry with nil grade."
  (let ((decklet-current-word "banana")
        (decklet-due-words '("cherry"))
        (decklet-review--trail nil)
        (decklet-review--trail-pointer 0)
        (meta (make-decklet-card-meta :state :learning)))
    (cl-letf (((symbol-function 'decklet-get-card-meta)
               (lambda (_word) (copy-decklet-card-meta meta)))
              ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
              ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil))
              ((symbol-function 'run-hooks) (lambda (&rest _) nil)))
      (decklet-review-next-card))
    (should (= 1 (length decklet-review--trail)))
    (let ((entry (nth 0 decklet-review--trail)))
      (should (equal "banana" (plist-get entry :word)))
      (should (null (plist-get entry :grade)))
      (should (plist-get entry :pre-meta)))))

(ert-deftest decklet-test-review-undo-decrements-pointer-and-navigates ()
  "Undo decrements pointer, pushes current card back, does not write to DB."
  (let* ((pre (make-decklet-card-meta :state :learning :step 0))
         (decklet-review--trail
          (list (list :word "date"
                               :grade 3
                               :pre-meta pre)))
         (decklet-review--trail-pointer 1)
         (decklet-current-word "elderberry")
         (decklet-due-words '("fig"))
         (upserted nil))
    (cl-letf (((symbol-function 'decklet-db--select-card)
               (lambda (_word) '(:word "date")))
              ((symbol-function 'decklet-db--upsert-card)
               (lambda (word meta) (setq upserted (list word meta))))
              ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
              ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil)))
      (decklet-review-undo))
    (should (= 0 decklet-review--trail-pointer))
    ;; Undo should NOT write to DB.
    (should (null upserted))
    (should (equal "date" decklet-current-word))
    ;; The interrupted card should be pushed back to the front of due-words.
    (should (equal '("elderberry" "fig") decklet-due-words))))

(ert-deftest decklet-test-review-undo-empty-log ()
  "Undo on empty log messages without error."
  (let ((decklet-review--trail nil)
        (decklet-review--trail-pointer 0)
        (msg nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest _) (setq msg fmt))))
      (decklet-review-undo))
    (should (string-match-p "Nothing to undo" msg))))

(ert-deftest decklet-test-review-undo-multiple-walks-backward ()
  "Multiple undos walk backward through the log."
  (let* ((entries (mapcar (lambda (w)
                            (list :word w :grade 3
                                  :pre-meta (make-decklet-card-meta)))
                          '("A" "B" "C")))
         (decklet-review--trail entries)
         (decklet-review--trail-pointer 3)
         (decklet-current-word "D")
         (words-seen nil))
    (cl-letf (((symbol-function 'decklet-db--select-card)
               (lambda (_word) '(:word "x")))
              ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
              ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil)))
      (dotimes (_ 3)
        (decklet-review-undo)
        (push decklet-current-word words-seen)))
    (should (equal '("A" "B" "C") words-seen))
    (should (= 0 decklet-review--trail-pointer))))

;; ---------------------------------------------------------------------------
;; Undo: confirm and re-rate
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-undo-confirm-rated-advances-pointer ()
  "Confirming an undone rated card advances pointer without DB write."
  (let* ((pre (make-decklet-card-meta :state :learning))
         (decklet-review--trail
          (list (list :word "fig" :grade 3
                               :pre-meta pre)))
         (decklet-review--trail-pointer 0)
         (decklet-current-word "fig")
         (decklet-due-words '("grape"))
         (upserted nil))
    (cl-letf (((symbol-function 'decklet-db--upsert-card)
               (lambda (word meta) (setq upserted (list word meta))))
              ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
              ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil))
              ((symbol-function 'run-hooks) (lambda (&rest _) nil)))
      (decklet-review-next-card))
    ;; Confirm should NOT write to DB.
    (should (null upserted))
    (should (= 1 decklet-review--trail-pointer))))

(ert-deftest decklet-test-review-undo-confirm-skipped-no-db-write ()
  "Confirming an undone skipped card does not write to DB."
  (let* ((pre (make-decklet-card-meta :state :learning))
         (decklet-review--trail
          (list (list :word "honey" :grade nil
                               :pre-meta pre)))
         (decklet-review--trail-pointer 0)
         (decklet-current-word "honey")
         (decklet-due-words '("ice"))
         (upserted nil))
    (cl-letf (((symbol-function 'decklet-db--upsert-card)
               (lambda (word meta) (setq upserted (list word meta))))
              ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
              ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil))
              ((symbol-function 'run-hooks) (lambda (&rest _) nil)))
      (decklet-review-next-card))
    (should (null upserted))
    (should (= 1 decklet-review--trail-pointer))))

(ert-deftest decklet-test-review-undo-rerate-restores-pre-meta-and-updates-grade ()
  "Re-rating an undone card restores pre-meta to DB then rates."
  (let* ((pre (make-decklet-card-meta :state :learning :step 0))
         (decklet-review--trail
          (list (list :word "jelly" :grade 3
                               :pre-meta pre)))
         (decklet-review--trail-pointer 0)
          (decklet-current-word "jelly")
         (upserted nil)
         (rated nil))
    (cl-letf (((symbol-function 'decklet-review--daily-goal-reached-p)
               (lambda () nil))
              ((symbol-function 'decklet-db--upsert-card)
               (lambda (word meta) (setq upserted (list word meta))))
              ((symbol-function 'decklet-rate-card)
               (lambda (word grade &optional prior-grade)
                 (setq rated (list word grade prior-grade))))
              ((symbol-function 'decklet-review--advance)
               (lambda () nil)))
      (decklet-review--handle-grade 1))
    (should (= 1 decklet-review--trail-pointer))
    ;; Pre-meta should have been written to DB before rating.
    (should (equal "jelly" (car upserted)))
    (should (equal pre (cadr upserted)))
    ;; Then rate-card was called with the new grade and the replaced
    ;; grade forwarded as PRIOR-GRADE.
    (should (equal '("jelly" 1 3) rated))
    (let ((entry (nth 0 decklet-review--trail)))
      (should (= 1 (plist-get entry :grade))))))

(ert-deftest decklet-test-review-undo-pointer-catches-up-resumes-forward ()
  "When pointer catches up to log end, next-card pops from due-words."
  (let* ((decklet-review--trail (list (list :word "x" :grade 3
                                                         :pre-meta (make-decklet-card-meta))))
         (decklet-review--trail-pointer 1)
          (decklet-current-word "x")
         (decklet-due-words '("kiwi")))
    (cl-letf (((symbol-function 'decklet-get-card-meta)
               (lambda (_w) (make-decklet-card-meta)))
              ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
              ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil))
              ((symbol-function 'run-hooks) (lambda (&rest _) nil)))
      (decklet-review-next-card))
    (should (equal "kiwi" decklet-current-word))
    ;; Skip was logged for "x"
    (should (= 2 (length decklet-review--trail)))))

(ert-deftest decklet-test-review-undo-confirm-then-resume-no-double-skip ()
  "After confirming the last undone card, forward flow resumes correctly.
The confirmed card must not be double-logged as a skip."
  (let* ((pre (make-decklet-card-meta :state :learning))
         ;; Log has one rated entry; pointer is at 0 (undone).
         (decklet-review--trail
          (list (list :word "A" :grade 3
                               :pre-meta pre)))
         (decklet-review--trail-pointer 0)
          (decklet-current-word "A")
         ;; B is waiting in the queue (was pushed back by undo).
         (decklet-due-words '("B")))
    (cl-letf (((symbol-function 'decklet--refresh-due-words) (lambda () nil))
              ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
              ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil))
              ((symbol-function 'run-hooks) (lambda (&rest _) nil)))
      (decklet-review-next-card))
    ;; Pointer should have advanced past the log.
    (should (= 1 decklet-review--trail-pointer))
    ;; Current word should be B (popped from due-words), not C.
    (should (equal "B" decklet-current-word))
    ;; Log should still have exactly 1 entry — no spurious skip appended.
    (should (= 1 (length decklet-review--trail)))))

(ert-deftest decklet-test-review-undo-pushes-current-card-to-due-words ()
  "Undoing from normal flow pushes the current card back to due-words."
  (let* ((pre (make-decklet-card-meta :state :learning))
         (decklet-review--trail
          (list (list :word "A" :grade 3
                               :pre-meta pre)))
         (decklet-review--trail-pointer 1)
         (decklet-current-word "B")
         (decklet-due-words '("C")))
    (cl-letf (((symbol-function 'decklet-db--select-card)
               (lambda (_word) '(:word "A")))
              ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
              ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil)))
      (decklet-review-undo))
    (should (equal "A" decklet-current-word))
    ;; B was pushed back to the front of due-words.
    (should (equal '("B" "C") decklet-due-words))))

(ert-deftest decklet-test-review-undo-in-undo-state-does-not-push-to-queue ()
  "Undoing while already in undo state does not push the current card."
  (let* ((entries (mapcar (lambda (w)
                            (list :word w :grade 3
                                  :pre-meta (make-decklet-card-meta)))
                          '("A" "B")))
         (decklet-review--trail entries)
         (decklet-review--trail-pointer 1)
         (decklet-current-word "B")
         (decklet-due-words '("C")))
    (cl-letf (((symbol-function 'decklet-db--select-card)
               (lambda (_word) '(:word "x")))
              ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
              ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil)))
      (decklet-review-undo))
    (should (equal "A" decklet-current-word))
    ;; B is in the log at pointer 1, not pushed to due-words.
    (should (equal '("C") decklet-due-words))))

(ert-deftest decklet-test-review-undo-rate-after-undo-does-not-duplicate-log ()
  "Rating a card after undoing to it updates the entry, not appends."
  (let* ((pre (make-decklet-card-meta :state :learning))
         (decklet-review--trail
          (list (list :word "A" :grade nil
                               :pre-meta pre)))
         (decklet-review--trail-pointer 0)
          (decklet-current-word "A"))
    (cl-letf (((symbol-function 'decklet-review--daily-goal-reached-p)
               (lambda () nil))
              ((symbol-function 'decklet-db--upsert-card) (lambda (&rest _) nil))
              ((symbol-function 'decklet-rate-card) (lambda (&rest _) nil))
              ((symbol-function 'decklet-review--advance)
               (lambda () nil)))
      (decklet-review--handle-grade 1))
    ;; Log should still have exactly 1 entry, updated in-place.
    (should (= 1 (length decklet-review--trail)))
    (should (= 1 (plist-get (nth 0 decklet-review--trail) :grade)))))

;; ---------------------------------------------------------------------------
;; Undo: trail reset
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-trail-reset-clears-state ()
  "Reset clears the trail and pointer."
  (let ((decklet-review--trail
         (list (list :word "a" :grade 3
                     :pre-meta (make-decklet-card-meta))))
        (decklet-review--trail-pointer 0))
    (decklet-review--trail-reset)
    (should (null decklet-review--trail))
    (should (= 0 decklet-review--trail-pointer))))

;; ---------------------------------------------------------------------------
;; Undo: rename and delete integration
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-undo-rename-updates-log ()
  "Renaming a word updates :word in all matching log entries."
  (let ((decklet-review--trail
         (list (list :word "old" :grade 3
                              :pre-meta (make-decklet-card-meta))
                        (list :word "other" :grade 2
                              :pre-meta (make-decklet-card-meta))
                        (list :word "old" :grade 1
                              :pre-meta (make-decklet-card-meta))))
        (decklet-review--trail-pointer 3))
    (decklet-review--trail-rename "old" "new")
    (should (equal "new" (plist-get (nth 0 decklet-review--trail) :word)))
    (should (equal "other" (plist-get (nth 1 decklet-review--trail) :word)))
    (should (equal "new" (plist-get (nth 2 decklet-review--trail) :word)))))

(ert-deftest decklet-test-review-undo-delete-removes-entries-adjusts-pointer ()
  "Deleting a word removes its log entries and adjusts the pointer."
  (let ((decklet-review--trail
         (list (list :word "A" :grade 3
                              :pre-meta (make-decklet-card-meta))
                        (list :word "B" :grade 2
                              :pre-meta (make-decklet-card-meta))
                        (list :word "C" :grade 1
                              :pre-meta (make-decklet-card-meta))))
        (decklet-review--trail-pointer 3))
    (decklet-review--trail-delete "B")
    (should (= 2 (length decklet-review--trail)))
    (should (equal "A" (plist-get (nth 0 decklet-review--trail) :word)))
    (should (equal "C" (plist-get (nth 1 decklet-review--trail) :word)))
    (should (= 2 decklet-review--trail-pointer))))

(ert-deftest decklet-test-review-undo-delete-before-pointer-adjusts ()
  "Deleting an entry before the pointer decrements it."
  (let ((decklet-review--trail
         (list (list :word "A" :grade 3
                              :pre-meta (make-decklet-card-meta))
                        (list :word "B" :grade 2
                              :pre-meta (make-decklet-card-meta))
                        (list :word "C" :grade 1
                              :pre-meta (make-decklet-card-meta))))
        (decklet-review--trail-pointer 1))
    (decklet-review--trail-delete "A")
    (should (= 2 (length decklet-review--trail)))
    (should (= 0 decklet-review--trail-pointer))
    (should (equal "B" (plist-get (nth 0 decklet-review--trail) :word)))))

(ert-deftest decklet-test-review-undo-delete-at-pointer ()
  "Deleting the entry at the current pointer adjusts gracefully."
  (let ((decklet-review--trail
         (list (list :word "A" :grade 3
                              :pre-meta (make-decklet-card-meta))
                        (list :word "B" :grade 2
                              :pre-meta (make-decklet-card-meta))
                        (list :word "C" :grade 1
                              :pre-meta (make-decklet-card-meta))))
        (decklet-review--trail-pointer 2))
    (decklet-review--trail-delete "C")
    (should (= 2 (length decklet-review--trail)))
    ;; Pointer should be clamped to log length (no longer in undo state)
    (should (= 2 decklet-review--trail-pointer))))

;; ---------------------------------------------------------------------------
;; Undo: rendering
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-undo-highlight-on-rated-card ()
  "The previous grade is highlighted when reviewing an undone rated card."
  (let* ((meta (make-decklet-card-meta :state :review :last-review "2025-01-01T00:00:00Z"))
         (decklet-review--trail
          (list (list :word "plum" :grade 3
                               :pre-meta meta)))
         (decklet-review--trail-pointer 0)
         (decklet-current-word "plum")
         (decklet-review--render-meta meta)
         (decklet-review-enable-interval-labels nil))
    (let ((output (decklet-review-component-rates)))
      ;; "Good" option should have the undo highlight face
      (should (text-property-not-all 0 (length output)
                                     'face nil output))
      ;; Check that undo highlight face appears in the output
      (let ((found nil))
        (dotimes (i (length output))
          (when (eq (get-text-property i 'face output)
                    'decklet-review-undo-highlight-face)
            (setq found t)))
        (should found)))))

(ert-deftest decklet-test-review-undo-no-highlight-in-normal-flow ()
  "No undo highlight face appears during normal forward review."
  (let* ((meta (make-decklet-card-meta :state :review :last-review "2025-01-01T00:00:00Z"))
         (decklet-review--trail nil)
         (decklet-review--trail-pointer 0)
         (decklet-current-word "quince")
         (decklet-review--render-meta meta)
         (decklet-review-enable-interval-labels nil))
    (let ((output (decklet-review-component-rates)))
      (let ((found nil))
        (dotimes (i (length output))
          (when (eq (get-text-property i 'face output)
                    'decklet-review-undo-highlight-face)
            (setq found t)))
        (should-not found)))))

(ert-deftest decklet-test-review-undo-no-highlight-on-skipped-card ()
  "No highlight face on an undone skipped card."
  (let* ((meta (make-decklet-card-meta :state :learning))
         (decklet-review--trail
          (list (list :word "raisin" :grade nil
                               :pre-meta meta)))
         (decklet-review--trail-pointer 0)
         (decklet-current-word "raisin")
         (decklet-review--render-meta meta)
         (decklet-review-enable-interval-labels nil))
    (let ((output (decklet-review-component-rates)))
      (let ((found nil))
        (dotimes (i (length output))
          (when (eq (get-text-property i 'face output)
                    'decklet-review-undo-highlight-face)
            (setq found t)))
        (should-not found)))))

;; ---------------------------------------------------------------------------
;; Undo: cleanup
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-undo-cleanup-clears-state ()
  "Session cleanup clears the trail and pointer."
  (let ((decklet-review--trail (list (list :word "x" :grade 1
                                                        :pre-meta (make-decklet-card-meta))))
        (decklet-review--trail-pointer 0)
        (decklet-review--hint-timer nil)
        (decklet-review--state-display-hint nil)
        (decklet-current-word "x")
        (decklet-last-added-word nil)
        (decklet-due-words nil))
    (decklet-review--clean-up)
    (should (null decklet-review--trail))
    (should (= 0 decklet-review--trail-pointer))))

;; ---------------------------------------------------------------------------
;; Undo: skip not logged during undo confirm
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-undo-skip-not-logged-on-confirm ()
  "Confirming an undone card via `n' does not append a new log entry."
  (let* ((pre (make-decklet-card-meta :state :learning))
         (decklet-review--trail
          (list (list :word "star" :grade 3
                               :pre-meta pre)))
         (decklet-review--trail-pointer 0)
          (decklet-current-word "star")
         (decklet-due-words '("sun")))
    (cl-letf (((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
              ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil))
              ((symbol-function 'run-hooks) (lambda (&rest _) nil)))
      (decklet-review-next-card))
    ;; Log should still have exactly 1 entry, not 2
    (should (= 1 (length decklet-review--trail)))))

;; ---------------------------------------------------------------------------
;; Undo: undo skips deleted cards
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-undo-skips-deleted-card ()
  "Undo skips entries whose card no longer exists and continues backward."
  (let* ((entries (mapcar (lambda (w)
                            (list :word w :grade 3
                                  :pre-meta (make-decklet-card-meta)))
                          '("A" "B")))
         (decklet-review--trail entries)
         (decklet-review--trail-pointer 2)
         (decklet-current-word "C")
         (decklet-due-words nil))
    ;; B is gone from DB, A exists.
    (cl-letf (((symbol-function 'decklet-db--select-card)
               (lambda (word) (when (equal word "A") '(:word "A"))))
              ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
              ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil)))
      (decklet-review-undo))
    ;; Should have skipped B and landed on A.
    (should (equal "A" decklet-current-word))
    (should (= 0 decklet-review--trail-pointer))))

;; ---------------------------------------------------------------------------
;; Undo: cleanup clears state without DB writes
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-cleanup-clears-without-db-write ()
  "Session cleanup clears state without writing to DB."
  (let* ((decklet-review--trail
          (list (list :word "x" :grade 3
                      :pre-meta (make-decklet-card-meta))))
         (decklet-review--trail-pointer 0)
         (decklet-review--hint-timer nil)
         (decklet-review--state-display-hint nil)
         (decklet-current-word "x")
         (decklet-last-added-word nil)
         (decklet-due-words nil)
         (upserted nil))
    (cl-letf (((symbol-function 'decklet-db--upsert-card)
               (lambda (word meta) (push (list word meta) upserted))))
      (decklet-review--clean-up))
    ;; No DB writes should have occurred.
    (should (null upserted))
    ;; State should be cleared.
    (should (null decklet-review--trail))
    (should (= 0 decklet-review--trail-pointer))))

;; ---------------------------------------------------------------------------
;; Undo: highlight targets only the label text
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-undo-highlight-only-on-label ()
  "The highlight face applies to the label text only, not the key number."
  (let* ((meta (make-decklet-card-meta :state :review :last-review "2025-01-01T00:00:00Z"))
         (decklet-review--trail
          (list (list :word "plum" :grade 3
                      :pre-meta meta)))
         (decklet-review--trail-pointer 0)
         (decklet-current-word "plum")
         (decklet-review--render-meta meta)
         (decklet-review-enable-interval-labels nil))
    (let ((output (decklet-review-component-rates)))
      ;; Find where "Good" starts in the output.
      (let ((good-pos (string-match "Good" output)))
        (should good-pos)
        ;; The face at "Good" should be the highlight face.
        (should (eq (get-text-property good-pos 'face output)
                    'decklet-review-undo-highlight-face))
        ;; The character before "Good" (the space) should NOT have the face.
        (should-not (eq (get-text-property (1- good-pos) 'face output)
                        'decklet-review-undo-highlight-face))))))

(provide 'decklet-review-test)
;;; decklet-review-test.el ends here

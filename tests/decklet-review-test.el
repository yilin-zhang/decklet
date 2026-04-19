;;; decklet-review-test.el --- Tests for decklet-review.el -*- lexical-binding: t; -*-

(require 'decklet-test-helpers)

(defmacro decklet-test-review--with-card-words (pairs &rest body)
  "Run BODY with CARD-ID to word lookup stubbed from PAIRS."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'decklet-card-word)
              (lambda (card-id)
                (alist-get card-id ',pairs nil nil #'eql)))
             ((symbol-function 'decklet-card-exists-p)
              (lambda (card-id)
                (and (alist-get card-id ',pairs nil nil #'eql) t))))
     ,@body))

;; ---------------------------------------------------------------------------
;; Review flow: grade handling and hook transitions
;; ---------------------------------------------------------------------------
;; These tests focus on the central grade handler used by 1/2/3/4 commands.
;; We explicitly mock side-effect functions (`decklet-rate-card',
;; `decklet-review-next-card') so we can verify behavior without UI coupling.

(ert-deftest decklet-test-review-handle-grade-triggers-daily-goal-hook-on-transition ()
  (let ((decklet-current-card-id 1)
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
      (decklet-test-review--with-card-words ((1 . "goal-word"))
                                            (cl-letf (((symbol-function 'decklet-review--daily-goal-reached-p)
                                                       (lambda ()
                                                         (prog1 (car goal-states)
                                                           (setq goal-states (cdr goal-states)))))
                                                      ((symbol-function 'decklet-db--require-card-row)
                                                       (lambda (_id) '(:card-id 1 :word "goal-word")))
                                                      ((symbol-function 'decklet-db--row->card-meta)
                                                       (lambda (_row) (make-decklet-card-meta)))
                                                      ((symbol-function 'decklet--rate-card-state)
                                                       (lambda (card-id word old-meta grade &optional _prior-grade)
                                                         (ignore word old-meta)
                                                         (setq rated (list card-id grade))))
                                                      ((symbol-function 'decklet-review--advance)
                                                       (lambda ()
                                                         (setq advance-count (1+ advance-count)))))
                                              (decklet-review--handle-grade 3))))
    (should (equal rated '(1 3)))
    (should (= 1 hook-count))
    (should (= 1 advance-count))))

(ert-deftest decklet-test-review-handle-grade-does-not-trigger-hook-without-transition ()
  (let ((decklet-current-card-id 1)
        (decklet-review--trail nil)
        (decklet-review--trail-pointer 0)
        (hook-count 0)
        ;; reached before and after rating -> no transition
        (goal-states '(t t)))
    (let ((decklet-review-daily-goal-reached-hook
           (list (lambda () (setq hook-count (1+ hook-count))))))
      (decklet-test-review--with-card-words ((1 . "steady-word"))
                                            (cl-letf (((symbol-function 'decklet-review--daily-goal-reached-p)
                                                       (lambda ()
                                                         (prog1 (car goal-states)
                                                           (setq goal-states (cdr goal-states)))))
                                                      ((symbol-function 'decklet-db--require-card-row)
                                                       (lambda (_id) '(:card-id 1 :word "steady-word")))
                                                      ((symbol-function 'decklet-db--row->card-meta)
                                                       (lambda (_row) (make-decklet-card-meta)))
                                                      ((symbol-function 'decklet--rate-card-state) (lambda (&rest _) nil))
                                                      ((symbol-function 'decklet-review--advance) (lambda () nil)))
                                              (decklet-review--handle-grade 1))))
    (should (= 0 hook-count))))

;; ---------------------------------------------------------------------------
;; Review flow: next-card sequencing and hook execution
;; ---------------------------------------------------------------------------
;; Ensures `decklet-review-next-card' consumes queue state in order and runs
;; next-card hook once per transition.

(ert-deftest decklet-test-review-next-card-consumes-due-queue-and-runs-hook ()
  (let ((decklet-due-card-ids '(1 2))
        (decklet-current-card-id nil)
        (hook-count 0))
    (let ((decklet-review-next-card-hook
           (list (lambda () (setq hook-count (1+ hook-count))))))
      (decklet-test-review--with-card-words ((1 . "w1") (2 . "w2"))
                                            (cl-letf (((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
                                                      ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil))
                                                      ((symbol-function 'decklet-review-quit) (lambda () nil)))
                                              (decklet-review-next-card))))
    (should (= decklet-current-card-id 1))
    (should (equal decklet-due-card-ids '(2)))
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
  (let ((decklet-current-card-id 1)
        (decklet-review--trail nil)
        (decklet-review--trail-pointer 0)
        (pre (make-decklet-card-meta :state :learning :step 0)))
    (decklet-test-review--with-card-words ((1 . "apple"))
                                          (cl-letf (((symbol-function 'decklet-review--daily-goal-reached-p)
                                                     (lambda () nil))
                                                    ((symbol-function 'decklet-db--require-card-row)
                                                     (lambda (_id) '(:card-id 1 :word "apple")))
                                                    ((symbol-function 'decklet-db--row->card-meta)
                                                     (lambda (_row) (copy-decklet-card-meta pre)))
                                                    ((symbol-function 'decklet--rate-card-state) (lambda (&rest _) nil))
                                                    ((symbol-function 'decklet-review--advance)
                                                     (lambda () nil)))
                                            (decklet-review--handle-grade 3)))
    (should (= 1 (length decklet-review--trail)))
    (should (= 1 decklet-review--trail-pointer))
    (let ((entry (nth 0 decklet-review--trail)))
      (should (= 1 (plist-get entry :card-id)))
      (should (= 3 (plist-get entry :grade)))
      (should (plist-get entry :pre-meta)))))

(ert-deftest decklet-test-review-undo-log-entry-on-skip ()
  "Skipping a card appends a log entry with nil grade."
  (let ((decklet-current-card-id 1)
        (decklet-due-card-ids '(2))
        (decklet-review--trail nil)
        (decklet-review--trail-pointer 0)
        (meta (make-decklet-card-meta :state :learning)))
    (decklet-test-review--with-card-words ((1 . "banana") (2 . "cherry"))
                                          (cl-letf (((symbol-function 'decklet-get-card-meta)
                                                     (lambda (_id) (copy-decklet-card-meta meta)))
                                                    ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
                                                    ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil))
                                                    ((symbol-function 'run-hooks) (lambda (&rest _) nil)))
                                            (decklet-review-next-card)))
    (should (= 1 (length decklet-review--trail)))
    (let ((entry (nth 0 decklet-review--trail)))
      (should (= 1 (plist-get entry :card-id)))
      (should (null (plist-get entry :grade)))
      (should (plist-get entry :pre-meta)))))

(ert-deftest decklet-test-review-undo-decrements-pointer-and-navigates ()
  "Undo decrements pointer, pushes current card back, does not write to DB."
  (let* ((pre (make-decklet-card-meta :state :learning :step 0))
         (decklet-review--trail
          (list (list :card-id 1
                      :grade 3
                      :pre-meta pre)))
         (decklet-review--trail-pointer 1)
         (decklet-current-card-id 2)
         (decklet-due-card-ids '(3))
         (upserted nil))
    (decklet-test-review--with-card-words ((1 . "date") (2 . "elderberry") (3 . "fig"))
                                          (cl-letf (((symbol-function 'decklet-db--upsert-card)
                                                     (lambda (word meta) (setq upserted (list word meta))))
                                                    ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
                                                    ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil)))
                                            (decklet-review-undo)))
    (should (= 0 decklet-review--trail-pointer))
    (should (null upserted))
    (should (= 1 decklet-current-card-id))
    (should (equal '(2 3) decklet-due-card-ids))))

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
  (let* ((entries (mapcar (lambda (id)
                            (list :card-id id :grade 3
                                  :pre-meta (make-decklet-card-meta)))
                          '(1 2 3)))
         (decklet-review--trail entries)
         (decklet-review--trail-pointer 3)
         (decklet-current-card-id 4)
         (words-seen nil))
    (decklet-test-review--with-card-words ((1 . "A") (2 . "B") (3 . "C") (4 . "D"))
                                          (cl-letf (((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
                                                    ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil)))
                                            (dotimes (_ 3)
                                              (decklet-review-undo)
                                              (push (decklet-card-word decklet-current-card-id) words-seen))))
    (should (equal '("A" "B" "C") words-seen))
    (should (= 0 decklet-review--trail-pointer))))

;; ---------------------------------------------------------------------------
;; Undo: confirm and re-rate
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-undo-confirm-rated-advances-pointer ()
  "Confirming an undone rated card advances pointer without DB write."
  (let* ((pre (make-decklet-card-meta :state :learning))
         (decklet-review--trail
          (list (list :card-id 1 :grade 3
                      :pre-meta pre)))
         (decklet-review--trail-pointer 0)
         (decklet-current-card-id 1)
         (decklet-due-card-ids '(2))
         (upserted nil))
    (decklet-test-review--with-card-words ((1 . "fig") (2 . "grape"))
                                          (cl-letf (((symbol-function 'decklet-db--upsert-card)
                                                     (lambda (word meta) (setq upserted (list word meta))))
                                                    ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
                                                    ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil))
                                                    ((symbol-function 'run-hooks) (lambda (&rest _) nil)))
                                            (decklet-review-next-card)))
    (should (null upserted))
    (should (= 1 decklet-review--trail-pointer))))

(ert-deftest decklet-test-review-undo-confirm-skipped-no-db-write ()
  "Confirming an undone skipped card does not write to DB."
  (let* ((pre (make-decklet-card-meta :state :learning))
         (decklet-review--trail
          (list (list :card-id 1 :grade nil
                      :pre-meta pre)))
         (decklet-review--trail-pointer 0)
         (decklet-current-card-id 1)
         (decklet-due-card-ids '(2))
         (upserted nil))
    (decklet-test-review--with-card-words ((1 . "honey") (2 . "ice"))
                                          (cl-letf (((symbol-function 'decklet-db--upsert-card)
                                                     (lambda (word meta) (setq upserted (list word meta))))
                                                    ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
                                                    ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil))
                                                    ((symbol-function 'run-hooks) (lambda (&rest _) nil)))
                                            (decklet-review-next-card)))
    (should (null upserted))
    (should (= 1 decklet-review--trail-pointer))))

(ert-deftest decklet-test-review-undo-rerate-restores-pre-meta-and-updates-grade ()
  "Re-rating an undone card restores pre-meta to DB then rates."
  (let* ((pre (make-decklet-card-meta :state :learning :step 0))
         (decklet-review--trail
          (list (list :card-id 1 :grade 3
                      :pre-meta pre)))
         (decklet-review--trail-pointer 0)
         (decklet-current-card-id 1)
         (upserted nil)
         (rated nil))
    (decklet-test-review--with-card-words ((1 . "jelly"))
                                          (cl-letf (((symbol-function 'decklet-review--daily-goal-reached-p)
                                                     (lambda () nil))
                                                    ((symbol-function 'decklet-db--require-card-row)
                                                     (lambda (_id) '(:card-id 1 :word "jelly")))
                                                    ((symbol-function 'decklet-db--upsert-card)
                                                     (lambda (word meta) (setq upserted (list word meta))))
                                                    ((symbol-function 'decklet--rate-card-state)
                                                     (lambda (card-id word old-meta grade &optional prior-grade)
                                                       (ignore word old-meta)
                                                       (setq rated (list card-id grade prior-grade))))
                                                    ((symbol-function 'decklet-review--advance)
                                                     (lambda () nil)))
                                            (decklet-review--handle-grade 1)))
    (should (= 1 decklet-review--trail-pointer))
    (should (equal "jelly" (car upserted)))
    (should (equal pre (cadr upserted)))
    (should (equal '(1 1 3) rated))
    (let ((entry (nth 0 decklet-review--trail)))
      (should (= 1 (plist-get entry :grade))))))

(ert-deftest decklet-test-review-undo-pointer-catches-up-resumes-forward ()
  "When pointer catches up to log end, next-card pops from due-words."
  (let* ((decklet-review--trail (list (list :card-id 1 :grade 3
                                            :pre-meta (make-decklet-card-meta))))
         (decklet-review--trail-pointer 1)
         (decklet-current-card-id 1)
         (decklet-due-card-ids '(2)))
    (decklet-test-review--with-card-words ((1 . "x") (2 . "kiwi"))
                                          (cl-letf (((symbol-function 'decklet-get-card-meta)
                                                     (lambda (_id) (make-decklet-card-meta)))
                                                    ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
                                                    ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil))
                                                    ((symbol-function 'run-hooks) (lambda (&rest _) nil)))
                                            (decklet-review-next-card)))
    (should (= 2 decklet-current-card-id))
    (should (= 2 (length decklet-review--trail)))))

(ert-deftest decklet-test-review-undo-confirm-then-resume-no-double-skip ()
  "After confirming the last undone card, forward flow resumes correctly.
The confirmed card must not be double-logged as a skip."
  (let* ((pre (make-decklet-card-meta :state :learning))
         ;; Log has one rated entry; pointer is at 0 (undone).
         (decklet-review--trail
          (list (list :card-id 1 :grade 3
                      :pre-meta pre)))
         (decklet-review--trail-pointer 0)
         (decklet-current-card-id 1)
         (decklet-due-card-ids '(2)))
    (decklet-test-review--with-card-words ((1 . "A") (2 . "B"))
                                          (cl-letf (((symbol-function 'decklet--refresh-due-card-ids) (lambda () nil))
                                                    ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
                                                    ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil))
                                                    ((symbol-function 'run-hooks) (lambda (&rest _) nil)))
                                            (decklet-review-next-card)))
    (should (= 1 decklet-review--trail-pointer))
    (should (= 2 decklet-current-card-id))
    (should (= 1 (length decklet-review--trail)))))

(ert-deftest decklet-test-review-undo-pushes-current-card-to-due-words ()
  "Undoing from normal flow pushes the current card back to due-words."
  (let* ((pre (make-decklet-card-meta :state :learning))
         (decklet-review--trail
          (list (list :card-id 1 :grade 3
                      :pre-meta pre)))
         (decklet-review--trail-pointer 1)
         (decklet-current-card-id 2)
         (decklet-due-card-ids '(3)))
    (decklet-test-review--with-card-words ((1 . "A") (2 . "B") (3 . "C"))
                                          (cl-letf (((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
                                                    ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil)))
                                            (decklet-review-undo)))
    (should (= 1 decklet-current-card-id))
    (should (equal '(2 3) decklet-due-card-ids))))

(ert-deftest decklet-test-review-undo-in-undo-state-does-not-push-to-queue ()
  "Undoing while already in undo state does not push the current card."
  (let* ((entries (mapcar (lambda (id)
                            (list :card-id id :grade 3
                                  :pre-meta (make-decklet-card-meta)))
                          '(1 2)))
         (decklet-review--trail entries)
         (decklet-review--trail-pointer 1)
         (decklet-current-card-id 2)
         (decklet-due-card-ids '(3)))
    (decklet-test-review--with-card-words ((1 . "A") (2 . "B") (3 . "C"))
                                          (cl-letf (((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
                                                    ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil)))
                                            (decklet-review-undo)))
    (should (= 1 decklet-current-card-id))
    (should (equal '(3) decklet-due-card-ids))))

(ert-deftest decklet-test-review-undo-rate-after-undo-does-not-duplicate-log ()
  "Rating a card after undoing to it updates the entry, not appends."
  (let* ((pre (make-decklet-card-meta :state :learning))
         (decklet-review--trail
          (list (list :card-id 1 :grade nil
                      :pre-meta pre)))
         (decklet-review--trail-pointer 0)
         (decklet-current-card-id 1))
    (decklet-test-review--with-card-words ((1 . "A"))
                                          (cl-letf (((symbol-function 'decklet-review--daily-goal-reached-p)
                                                     (lambda () nil))
                                                    ((symbol-function 'decklet-db--require-card-row)
                                                     (lambda (_id) '(:card-id 1 :word "A")))
                                                    ((symbol-function 'decklet-db--upsert-card) (lambda (&rest _) nil))
                                                    ((symbol-function 'decklet--rate-card-state) (lambda (&rest _) nil))
                                                    ((symbol-function 'decklet-review--advance)
                                                     (lambda () nil)))
                                            (decklet-review--handle-grade 1)))
    (should (= 1 (length decklet-review--trail)))
    (should (= 1 (plist-get (nth 0 decklet-review--trail) :grade)))))

;; ---------------------------------------------------------------------------
;; Undo: trail reset
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-trail-reset-clears-state ()
  "Reset clears the trail and pointer."
  (let ((decklet-review--trail
         (list (list :card-id 1 :grade 3
                     :pre-meta (make-decklet-card-meta))))
        (decklet-review--trail-pointer 0))
    (decklet-review--trail-reset)
    (should (null decklet-review--trail))
    (should (= 0 decklet-review--trail-pointer))))

;; ---------------------------------------------------------------------------
;; Undo: rename and delete integration
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-trail-entries-keep-card-ids ()
  "Trail identity is stored as stable card ids."
  (let ((decklet-review--trail
         (list (list :card-id 11 :grade 3
                     :pre-meta (make-decklet-card-meta))
               (list :card-id 22 :grade 2
                     :pre-meta (make-decklet-card-meta))
               (list :card-id 11 :grade 1
                     :pre-meta (make-decklet-card-meta)))))
    (should (= 11 (plist-get (nth 0 decklet-review--trail) :card-id)))
    (should (= 22 (plist-get (nth 1 decklet-review--trail) :card-id)))
    (should (= 11 (plist-get (nth 2 decklet-review--trail) :card-id)))))

(ert-deftest decklet-test-review-undo-delete-removes-entries-adjusts-pointer ()
  "Deleting a word removes its log entries and adjusts the pointer."
  (let ((decklet-review--trail
         (list (list :card-id 1 :grade 3
                     :pre-meta (make-decklet-card-meta))
               (list :card-id 2 :grade 2
                     :pre-meta (make-decklet-card-meta))
               (list :card-id 3 :grade 1
                     :pre-meta (make-decklet-card-meta))))
        (decklet-review--trail-pointer 3))
    (decklet-review--trail-delete 2)
    (should (= 2 (length decklet-review--trail)))
    (should (= 1 (plist-get (nth 0 decklet-review--trail) :card-id)))
    (should (= 3 (plist-get (nth 1 decklet-review--trail) :card-id)))
    (should (= 2 decklet-review--trail-pointer))))

(ert-deftest decklet-test-review-undo-delete-before-pointer-adjusts ()
  "Deleting an entry before the pointer decrements it."
  (let ((decklet-review--trail
         (list (list :card-id 1 :grade 3
                     :pre-meta (make-decklet-card-meta))
               (list :card-id 2 :grade 2
                     :pre-meta (make-decklet-card-meta))
               (list :card-id 3 :grade 1
                     :pre-meta (make-decklet-card-meta))))
        (decklet-review--trail-pointer 1))
    (decklet-review--trail-delete 1)
    (should (= 2 (length decklet-review--trail)))
    (should (= 0 decklet-review--trail-pointer))
    (should (= 2 (plist-get (nth 0 decklet-review--trail) :card-id)))))

(ert-deftest decklet-test-review-undo-delete-at-pointer ()
  "Deleting the entry at the current pointer adjusts gracefully."
  (let ((decklet-review--trail
         (list (list :card-id 1 :grade 3
                     :pre-meta (make-decklet-card-meta))
               (list :card-id 2 :grade 2
                     :pre-meta (make-decklet-card-meta))
               (list :card-id 3 :grade 1
                     :pre-meta (make-decklet-card-meta))))
        (decklet-review--trail-pointer 2))
    (decklet-review--trail-delete 3)
    (should (= 2 (length decklet-review--trail)))
    (should (= 2 decklet-review--trail-pointer))))

;; ---------------------------------------------------------------------------
;; Undo: rendering
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-undo-highlight-on-rated-card ()
  "The previous grade is highlighted when reviewing an undone rated card."
  (let* ((meta (make-decklet-card-meta :state :review :last-review "2025-01-01T00:00:00Z"))
         (decklet-review--trail
          (list (list :card-id 1 :grade 3
                      :pre-meta meta)))
         (decklet-review--trail-pointer 0)
         (decklet-review--render-word "plum")
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
         (decklet-review--render-word "quince")
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
          (list (list :card-id 1 :grade nil
                      :pre-meta meta)))
         (decklet-review--trail-pointer 0)
         (decklet-review--render-word "raisin")
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
  (let ((decklet-review--trail (list (list :card-id 1 :grade 1
                                           :pre-meta (make-decklet-card-meta))))
        (decklet-review--trail-pointer 0)
        (decklet-review--hint-timer nil)
        (decklet-review--state-display-hint nil)
        (decklet-current-card-id 1)
        (decklet-last-added-word nil)
        (decklet-due-card-ids nil))
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
          (list (list :card-id 1 :grade 3
                      :pre-meta pre)))
         (decklet-review--trail-pointer 0)
         (decklet-current-card-id 1)
         (decklet-due-card-ids '(2)))
    (decklet-test-review--with-card-words ((1 . "star") (2 . "sun"))
                                          (cl-letf (((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
                                                    ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil))
                                                    ((symbol-function 'run-hooks) (lambda (&rest _) nil)))
                                            (decklet-review-next-card)))
    (should (= 1 (length decklet-review--trail)))))

;; ---------------------------------------------------------------------------
;; Undo: undo skips deleted cards
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-undo-skips-deleted-card ()
  "Undo skips entries whose card no longer exists and continues backward."
  (let* ((entries (mapcar (lambda (id)
                            (list :card-id id :grade 3
                                  :pre-meta (make-decklet-card-meta)))
                          '(1 2)))
         (decklet-review--trail entries)
         (decklet-review--trail-pointer 2)
         (decklet-current-card-id 3)
         (decklet-due-card-ids nil))
    (cl-letf (((symbol-function 'decklet-card-word)
               (lambda (card-id)
                 (alist-get card-id '((1 . "A") (2 . "B") (3 . "C")) nil nil #'eql)))
              ((symbol-function 'decklet-card-exists-p)
               (lambda (card-id) (= card-id 1)))
              ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
              ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil)))
      (decklet-review-undo))
    (should (= 1 decklet-current-card-id))
    (should (= 0 decklet-review--trail-pointer))))

;; ---------------------------------------------------------------------------
;; Undo: cleanup clears state without DB writes
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-cleanup-clears-without-db-write ()
  "Session cleanup clears state without writing to DB."
  (let* ((decklet-review--trail
          (list (list :card-id 1 :grade 3
                      :pre-meta (make-decklet-card-meta))))
         (decklet-review--trail-pointer 0)
         (decklet-review--hint-timer nil)
         (decklet-review--state-display-hint nil)
         (decklet-current-card-id 1)
         (decklet-last-added-word nil)
         (decklet-due-card-ids nil)
         (upserted nil))
    (cl-letf (((symbol-function 'decklet-db--upsert-card)
               (lambda (word meta) (push (list word meta) upserted))))
      (decklet-review--clean-up))
    (should (null upserted))
    (should (null decklet-review--trail))
    (should (= 0 decklet-review--trail-pointer))))

;; ---------------------------------------------------------------------------
;; Undo: highlight targets only the label text
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-undo-highlight-only-on-label ()
  "The highlight face applies to the label text only, not the key number."
  (let* ((meta (make-decklet-card-meta :state :review :last-review "2025-01-01T00:00:00Z"))
         (decklet-review--trail
          (list (list :card-id 1 :grade 3
                      :pre-meta meta)))
         (decklet-review--trail-pointer 0)
         (decklet-review--render-word "plum")
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

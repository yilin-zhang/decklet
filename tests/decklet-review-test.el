;;; decklet-review-test.el --- Tests for decklet-review.el -*- lexical-binding: t; -*-

(require 'decklet-test-helpers)

(defmacro decklet-test-review--with-card-words (pairs &rest body)
  "Run BODY with CARD-ID to word lookup stubbed from PAIRS."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'decklet-get-card-word)
              (lambda (card-id)
                (alist-get card-id ',pairs nil nil #'eql)))
             ((symbol-function 'decklet-card-exists-p)
              (lambda (card-id)
                (and (alist-get card-id ',pairs nil nil #'eql) t))))
     ,@body))

(ert-deftest decklet-test-review-mode-registers-db-dependency ()
  (with-temp-buffer
    (decklet-review-mode)
    (should decklet-db--owner-buffer)))

(ert-deftest decklet-test-review-quit-kills-attached-buffers-on-last-owner ()
  (decklet-test--with-temp-db
   (decklet-db--ensure)
   (let ((review (get-buffer-create decklet-review-buffer-name))
         (attached (generate-new-buffer " *decklet-attached*")))
     (unwind-protect
         (progn
           (with-current-buffer review
             (decklet-review-mode))
           (with-current-buffer attached
             (decklet-card-back-mode 1))
           (decklet-review-quit)
           (should-not (buffer-live-p review))
           (should-not (buffer-live-p attached))
           (should-not decklet-db--conn))
       (when (buffer-live-p review)
         (kill-buffer review))
       (when (buffer-live-p attached)
         (kill-buffer attached))))))

(ert-deftest decklet-test-review-quit-aborts-when-attached-buffer-cancels-kill ()
  (decklet-test--with-temp-db
   (decklet-db--ensure)
   (let ((review (get-buffer-create decklet-review-buffer-name))
         (attached (generate-new-buffer " *decklet-attached*")))
     (unwind-protect
         (progn
           (with-current-buffer review
             (decklet-review-mode))
           (with-current-buffer attached
             (decklet-card-back-mode 1)
             (add-hook 'kill-buffer-query-functions (lambda () nil) nil t))
           (decklet-review-quit)
           (should (buffer-live-p review))
           (should (buffer-live-p attached))
           (should decklet-db--conn))
       (when (buffer-live-p attached)
         (with-current-buffer attached
           (setq kill-buffer-query-functions nil))
         (kill-buffer attached))
       (when (buffer-live-p review)
         (kill-buffer review))))))

;; ---------------------------------------------------------------------------
;; Review flow: grade handling and hook transitions
;; ---------------------------------------------------------------------------
;; These tests focus on the central grade handler used by 1/2/3/4 commands.
;; We explicitly mock side-effect functions (`decklet-rate-card',
;; `decklet-review-next-card') so we can verify behavior without UI coupling.

(ert-deftest decklet-test-review-handle-grade-triggers-daily-goal-hook-on-transition ()
  (let ((decklet-current-card-id 1)
        (decklet-review--trail-past nil)
        (decklet-review--trail-future nil)
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
        (decklet-review--trail-past nil)
        (decklet-review--trail-future nil)
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
;; Trail zipper: entry recording
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-trail-records-rated-entry-on-past ()
  "Rating a card pushes an entry onto the past side."
  (let ((decklet-current-card-id 1)
        (decklet-review--trail-past nil)
        (decklet-review--trail-future nil)
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
    (should (= 1 (length decklet-review--trail-past)))
    (should (null decklet-review--trail-future))
    (let ((entry (car decklet-review--trail-past)))
      (should (= 1 (plist-get entry :card-id)))
      (should (= 3 (plist-get entry :grade)))
      (should (plist-get entry :pre-meta)))))

(ert-deftest decklet-test-review-trail-records-skip-entry-on-past ()
  "Skipping a card pushes an entry with nil grade onto the past side."
  (let ((decklet-current-card-id 1)
        (decklet-due-card-ids '(2))
        (decklet-review--trail-past nil)
        (decklet-review--trail-future nil)
        (meta (make-decklet-card-meta :state :learning)))
    (decklet-test-review--with-card-words ((1 . "banana") (2 . "cherry"))
                                          (cl-letf (((symbol-function 'decklet-get-card-meta)
                                                     (lambda (_id) (copy-decklet-card-meta meta)))
                                                    ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
                                                    ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil))
                                                    ((symbol-function 'run-hooks) (lambda (&rest _) nil)))
                                            (decklet-review-next-card)))
    (should (= 1 (length decklet-review--trail-past)))
    (let ((entry (car decklet-review--trail-past)))
      (should (= 1 (plist-get entry :card-id)))
      (should (null (plist-get entry :grade)))
      (should (plist-get entry :pre-meta)))))

;; ---------------------------------------------------------------------------
;; Trail zipper: undo
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-undo-moves-past-head-to-future ()
  "Undo pops from past, pushes onto future, and pushes current card back to due."
  (let* ((pre (make-decklet-card-meta :state :learning :step 0))
         (decklet-review--trail-past
          (list (list :card-id 1 :grade 3 :pre-meta pre)))
         (decklet-review--trail-future nil)
         (decklet-current-card-id 2)
         (decklet-due-card-ids '(3))
         (upserted nil))
    (decklet-test-review--with-card-words ((1 . "date") (2 . "elderberry") (3 . "fig"))
                                          (cl-letf (((symbol-function 'decklet-db--upsert-card)
                                                     (lambda (word meta) (setq upserted (list word meta))))
                                                    ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
                                                    ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil)))
                                            (decklet-review-undo)))
    (should (null decklet-review--trail-past))
    (should (= 1 (length decklet-review--trail-future)))
    (should (null upserted))
    (should (= 1 decklet-current-card-id))
    (should (equal '(2 3) decklet-due-card-ids))))

(ert-deftest decklet-test-review-undo-empty-trail ()
  "Undo on empty trail messages without error."
  (let ((decklet-review--trail-past nil)
        (decklet-review--trail-future nil)
        (msg nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest _) (setq msg fmt))))
      (decklet-review-undo))
    (should (string-match-p "Nothing to undo" msg))))

(ert-deftest decklet-test-review-undo-multiple-walks-backward ()
  "Multiple undos walk the full past onto future, newest-first."
  (let* ((make-entry (lambda (id)
                       (list :card-id id :grade 3 :pre-meta (make-decklet-card-meta))))
         ;; Rate order was 1 then 2 then 3, so past head is most recent = 3.
         (decklet-review--trail-past
          (list (funcall make-entry 3)
                (funcall make-entry 2)
                (funcall make-entry 1)))
         (decklet-review--trail-future nil)
         (decklet-current-card-id 4)
         (words-seen nil))
    (decklet-test-review--with-card-words ((1 . "A") (2 . "B") (3 . "C") (4 . "D"))
                                          (cl-letf (((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
                                                    ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil)))
                                            (dotimes (_ 3)
                                              (decklet-review-undo)
                                              (push (decklet-get-card-word decklet-current-card-id) words-seen))))
    ;; First undo reveals C (most recent), then B, then A.
    (should (equal '("A" "B" "C") words-seen))
    (should (null decklet-review--trail-past))
    (should (= 3 (length decklet-review--trail-future)))))

;; ---------------------------------------------------------------------------
;; Trail zipper: confirm and re-rate
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-confirm-rated-moves-future-head-to-past ()
  "Confirming an undone rated card moves its entry back to past, no DB write."
  (let* ((pre (make-decklet-card-meta :state :learning))
         (decklet-review--trail-past nil)
         (decklet-review--trail-future
          (list (list :card-id 1 :grade 3 :pre-meta pre)))
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
    (should (= 1 (length decklet-review--trail-past)))
    (should (null decklet-review--trail-future))))

(ert-deftest decklet-test-review-confirm-skipped-no-db-write ()
  "Confirming an undone skipped card does not write to DB."
  (let* ((pre (make-decklet-card-meta :state :learning))
         (decklet-review--trail-past nil)
         (decklet-review--trail-future
          (list (list :card-id 1 :grade nil :pre-meta pre)))
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
    (should (= 1 (length decklet-review--trail-past)))
    (should (null decklet-review--trail-future))))

(ert-deftest decklet-test-review-rerate-restores-pre-meta-and-updates-entry ()
  "Re-rating an undone card restores pre-meta to DB then rates and updates entry."
  (let* ((pre (make-decklet-card-meta :state :learning :step 0))
         (decklet-review--trail-past nil)
         (decklet-review--trail-future
          (list (list :card-id 1 :grade 3 :pre-meta pre)))
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
    (should (= 1 (length decklet-review--trail-past)))
    (should (null decklet-review--trail-future))
    (should (equal "jelly" (car upserted)))
    (should (equal pre (cadr upserted)))
    (should (equal '(1 1 3) rated))
    (should (= 1 (plist-get (car decklet-review--trail-past) :grade)))))

(ert-deftest decklet-test-review-next-card-in-forward-flow-skips-and-pops ()
  "Forward-flow next-card records a skip and pops the next due card."
  (let* ((decklet-review--trail-past
          (list (list :card-id 1 :grade 3 :pre-meta (make-decklet-card-meta))))
         (decklet-review--trail-future nil)
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
    ;; Prior rated entry plus the fresh skip.
    (should (= 2 (length decklet-review--trail-past)))))

(ert-deftest decklet-test-review-confirm-then-resume-no-double-skip ()
  "After confirming the last undone card, forward flow resumes without double-logging it."
  (let* ((pre (make-decklet-card-meta :state :learning))
         (decklet-review--trail-past nil)
         (decklet-review--trail-future
          (list (list :card-id 1 :grade 3 :pre-meta pre)))
         (decklet-current-card-id 1)
         (decklet-due-card-ids '(2)))
    (decklet-test-review--with-card-words ((1 . "A") (2 . "B"))
                                          (cl-letf (((symbol-function 'decklet--refresh-due-card-ids) (lambda () nil))
                                                    ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
                                                    ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil))
                                                    ((symbol-function 'run-hooks) (lambda (&rest _) nil)))
                                            (decklet-review-next-card)))
    (should (null decklet-review--trail-future))
    (should (= 2 decklet-current-card-id))
    (should (= 1 (length decklet-review--trail-past)))))

(ert-deftest decklet-test-review-undo-in-undo-state-does-not-push-to-queue ()
  "Undoing while already in undo state does not push the current card."
  (let* ((make-entry (lambda (id)
                       (list :card-id id :grade 3 :pre-meta (make-decklet-card-meta))))
         ;; Already undone once: past=(A), future=(B).  Current on screen is B.
         (decklet-review--trail-past (list (funcall make-entry 1)))
         (decklet-review--trail-future (list (funcall make-entry 2)))
         (decklet-current-card-id 2)
         (decklet-due-card-ids '(3)))
    (decklet-test-review--with-card-words ((1 . "A") (2 . "B") (3 . "C"))
                                          (cl-letf (((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
                                                    ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil)))
                                            (decklet-review-undo)))
    (should (= 1 decklet-current-card-id))
    (should (equal '(3) decklet-due-card-ids))))

(ert-deftest decklet-test-review-rerate-after-undo-does-not-duplicate-entry ()
  "Rating a card after undoing to it updates the entry in place."
  (let* ((pre (make-decklet-card-meta :state :learning))
         (decklet-review--trail-past nil)
         (decklet-review--trail-future
          (list (list :card-id 1 :grade nil :pre-meta pre)))
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
    (should (= 1 (length decklet-review--trail-past)))
    (should (null decklet-review--trail-future))
    (should (= 1 (plist-get (car decklet-review--trail-past) :grade)))))

;; ---------------------------------------------------------------------------
;; Trail zipper: reset
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-trail-reset-clears-state ()
  "Reset clears both sides of the trail."
  (let ((decklet-review--trail-past
         (list (list :card-id 1 :grade 3 :pre-meta (make-decklet-card-meta))))
        (decklet-review--trail-future
         (list (list :card-id 2 :grade 2 :pre-meta (make-decklet-card-meta)))))
    (decklet-review--trail-reset)
    (should (null decklet-review--trail-past))
    (should (null decklet-review--trail-future))))

;; ---------------------------------------------------------------------------
;; Trail zipper: delete
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-trail-entries-keep-card-ids ()
  "Trail identity is stored as stable card ids."
  (let ((decklet-review--trail-past
         (list (list :card-id 11 :grade 1 :pre-meta (make-decklet-card-meta))
               (list :card-id 22 :grade 2 :pre-meta (make-decklet-card-meta))
               (list :card-id 11 :grade 3 :pre-meta (make-decklet-card-meta)))))
    (should (= 11 (plist-get (nth 0 decklet-review--trail-past) :card-id)))
    (should (= 22 (plist-get (nth 1 decklet-review--trail-past) :card-id)))
    (should (= 11 (plist-get (nth 2 decklet-review--trail-past) :card-id)))))

(ert-deftest decklet-test-review-trail-delete-removes-from-past ()
  "Deleting a card removes its entries from the past side."
  (let ((decklet-review--trail-past
         (list (list :card-id 3 :grade 1 :pre-meta (make-decklet-card-meta))
               (list :card-id 2 :grade 2 :pre-meta (make-decklet-card-meta))
               (list :card-id 1 :grade 3 :pre-meta (make-decklet-card-meta))))
        (decklet-review--trail-future nil))
    (decklet-review--trail-delete 2)
    (should (= 2 (length decklet-review--trail-past)))
    (should (null decklet-review--trail-future))
    (should (= 3 (plist-get (nth 0 decklet-review--trail-past) :card-id)))
    (should (= 1 (plist-get (nth 1 decklet-review--trail-past) :card-id)))))

(ert-deftest decklet-test-review-trail-delete-removes-from-both-sides ()
  "Deleting a card removes entries from both past and future."
  ;; Prior state: rated 1, rated 2, then undone twice, so user is on 1.
  ;; past=(), future=((:card 1 ...) (:card 2 ...))
  (let ((decklet-review--trail-past nil)
        (decklet-review--trail-future
         (list (list :card-id 1 :grade 3 :pre-meta (make-decklet-card-meta))
               (list :card-id 2 :grade 2 :pre-meta (make-decklet-card-meta)))))
    (decklet-review--trail-delete 1)
    (should (null decklet-review--trail-past))
    (should (= 1 (length decklet-review--trail-future)))
    (should (= 2 (plist-get (car decklet-review--trail-future) :card-id)))))

(ert-deftest decklet-test-review-trail-delete-of-current-leaves-rest ()
  "Deleting the card currently on-screen removes just that entry from future."
  ;; past=((:card 2)), future=((:card 3)).  User is looking at 3.
  (let ((decklet-review--trail-past
         (list (list :card-id 2 :grade 2 :pre-meta (make-decklet-card-meta))
               (list :card-id 1 :grade 3 :pre-meta (make-decklet-card-meta))))
        (decklet-review--trail-future
         (list (list :card-id 3 :grade 1 :pre-meta (make-decklet-card-meta)))))
    (decklet-review--trail-delete 3)
    (should (= 2 (length decklet-review--trail-past)))
    (should (null decklet-review--trail-future))))

;; ---------------------------------------------------------------------------
;; Trail zipper: render highlighting
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-undo-highlight-on-rated-card ()
  "The previous grade is highlighted when reviewing an undone rated card."
  (let* ((meta (make-decklet-card-meta :state :review :last-review "2025-01-01T00:00:00Z"))
         (decklet-review--trail-past nil)
         (decklet-review--trail-future
          (list (list :card-id 1 :grade 3 :pre-meta meta)))
         (decklet-review--render-word "plum")
         (decklet-review--render-meta meta)
         (decklet-review-enable-interval-labels nil))
    (let ((output (decklet-review-component-rates)))
      ;; "Good" option should have the undo highlight face
      (should (text-property-not-all 0 (length output)
                                     'face nil output))
      (let ((found nil))
        (dotimes (i (length output))
          (when (eq (get-text-property i 'face output)
                    'decklet-review-undo-highlight-face)
            (setq found t)))
        (should found)))))

(ert-deftest decklet-test-review-undo-no-highlight-in-normal-flow ()
  "No undo highlight face appears during normal forward review."
  (let* ((meta (make-decklet-card-meta :state :review :last-review "2025-01-01T00:00:00Z"))
         (decklet-review--trail-past nil)
         (decklet-review--trail-future nil)
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
         (decklet-review--trail-past nil)
         (decklet-review--trail-future
          (list (list :card-id 1 :grade nil :pre-meta meta)))
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
;; Session cleanup
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-clean-up-clears-trail ()
  "Session cleanup clears both sides of the trail."
  (let ((decklet-review--trail-past
         (list (list :card-id 1 :grade 1 :pre-meta (make-decklet-card-meta))))
        (decklet-review--trail-future
         (list (list :card-id 2 :grade 3 :pre-meta (make-decklet-card-meta))))
        (decklet-review--hint-timer nil)
        (decklet-review--state-display-hint nil)
        (decklet-current-card-id 1)
        (decklet-last-added-word nil)
        (decklet-due-card-ids nil))
    (decklet-review--clean-up)
    (should (null decklet-review--trail-past))
    (should (null decklet-review--trail-future))))

(ert-deftest decklet-test-review-clean-up-does-not-write-to-db ()
  "Session cleanup clears state without writing to DB."
  (let* ((decklet-review--trail-past
          (list (list :card-id 1 :grade 3 :pre-meta (make-decklet-card-meta))))
         (decklet-review--trail-future nil)
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
    (should (null decklet-review--trail-past))
    (should (null decklet-review--trail-future))))

;; ---------------------------------------------------------------------------
;; Undo: skip not logged during confirm
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-skip-not-logged-on-confirm ()
  "Confirming an undone card via `n' does not append a new trail entry."
  (let* ((pre (make-decklet-card-meta :state :learning))
         (decklet-review--trail-past nil)
         (decklet-review--trail-future
          (list (list :card-id 1 :grade 3 :pre-meta pre)))
         (decklet-current-card-id 1)
         (decklet-due-card-ids '(2)))
    (decklet-test-review--with-card-words ((1 . "star") (2 . "sun"))
                                          (cl-letf (((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
                                                    ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil))
                                                    ((symbol-function 'run-hooks) (lambda (&rest _) nil)))
                                            (decklet-review-next-card)))
    (should (= 1 (length decklet-review--trail-past)))
    (should (null decklet-review--trail-future))))

;; ---------------------------------------------------------------------------
;; Undo: skips deleted cards
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-undo-skips-deleted-card ()
  "Undo skips entries whose card no longer exists and continues backward."
  (let* ((make-entry (lambda (id)
                       (list :card-id id :grade 3 :pre-meta (make-decklet-card-meta))))
         ;; Past head is most recent, i.e., 2 rated after 1.
         (decklet-review--trail-past
          (list (funcall make-entry 2)
                (funcall make-entry 1)))
         (decklet-review--trail-future nil)
         (decklet-current-card-id 3)
         (decklet-due-card-ids nil))
    (cl-letf (((symbol-function 'decklet-get-card-word)
               (lambda (card-id)
                 (alist-get card-id '((1 . "A") (2 . "B") (3 . "C")) nil nil #'eql)))
              ((symbol-function 'decklet-card-exists-p)
               (lambda (card-id) (= card-id 1)))
              ((symbol-function 'decklet-review--reset-ui-state) (lambda () nil))
              ((symbol-function 'decklet-review--render-buffer) (lambda (&rest _) nil)))
      (decklet-review-undo))
    (should (= 1 decklet-current-card-id))
    (should (null decklet-review--trail-past))
    (should (= 2 (length decklet-review--trail-future)))))

;; ---------------------------------------------------------------------------
;; Undo: highlight targets only the label text
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-undo-highlight-only-on-label ()
  "The highlight face applies to the label text only, not the key number."
  (let* ((meta (make-decklet-card-meta :state :review :last-review "2025-01-01T00:00:00Z"))
         (decklet-review--trail-past nil)
         (decklet-review--trail-future
          (list (list :card-id 1 :grade 3 :pre-meta meta)))
         (decklet-review--render-word "plum")
         (decklet-review--render-meta meta)
         (decklet-review-enable-interval-labels nil))
    (let ((output (decklet-review-component-rates)))
      (let ((good-pos (string-match "Good" output)))
        (should good-pos)
        (should (eq (get-text-property good-pos 'face output)
                    'decklet-review-undo-highlight-face))
        (should-not (eq (get-text-property (1- good-pos) 'face output)
                        'decklet-review-undo-highlight-face))))))

(provide 'decklet-review-test)
;;; decklet-review-test.el ends here

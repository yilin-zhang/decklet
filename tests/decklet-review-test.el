;;; decklet-review-test.el --- This file tests decklet-review.el. -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

(defmacro decklet-test-review--with-card-words (pairs &rest body)
  "Run BODY with CARD-ID -> word lookups (and existence) stubbed from PAIRS."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'decklet-get-card-word)
              (lambda (id) (alist-get id ',pairs nil nil #'eql)))
             ((symbol-function 'decklet-card-exists-p)
              (lambda (id) (and (alist-get id ',pairs nil nil #'eql) t))))
     ,@body))

;;; Mode and session teardown

(ert-deftest decklet-test-review-mode-registers-session-buffer ()
  "`decklet-review-mode' marks its buffer as a Decklet session buffer."
  (with-temp-buffer
    (decklet-review-mode)
    (should decklet-db--session-buffer)))

(ert-deftest decklet-test-review-quit-kills-attached-buffers-on-last-primary ()
  "Quitting the last primary buffer kills attached buffers and closes the DB."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (let ((review (get-buffer-create decklet-review-buffer-name)))
      (decklet-test--with-temp-buffers (attached)
	(with-current-buffer review (decklet-review-mode))
	(with-current-buffer attached (decklet-card-back-mode 1))
	(decklet-review-quit)
	(should-not (buffer-live-p review))
	(should-not (buffer-live-p attached))
	(should-not decklet-db--conn)))))

(ert-deftest decklet-test-review-quit-aborts-when-attached-cancels-kill ()
  "An attached buffer refusing to die keeps the review buffer and DB alive."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (let ((review (get-buffer-create decklet-review-buffer-name)))
      (decklet-test--with-temp-buffers (attached)
	(with-current-buffer review (decklet-review-mode))
	(with-current-buffer attached
	  (decklet-card-back-mode 1)
	  (add-hook 'kill-buffer-query-functions #'ignore nil t))
	(decklet-review-quit)
	(should (buffer-live-p review))
	(should (buffer-live-p attached))
	(should decklet-db--conn)
	(with-current-buffer attached (decklet-card-back-mode -1))
	(when (buffer-live-p review) (kill-buffer review))))))

;;; Grade handling and the daily-goal hook

;; These drive `decklet-review--handle-grade' against a real card: FSRS, the
;; DB write, the counter refresh, and the review log all run for real.  Only
;; `decklet-review--advance' (pure navigation onto the next card) is stubbed,
;; since there is no live review buffer to render into.

(ert-deftest decklet-test-review-handle-grade-fires-daily-goal-hook-on-transition ()
  "Rating the last outstanding card fires the daily-goal hook once."
  (decklet-test--with-temp-db
    (decklet--add-card "goalword")
    (let* ((decklet-review-daily-goal 1)
           (decklet-current-card-id (decklet-test--card-id "goalword"))
           (decklet-review--trail-past nil)
           (decklet-review--trail-future nil)
           (hook-count 0)
           (decklet-review-daily-goal-reached-hook
            (list (lambda () (cl-incf hook-count)))))
      (decklet--refresh-counter)             ; new card: goal not yet reached
      (cl-letf (((symbol-function 'decklet-review--advance) #'ignore))
        (decklet-review--handle-grade 3))
      (should (= hook-count 1))
      ;; The card really advanced and a rated entry was recorded.
      (should (decklet-card-meta-last-review
               (decklet-get-card-meta decklet-current-card-id)))
      (should (= 3 (plist-get (car decklet-review--trail-past) :grade))))))

(ert-deftest decklet-test-review-handle-grade-no-hook-when-goal-already-reached ()
  "Rating while the daily goal is already met does not re-fire the goal hook."
  (decklet-test--with-temp-db
    (decklet--add-card "first")
    (decklet--add-card "second")
    (let* ((decklet-review-daily-goal 1)
           (hook-count 0)
           (decklet-review-daily-goal-reached-hook
            (list (lambda () (cl-incf hook-count)))))
      (decklet-rate-card (decklet-test--card-id "first") 3) ; reach the goal
      (let ((decklet-current-card-id (decklet-test--card-id "second"))
            (decklet-review--trail-past nil)
            (decklet-review--trail-future nil))
        (decklet--refresh-counter)
        (cl-letf (((symbol-function 'decklet-review--advance) #'ignore))
	  (decklet-review--handle-grade 3))
        (should (= hook-count 0))))))

;;; Next-card sequencing

(ert-deftest decklet-test-review-next-card-consumes-due-queue-and-runs-hook ()
  "Forward `next-card' pops the head of the due queue and runs the next-card hook."
  (let* ((decklet-due-card-ids '(1 2))
         (decklet-current-card-id nil)
         (hook-count 0)
         (decklet-review-next-card-hook (list (lambda () (cl-incf hook-count)))))
    ;; `run-hooks' is left real so the next-card hook actually fires.
    (decklet-test-review--with-card-words ((1 . "w1") (2 . "w2"))
      (cl-letf (((symbol-function 'decklet-review--reset-ui-state) #'ignore)
		((symbol-function 'decklet-review--render-buffer) #'ignore)
		((symbol-function 'decklet-review-quit) #'ignore))
	(decklet-review-next-card)))
    (should (= decklet-current-card-id 1))
    (should (equal decklet-due-card-ids '(2)))
    (should (= hook-count 1))))

(ert-deftest decklet-test-review-start-hint-timer-is-idempotent ()
  "Repeated `start-hint-timer' calls schedule at most one timer."
  (let ((decklet-review--hint-timer nil)
        (decklet-review-hint-delay 0.1)
        (calls 0))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (&rest _) (cl-incf calls) 'fake-timer)))
      (decklet-review--start-hint-timer)
      (decklet-review--start-hint-timer))
    (should (= calls 1))
    (should (eq decklet-review--hint-timer 'fake-timer))))

;;; Trail: recording forward steps

(ert-deftest decklet-test-review-trail-records-rated-entry ()
  "Rating a card pushes a rated entry (with pre-meta) onto the past side."
  (decklet-test--with-temp-db
    (decklet--add-card "apple")
    (let ((decklet-current-card-id (decklet-test--card-id "apple"))
          (decklet-review--trail-past nil)
          (decklet-review--trail-future nil))
      (cl-letf (((symbol-function 'decklet-review--advance) #'ignore))
        (decklet-review--handle-grade 3))
      (should (= 1 (length decklet-review--trail-past)))
      (should (null decklet-review--trail-future))
      (let ((entry (car decklet-review--trail-past)))
        (should (eql decklet-current-card-id (plist-get entry :card-id)))
        (should (= 3 (plist-get entry :grade)))
        (should (plist-get entry :pre-meta))))))

(ert-deftest decklet-test-review-trail-records-skip-entry ()
  "Skipping (forward `next-card') pushes an entry with a nil grade."
  (let ((decklet-current-card-id 1)
        (decklet-due-card-ids '(2))
        (decklet-review--trail-past nil)
        (decklet-review--trail-future nil))
    (decklet-test-review--with-card-words ((1 . "banana") (2 . "cherry"))
      (cl-letf (((symbol-function 'decklet-get-card-meta)
		 (lambda (_id) (make-decklet-card-meta :state :learning))))
	(decklet-test--with-silent-review-ui
	  (decklet-review-next-card))))
    (should (= 1 (length decklet-review--trail-past)))
    (let ((entry (car decklet-review--trail-past)))
      (should (= 1 (plist-get entry :card-id)))
      (should (null (plist-get entry :grade)))
      (should (plist-get entry :pre-meta)))))

;;; Trail: undo

(ert-deftest decklet-test-review-undo-moves-past-head-to-future ()
  "Undo moves trail history and restores the current card to the due queue.
It does not write to the database."
  (let* ((decklet-review--trail-past (list (decklet-test--trail-entry 1)))
         (decklet-review--trail-future nil)
         (decklet-current-card-id 2)
         (decklet-due-card-ids '(3))
         (upserted nil))
    (decklet-test-review--with-card-words ((1 . "date") (2 . "elderberry") (3 . "fig"))
      (cl-letf (((symbol-function 'decklet-db--upsert-card)
		 (lambda (&rest _) (setq upserted t)))
		((symbol-function 'decklet-review--reset-ui-state) #'ignore)
		((symbol-function 'decklet-review--render-buffer) #'ignore))
	(decklet-review-undo)))
    (should (null decklet-review--trail-past))
    (should (= 1 (length decklet-review--trail-future)))
    (should (null upserted))
    (should (= 1 decklet-current-card-id))
    (should (equal '(2 3) decklet-due-card-ids))))

(ert-deftest decklet-test-review-undo-multiple-walks-backward ()
  "Successive undos reveal earlier cards newest-first and grow the future side."
  (let* ((decklet-review--trail-past
          (list (decklet-test--trail-entry 3)
                (decklet-test--trail-entry 2)
                (decklet-test--trail-entry 1)))
         (decklet-review--trail-future nil)
         (decklet-current-card-id 4)
         (card-ids-seen nil))
    (decklet-test-review--with-card-words ((1 . "A") (2 . "B") (3 . "C") (4 . "D"))
      (cl-letf (((symbol-function 'decklet-review--reset-ui-state) #'ignore)
		((symbol-function 'decklet-review--render-buffer) #'ignore))
	(dotimes (_ 3)
	  (decklet-review-undo)
	  (push decklet-current-card-id card-ids-seen))))
    (should (equal '(1 2 3) card-ids-seen))
    (should (null decklet-review--trail-past))
    (should (= 3 (length decklet-review--trail-future)))))

(ert-deftest decklet-test-review-undo-skips-deleted-card ()
  "Undo discards entries whose card no longer exists and continues backward.
Dead entries must not remain on the future side: advancing would
try to present the nonexistent card."
  (let* ((decklet-review--trail-past
          (list (decklet-test--trail-entry 2) (decklet-test--trail-entry 1)))
         (decklet-review--trail-future nil)
         (decklet-current-card-id 3)
         (decklet-due-card-ids nil))
    (cl-letf (((symbol-function 'decklet-get-card-word)
               (lambda (id) (alist-get id '((1 . "A") (2 . "B") (3 . "C")) nil nil #'eql)))
              ((symbol-function 'decklet-card-exists-p) (lambda (id) (= id 1)))
              ((symbol-function 'decklet-review--reset-ui-state) #'ignore)
              ((symbol-function 'decklet-review--render-buffer) #'ignore))
      (decklet-review-undo))
    (should (= 1 decklet-current-card-id))
    (should (null decklet-review--trail-past))
    (should (= 1 (length decklet-review--trail-future)))
    (should (= 1 (plist-get (car decklet-review--trail-future) :card-id)))))

;;; Trail: confirming and re-rating an undone card

(ert-deftest decklet-test-review-rerate-after-undo-recomputes-from-pre-meta ()
  "Re-rating after undo restores the original pre-rating state.
FSRS uses that original base rather than the undone rating, and Decklet voids
the original log record.

The proof is in the log: the re-rate's `pre_stability' is nil (the restored
new-card base), not the stability left behind by the undone rating."
  (decklet-test--with-temp-db
    (decklet--add-card "w")
    (let ((decklet-current-card-id (decklet-test--card-id "w"))
          (decklet-due-card-ids nil)
          (decklet-review--trail-past nil)
          (decklet-review--trail-future nil))
      (cl-letf (((symbol-function 'decklet-review--advance) #'ignore)
                ((symbol-function 'decklet-review--reset-ui-state) #'ignore)
                ((symbol-function 'decklet-review--render-buffer) #'ignore))
        (decklet-review--handle-grade 1)     ; forward-rate Again
        (decklet-review-undo)                ; back to the card
        (decklet-review--handle-grade 3))    ; re-rate Good from the undone spot
      ;; The trail holds a single entry, now graded Good.
      (should (= 1 (length decklet-review--trail-past)))
      (should (= 3 (plist-get (car decklet-review--trail-past) :grade)))
      ;; Log: rated(Again) -> rated(Good) -> void(the prior record).
      (let* ((records (decklet-test--read-log))
             (again (nth 0 records))
             (good (nth 1 records)))
        (should (equal (list decklet-review-log-kind-rated
                             decklet-review-log-kind-rated
                             decklet-review-log-kind-void)
                       (mapcar (lambda (r) (plist-get r :kind)) records)))
        (should (= 1 (plist-get again :grade)))
        (should (= (plist-get again :id) (plist-get (nth 2 records) :voids)))
        (should (= 3 (plist-get good :grade)))
        (should (null (plist-get good :pre_stability)))))))

(ert-deftest decklet-test-review-next-card-after-confirm-resumes-forward ()
  "Confirming the last undone card resumes forward review.
The next due card appears with only one prior trail entry."
  (let* ((decklet-review--trail-past nil)
         (decklet-review--trail-future (list (decklet-test--trail-entry 1)))
         (decklet-current-card-id 1)
         (decklet-due-card-ids '(2)))
    (decklet-test-review--with-card-words ((1 . "A") (2 . "B"))
      (cl-letf (((symbol-function 'decklet--refresh-due-card-ids) #'ignore))
	(decklet-test--with-silent-review-ui
	  (decklet-review-next-card))))
    (should (null decklet-review--trail-future))
    (should (= 2 decklet-current-card-id))
    (should (= 1 (length decklet-review--trail-past)))))

;;; Trail: reset and delete

(ert-deftest decklet-test-review-trail-reset-clears-both-sides ()
  "`trail-reset' empties past and future."
  (let ((decklet-review--trail-past (list (decklet-test--trail-entry 1)))
        (decklet-review--trail-future (list (decklet-test--trail-entry 2 :grade 2))))
    (decklet-review--trail-reset)
    (should (null decklet-review--trail-past))
    (should (null decklet-review--trail-future))))

(ert-deftest decklet-test-review-trail-delete-removes-from-both-sides ()
  "`trail-delete' removes every entry for a card from past and future."
  (let ((decklet-review--trail-past
         (list (decklet-test--trail-entry 3) (decklet-test--trail-entry 2)
               (decklet-test--trail-entry 1)))
        (decklet-review--trail-future
         (list (decklet-test--trail-entry 2 :grade 2))))
    (decklet-review--trail-delete 2)
    (should (equal '(3 1) (mapcar (lambda (e) (plist-get e :card-id))
                                  decklet-review--trail-past)))
    (should (null decklet-review--trail-future))))

;;; Undo highlight on the rates component

(defun decklet-test-review--rates-with-future (future)
  "Return the rates component string with FUTURE as the undo trail-future."
  (let ((meta (make-decklet-card-meta :state :review :last-review "2025-01-01T00:00:00Z"))
        (decklet-review--trail-past nil)
        (decklet-review--trail-future future)
        (decklet-review--render-word "plum")
        (decklet-review-enable-interval-labels nil))
    (let ((decklet-review--render-meta meta))
      (decklet-review-component-rates))))

(ert-deftest decklet-test-review-undo-highlights-prior-grade ()
  "An undone rated card highlights its prior grade."
  (let ((output (decklet-test-review--rates-with-future
                 (list (decklet-test--trail-entry 1 :grade 3))))) ; grade 3 = Good
    (should (decklet-test--string-has-face-p
             output 'decklet-review-undo-highlight-face))))

(provide 'decklet-review-test)
;;; decklet-review-test.el ends here

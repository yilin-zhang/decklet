;;; decklet-review-test.el --- This file tests decklet-review.el. -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

(defmacro decklet-test-review--in-session (&rest body)
  "Run BODY in a live review buffer with an empty trail, killing it on exit."
  (declare (indent 0) (debug t))
  `(let ((decklet-review--trail-past nil)
         (decklet-review--trail-future nil))
     (with-current-buffer (get-buffer-create decklet-review-buffer-name)
       (unwind-protect
           (progn (decklet-review-mode) ,@body)
         (setq kill-buffer-query-functions nil)
         (kill-buffer (current-buffer))))))

;;; Session teardown

(ert-deftest decklet-test-review-quit-needs-attached-buffers-to-die ()
  "Quitting review closes attached popups and the DB, unless one refuses.
A popup that refuses to die keeps the review buffer and the DB alive."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (let ((review (get-buffer-create decklet-review-buffer-name)))
      (unwind-protect
          (decklet-test--with-temp-buffers (attached)
            (with-current-buffer review (decklet-review-mode))
            (with-current-buffer attached
              (decklet-card-back-mode 1)
              (add-hook 'kill-buffer-query-functions #'ignore nil t))
            (decklet-review-quit)
            (should (buffer-live-p review))
            (should (buffer-live-p attached))
            (should decklet-db--conn)
            (with-current-buffer attached
              (remove-hook 'kill-buffer-query-functions #'ignore t))
            (decklet-review-quit)
            (should-not (buffer-live-p review))
            (should-not (buffer-live-p attached))
            (should-not decklet-db--conn))
        (when (buffer-live-p review) (kill-buffer review))))))

;;; Grading

(ert-deftest decklet-test-review-daily-goal-hook-fires-once ()
  "The daily-goal hook fires on the rating that reaches the goal, not after."
  (decklet-test--with-temp-db
    (decklet--add-card "first")
    (decklet--add-card "second")
    (let* ((decklet-review-daily-goal 1)
           (decklet-review--trail-past nil)
           (decklet-review--trail-future nil)
           (hook-count 0)
           (decklet-review-daily-goal-reached-hook
            (list (lambda () (cl-incf hook-count)))))
      (decklet--refresh-counter)
      (cl-letf (((symbol-function 'decklet-review--advance) #'ignore))
        (dolist (word '("first" "second"))
          (setq decklet-current-card-id (decklet-test--card-id word))
          (decklet-review--handle-grade 3)))
      (should (= hook-count 1)))))

(ert-deftest decklet-test-review-delete-preserves-pending-order ()
  "Deleting the visible or a pending card preserves the remaining queue."
  (decklet-test--with-temp-db
    (dolist (word '("delete-current" "delete-next" "delete-pending" "delete-last"))
      (decklet--add-card word))
    (let* ((current (decklet-test--card-id "delete-current"))
           (next (decklet-test--card-id "delete-next"))
           (pending (decklet-test--card-id "delete-pending"))
           (last (decklet-test--card-id "delete-last"))
           (decklet-current-card-id current)
           (decklet-due-card-ids (list next pending last))
           (decklet-review--trail-past nil)
           (decklet-review--trail-future nil)
           (decklet-review--queue-context (decklet-review--queue-context))
           (decklet-review-next-card-hook nil)
           (major-mode 'decklet-review-mode))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'decklet-review--reset-ui-state) #'ignore)
                ((symbol-function 'decklet-review--render-buffer) #'ignore)
                ((symbol-function 'decklet--refresh-due-card-ids)
                 (lambda () (ert-fail "Deletion recollected the queue"))))
        (decklet-review-delete-card)
        (should-not (decklet-card-exists-p current))
        (should (eql decklet-current-card-id next))
        (should (equal decklet-due-card-ids (list pending last)))
        (decklet-delete-card pending)
        (should (equal decklet-due-card-ids (list last)))
        (decklet-review--advance)
        (should (eql decklet-current-card-id last))))))

;;; Undo

(ert-deftest decklet-test-review-undo-walks-back-and-confirm-walks-forward ()
  "Undo revisits earlier cards newest first without touching the DB.
Confirming the undone cards walks forward again, and review then
resumes with the card that was showing before the undo."
  (decklet-test--with-temp-db
    (dolist (word '("a" "b" "c")) (decklet--add-card word))
    (let ((a (decklet-test--card-id "a"))
          (b (decklet-test--card-id "b"))
          (c (decklet-test--card-id "c")))
      (decklet-test-review--in-session
        (setq decklet-current-card-id a
              decklet-due-card-ids (list b c))
        (decklet-review--handle-grade 3)
        (decklet-review--handle-grade 3)
        (should (eql c decklet-current-card-id))
        (let ((rated-a (decklet-get-card-meta a)))
          (decklet-review-undo)
          (should (eql b decklet-current-card-id))
          (decklet-review-undo)
          (should (eql a decklet-current-card-id))
          (should (equal rated-a (decklet-get-card-meta a))))
        (decklet-review-next-card)
        (should (eql b decklet-current-card-id))
        (decklet-review-next-card)
        (should (eql c decklet-current-card-id))
        (should (= 2 (length (decklet-test--read-log))))))))

(ert-deftest decklet-test-review-undo-skips-deleted-cards ()
  "Undo passes over a card deleted after it was reviewed."
  (decklet-test--with-temp-db
    (dolist (word '("a" "b" "c")) (decklet--add-card word))
    (let ((a (decklet-test--card-id "a"))
          (b (decklet-test--card-id "b"))
          (c (decklet-test--card-id "c")))
      (decklet-test-review--in-session
        (setq decklet-current-card-id a
              decklet-due-card-ids (list b c))
        (decklet-review--handle-grade 3)
        (decklet-review--handle-grade 3)
        (decklet-delete-card b)
        (decklet-review-undo)
        (should (eql a decklet-current-card-id))
        (decklet-review-next-card)
        (should (eql c decklet-current-card-id))))))

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

(ert-deftest decklet-test-review-rerate-drops-later-entries-of-same-card ()
  "Re-rating an earlier review retires the same card's later reviews.
Those were rated from the state the re-rate replaced, so keeping them
would leave a log rating the database no longer reflects."
  (decklet-test--with-temp-db
    (decklet--add-card "a")
    (decklet--add-card "b")
    (let ((a (decklet-test--card-id "a"))
          (b (decklet-test--card-id "b"))
          (decklet-due-card-ids nil)
          (decklet-review--trail-past nil)
          (decklet-review--trail-future nil))
      (cl-letf (((symbol-function 'decklet-review--advance)
                 (lambda ()
                   (setq decklet-current-card-id
                         (plist-get (decklet-review--trail-current-entry) :card-id))))
                ((symbol-function 'decklet-review--present-card)
                 (lambda (id) (setq decklet-current-card-id id))))
        (setq decklet-current-card-id a) (decklet-review--handle-grade 1)
        (setq decklet-current-card-id b) (decklet-review--handle-grade 3)
        (setq decklet-current-card-id a) (decklet-review--handle-grade 3)
        (setq decklet-current-card-id nil)
        (dotimes (_ 3) (decklet-review-undo))
        (should (eql a decklet-current-card-id))
        (decklet-review--handle-grade 4))
      ;; Only B is left to revisit; A's later rating is gone from the trail.
      (should (equal (list b) (mapcar (lambda (e) (plist-get e :card-id))
                                      decklet-review--trail-future)))
      (let* ((records (decklet-test--read-log))
             (rated-a (seq-filter (lambda (r) (and (equal (plist-get r :kind) "rated")
                                                   (eql (plist-get r :card_id) a)))
                                  records))
             (voided (mapcar (lambda (r) (plist-get r :voids))
                             (seq-filter (lambda (r) (equal (plist-get r :kind) "void"))
                                         records)))
             (effective (seq-remove (lambda (r) (memql (plist-get r :id) voided))
                                    rated-a)))
        ;; Both original ratings of A are voided; the re-rate stands alone
        ;; and matches the database.
        (should (equal '(4) (mapcar (lambda (r) (plist-get r :grade)) effective)))
        (should (= (plist-get (car effective) :post_stability)
                   (decklet-card-meta-stability (decklet-get-card-meta a))))))))

(ert-deftest decklet-test-review-undo-renders-from-pre-rating-meta ()
  "While undoing, the review buffer renders the card's pre-rating meta.
Re-rating applies the new grade to the trail entry's `:pre-meta', so the
predicted intervals must be computed from that same state rather than
from the already-rated row in the DB."
  (decklet-test--with-temp-db
    (let* ((id (plist-get (decklet--add-card "lucid") :card-id))
           ;; A second due card keeps the session open after the grade.
           (other (plist-get (decklet--add-card "vivid") :card-id))
           (seen nil))
      (with-current-buffer (get-buffer-create decklet-review-buffer-name)
        (unwind-protect
            (progn
              (decklet-review-mode)
              (setq decklet-current-card-id id
                    decklet-due-card-ids (list other))
              (cl-letf (((symbol-function 'run-hooks) #'ignore)
                        ((symbol-function 'decklet-review-component-rates)
                         (lambda ()
                           (push (cons decklet-current-card-id
                                       (decklet-card-meta-effective-state
                                        decklet-review--render-meta))
                                 seen)
                           "")))
                (decklet-review--handle-grade 3)
                (decklet-review-undo)
                ;; The DB row now holds the rated state...
                (should (eq :learning
                            (decklet-card-meta-effective-state
                             (decklet-get-card-meta id))))
                ;; ...but the undo render shows the card as it was
                ;; before the rating being replaced.
                (should (equal (cons id :new) (car seen)))))
          (setq kill-buffer-query-functions nil)
          (kill-buffer (current-buffer)))))))

(provide 'decklet-review-test)
;;; decklet-review-test.el ends here

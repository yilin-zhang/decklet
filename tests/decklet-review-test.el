;;; decklet-review-test.el --- Tests for decklet-review.el -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

(defmacro decklet-test-review--in-session (&rest body)
  "Run BODY in a live review buffer, killing it on exit."
  (declare (indent 0) (debug t))
  `(with-current-buffer (get-buffer-create decklet-review-buffer-name)
     (unwind-protect
         (progn (decklet-review-mode) ,@body)
       (setq kill-buffer-query-functions nil)
       (kill-buffer (current-buffer)))))

;;; Grading

(ert-deftest decklet-test-review-daily-goal-hook-fires-once ()
  "The daily-goal hook fires once, on the rating that reaches the goal."
  (decklet-test--with-temp-db
    (decklet--add-card "first")
    (decklet--add-card "second")
    (let* ((decklet-review-daily-goal 1)
           (hook-count 0)
           (decklet-review-daily-goal-reached-hook
            (list (lambda () (cl-incf hook-count)))))
      (decklet-review--refresh-counter)
      (cl-letf (((symbol-function 'decklet-review--advance) #'ignore))
        (dolist (word '("first" "second"))
          (setq decklet-current-card-id (decklet-test--card-id word))
          (decklet-review--handle-grade 3)))
      (should (= hook-count 1)))))

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
              decklet-review--due-card-ids (list b c))
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
              decklet-review--due-card-ids (list b c))
        (decklet-review--handle-grade 3)
        (decklet-review--handle-grade 3)
        (decklet-delete-card b)
        (decklet-review-undo)
        (should (eql a decklet-current-card-id))
        (decklet-review-next-card)
        (should (eql c decklet-current-card-id))))))

(ert-deftest decklet-test-review-rerate-after-undo-recomputes-from-pre-meta ()
  "Re-rating after undo starts from the card's state before the first rating.
The log voids the first record, and the new record's `pre_stability' is
nil, the state of a new card."
  (decklet-test--with-temp-db
    (decklet--add-card "w")
    (let ((decklet-current-card-id (decklet-test--card-id "w")))
      (cl-letf (((symbol-function 'decklet-review--advance) #'ignore)
                ((symbol-function 'decklet-review--reset-ui-state) #'ignore)
                ((symbol-function 'decklet-review--render-buffer) #'ignore))
        (decklet-review--handle-grade 1)     ; forward-rate Again
        (decklet-review-undo)                ; back to the card
        (decklet-review--handle-grade 3))    ; re-rate Good from the undone spot
      ;; The trail holds a single entry, now graded Good.
      (should (= 1 (length decklet-review--trail-past)))
      (should (= 3 (plist-get (car decklet-review--trail-past) :grade)))
      ;; The log holds rated(Again), rated(Good), then a void of the first.
      (let* ((records (decklet-test--read-log))
             (again (nth 0 records))
             (good (nth 1 records)))
        (should (equal (list "rated"
                             "rated"
                             "void")
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
          (b (decklet-test--card-id "b")))
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
predicted intervals must come from that state too."
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
                    decklet-review--due-card-ids (list other))
              (cl-letf (((symbol-function 'run-hooks) #'ignore)
                        ((symbol-function 'decklet-review-component-rates)
                         (lambda ()
                           (push (cons decklet-current-card-id
                                       (decklet-card-meta-effective-state
                                        (plist-get decklet-review--render-card :meta)))
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

;;; Queue invalidation

(ert-deftest decklet-test-review-retag-drops-pending-queue ()
  "Changing a card's tags drops the pending queue, which was grouped by tags."
  (decklet-test--with-temp-db
    (let* ((id (plist-get (decklet--add-card "rose") :card-id))
           (decklet-review--due-card-ids (list id)))
      (decklet-set-card-tags id '("medicine"))
      (should-not decklet-review--due-card-ids))))

(ert-deftest decklet-test-review-counter-refreshes-only-with-review-buffer ()
  "Deck mutations skip counter recomputation unless a review buffer is open.
When a review session is open, deleting, archiving and adding cards
keep `decklet-review--counter' up to date."
  (decklet-test--with-temp-db
    (let ((a (plist-get (decklet--add-card "alpha") :card-id))
          (b (plist-get (decklet--add-card "beta") :card-id)))
      ;; Outside review, mutations never touch the queue counters.
      (cl-letf (((symbol-function 'decklet-queue--counts)
                 (lambda () (error "Unexpected counter refresh"))))
        (decklet-archive-card a)
        (decklet-unarchive-card a)
        (decklet-delete-card b))
      ;; Inside a review session, mutations refresh the counters.
      (decklet-test-review--in-session
        (let ((c (plist-get (decklet--add-card "gamma") :card-id)))
          (should (= 2 (plist-get decklet-review--counter :new)))
          (decklet-archive-card c)
          (should (= 1 (plist-get decklet-review--counter :new)))
          (decklet-unarchive-card c)
          (should (= 2 (plist-get decklet-review--counter :new)))
          (decklet-delete-card a)
          (should (= 1 (plist-get decklet-review--counter :new))))))))

;;; Session startup and re-entry

(ert-deftest decklet-test-review-reentry-restarts-cleanly ()
  "Calling `decklet-review' with an open session quits it and starts fresh.
Start and quit hooks stay paired, and the trail starts empty with no fake skip."
  (decklet-test--with-temp-db
    (decklet--add-card "alpha")
    (decklet--add-card "beta")
    (let* ((events nil)
           (decklet-review-start-hook (list (lambda () (push 'start events))))
           (decklet-review-quit-hook (list (lambda () (push 'quit events)))))
      (unwind-protect
          (progn
            (decklet-review)
            (decklet-review-next-card)
            (should (= 1 (length decklet-review--trail-past)))
            (decklet-review)
            (should (equal '(start quit start) (nreverse events)))
            (should-not decklet-review--trail-past))
        (when-let* ((buf (get-buffer decklet-review-buffer-name)))
          (kill-buffer buf))))))

(provide 'decklet-review-test)
;;; decklet-review-test.el ends here

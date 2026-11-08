;;; decklet-db-test.el --- This file tests decklet-db.el. -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

;;; Card identity and fields

(ert-deftest decklet-test-db-mint-card-id-seeds-above-existing-max ()
  "A freshly seeded counter mints above the largest existing card id."
  (decklet-test--with-temp-db
    (let ((conn (decklet-db--ensure))
          (now (decklet--now)))
      (sqlite-execute
       conn
       "INSERT INTO cards (word, added_date, due, state, card_id)
        VALUES ('one', ?, ?, 'review', 9999999999),
               ('two', ?, ?, 'review', 8888888888);"
       (list now now now now))
      (setq decklet-db--last-card-id nil)
      (should (> (decklet-db--mint-card-id) 9999999999)))))

(ert-deftest decklet-test-db-scheduling-writes-keep-user-fields ()
  "Rating and renaming a card leave its hint, back and tags alone."
  (decklet-test--with-temp-db
    (decklet--add-card "lucid")
    (let ((id (decklet-test--card-id "lucid")))
      (decklet-set-card-hint id "adj.")
      (decklet-set-card-back id "clear and bright")
      (decklet-set-card-tags id '("reading"))
      (decklet-rate-card id 3)
      (decklet-set-card-word id "lucidity")
      (should (equal "adj." (decklet-get-card-hint id)))
      (should (equal "clear and bright" (decklet-get-card-back id)))
      (should (equal '("reading") (decklet-get-card-tags id))))))

;;; Connection lifecycle

(ert-deftest decklet-test-db-connection-lives-while-any-session-holds-it ()
  "The connection stays open until the last session holder lets go.
A holder lets go by being killed, by calling its disposer (twice is
harmless), or by turning off `decklet-card-back-mode', whose popup
buffer outlives the mode."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (decklet-test--with-temp-buffers (killed leased popup)
      (with-current-buffer killed (decklet-db-register-session-buffer))
      (with-current-buffer popup (decklet-card-back-mode 1))
      (let ((release (with-current-buffer leased
                       (decklet-db-acquire-session-buffer))))
        (kill-buffer killed)
        (should decklet-db--conn)
        (funcall release)
        (funcall release)
        (should decklet-db--conn)
        (with-current-buffer popup (decklet-card-back-mode -1))
        (should (buffer-live-p popup))
        (should-not decklet-db--conn)))))

(ert-deftest decklet-test-db-disconnect-needs-every-session-buffer-to-die ()
  "`decklet-disconnect' keeps the DB open if a session buffer refuses to die.
Once every buffer can die, it kills them all, closes the DB, and runs
the pre-disconnect hook exactly once."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (decklet-test--with-temp-buffers (plain stubborn)
      (dolist (buf (list plain stubborn))
        (with-current-buffer buf (decklet-db-register-session-buffer)))
      (with-current-buffer stubborn
        (add-hook 'kill-buffer-query-functions #'ignore nil t))
      (let* ((hook-count 0)
             (decklet-db-pre-disconnect-hook (list (lambda () (cl-incf hook-count)))))
        (should-error (decklet-disconnect) :type 'user-error)
        (should (buffer-live-p stubborn))
        (should decklet-db--conn)
        (should (= hook-count 0))
        (with-current-buffer stubborn
          (remove-hook 'kill-buffer-query-functions #'ignore t))
        (decklet-disconnect)
        (should-not (buffer-live-p plain))
        (should-not (buffer-live-p stubborn))
        (should-not decklet-db--conn)
        (should (= hook-count 1))))))

(ert-deftest decklet-test-db-pre-connect-hook-gates-each-connection ()
  "The pre-connect hook can refuse a connection, and runs once per opening."
  (decklet-test--with-temp-db
    (let ((decklet-db-pre-connect-hook (list (lambda () (user-error "Refused")))))
      (should-error (decklet-db--ensure) :type 'user-error)
      (should-not decklet-db--conn)
      (should-not (file-exists-p decklet-db-file)))
    (let* ((hook-count 0)
           (decklet-db-pre-connect-hook (list (lambda () (cl-incf hook-count)))))
      (decklet-db--ensure)
      (decklet-db--ensure)
      (should (= hook-count 1)))))

;;; Due-card selection and counts

(ert-deftest decklet-test-db-select-due-card-ids-honors-review-order ()
  "The due queue follows `decklet-review-order': learning, then new, then review."
  (decklet-test--with-temp-db
    (let* ((decklet-review-order '((learning (sort :due :asc))
                                   (new (sort :added :desc))
                                   (review (sort :due :asc))))
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

(ert-deftest decklet-test-db-counts-report-holdings-and-todays-allowance ()
  "Counts report what the deck holds and what today still offers.
A daily limit lowers the `-remaining' count and sets `:limited'."
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
        (should (= 1 (plist-get counts :new)))
        (should (= 1 (plist-get counts :new-remaining)))
        (should-not (plist-get counts :limited)))
      (let* ((decklet-review-order '(((learning relearning) (sort :due :asc))
                                     (review shuffle)
                                     (new (daily-limit 0 shuffle))))
             (counts (decklet-db--counts)))
        (should (= 1 (plist-get counts :new)))
        (should (= 0 (plist-get counts :new-remaining)))
        (should (plist-get counts :limited))))))

(ert-deftest decklet-test-db-review-order-validation ()
  "The review-order grammar accepts its canonical forms and rejects the rest."
  (dolist (order '((((learning relearning) (sort :due :asc))
                    (review (daily-limit 120 shuffle))
                    (new (spread (daily-limit 10 (sort :added :desc)))))
                   ;; A zero limit pauses a step for the day.
                   ((new (daily-limit 0 shuffle)))
                   (((new :tags (and "a" (not "b"))) shuffle)
                    ((review :tags (or "a" "c")) shuffle))))
    (decklet-db--review-validate-order order))
  (dolist (order '(;; One fallback rule per state.
                   ((review shuffle) (review (sort :due :asc)))
                   ((new shuffle) ((new review) shuffle))
                   ;; Learning cards sort only by :due or :added.
                   ((learning (sort :stability :desc)))
                   ;; A limit is a non-negative integer.
                   ((new (daily-limit -1 shuffle)))
                   ;; `spread' wraps `daily-limit', never the reverse.
                   ((review shuffle) (new (daily-limit 10 (spread shuffle))))
                   ;; A leading spread has nothing to spread into.
                   ((new (spread shuffle)))
                   ((review (daily-limit 10 (sort :due :sideways))))
                   ;; Malformed tag selectors and the old dotted syntax.
                   ((new :tags) shuffle)
                   (((new :tags (eval "a")) shuffle))
                   ((:new . shuffle))))
    (should-error (decklet-db--review-validate-order order))))

(ert-deftest decklet-test-db-daily-limit-is-a-whole-day-budget ()
  "A daily limit counts today's ratings, so cards graded earlier use it up.
Ratings from earlier days do not count, and a voided rating refunds
its slot."
  (decklet-test--with-temp-db
    (let ((decklet-review-order '((new (daily-limit 2 (sort :added :asc))))))
      (dolist (word '("new-a" "new-b" "new-c"))
        (decklet-test--add-card-meta word :state :new :last-review nil
                                     :timestamp "20250101T000000Z"))
      (decklet-test--log-rated "new" "20250101T000000Z")
      (should (equal (decklet-db--select-due-card-ids)
                     (mapcar #'decklet-test--card-id '("new-a" "new-b"))))
      (let ((first (decklet-test--log-rated "new")))
        (should (equal (decklet-db--select-due-card-ids)
                       (list (decklet-test--card-id "new-a"))))
        (decklet-test--log-rated "new")
        (should-not (decklet-db--select-due-card-ids))
        (decklet-review-log-append-void first))
      (should (equal (decklet-db--select-due-card-ids)
                     (list (decklet-test--card-id "new-a")))))))

(ert-deftest decklet-test-db-spread-distributes-step-through-queue ()
  "A spread step is interleaved into what the preceding steps gathered."
  (decklet-test--with-temp-db
    (let* ((decklet-review-order
            '((review (sort :due :asc))
              (new (spread (sort :added :asc)))))
           (now (current-time))
           (at (lambda (secs)
                 (decklet-test--ts (time-add now (seconds-to-time secs))))))
      (dolist (pair '(("review-a" . -300) ("review-b" . -200) ("review-c" . -100)))
        (decklet-test--add-card-meta
         (car pair) :state :review
         :added-date (funcall at -7200) :last-review (funcall at -3600)
         :due (funcall at (cdr pair))))
      (decklet-test--add-card-meta "new-a" :state :new :last-review nil
                                   :added-date (funcall at 0)
                                   :due (funcall at 0))
      ;; Three review cards plus one new card: the new one lands at the
      ;; half-stride offset rather than at either end.
      (should (equal (decklet-db--select-due-card-ids)
                     (mapcar #'decklet-test--card-id
                             '("review-a" "review-b" "new-a" "review-c")))))))

;;; Calendar due counts

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

(provide 'decklet-db-test)
;;; decklet-db-test.el ends here

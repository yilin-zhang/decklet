;;; decklet-db-test.el --- This file tests decklet-db.el. -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

;;; Input normalization

(ert-deftest decklet-test-db-normalize-word ()
  "Word normalization trims, collapses newlines, and rejects blanks."
  (should (string= (decklet-db--normalize-word "  lucid  ") "lucid"))
  (should (string= (decklet-db--normalize-word "  lucid\n\nrain  ") "lucid rain"))
  (should-error (decklet-db--normalize-word "  "))
  (should-error (decklet-db--normalize-word "")))

(ert-deftest decklet-test-db-normalize-optional-text ()
  "Optional text trims and maps blank/nil to nil."
  (should (equal (decklet-db--normalize-optional-text nil) nil))
  (should (equal (decklet-db--normalize-optional-text "  ") nil))
  (should (string= (decklet-db--normalize-optional-text "  foo bar  ") "foo bar")))

;;; Basic round-trip

(ert-deftest decklet-test-db-mint-card-id-is-positive-and-monotonic ()
  "Minted card ids are positive integers that strictly increase."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (let ((ids (cl-loop repeat 20 collect (decklet-db--mint-card-id))))
      (should (cl-every #'integerp ids))
      (should (> (car ids) 0))
      (should (equal ids (sort (copy-sequence ids) #'<)))
      (should (= (length ids) (length (delete-dups (copy-sequence ids))))))))

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

(ert-deftest decklet-test-db-upsert-then-select ()
  "A card upserted by word can be read back by word."
  (decklet-test--with-temp-db
    (decklet-test--add-card-meta "lucid")
    (let ((row (decklet-db--select-card-row-by-word "lucid")))
      (should row)
      (should (string= (plist-get row :word) "lucid")))))

;;; Connection lifecycle (session buffers)

(ert-deftest decklet-test-db-session-buffer-keeps-connection-open ()
  "A session buffer holds the connection open until it is killed."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (decklet-test--with-temp-buffers (buf)
      (with-current-buffer buf
	(decklet-db-register-session-buffer)
	(should decklet-db--session-buffer))
      (should (memq buf (decklet-db--session-buffers)))
      (should decklet-db--conn)
      (kill-buffer buf)
      (should-not decklet-db--conn))))

(ert-deftest decklet-test-db-kill-one-session-buffer-keeps-others ()
  "Killing one session buffer leaves the others and the DB alive."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (decklet-test--with-temp-buffers (review edit attached)
      (with-current-buffer review (decklet-review-mode))
      (with-current-buffer edit (decklet-edit-mode))
      (with-current-buffer attached (decklet-card-back-mode 1))
      (kill-buffer review)
      (should-not (buffer-live-p review))
      (should (buffer-live-p edit))
      (should (buffer-live-p attached))
      (should decklet-db--conn))))

(ert-deftest decklet-test-db-release-lease-disconnects-when-last ()
  "Releasing the last lease disconnects, without killing the buffer."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (decklet-test--with-temp-buffers (buf)
      (let ((release (with-current-buffer buf
                       (decklet-db-acquire-session-buffer))))
        (should decklet-db--conn)
        (funcall release)
        (should (buffer-live-p buf))
        (should-not (buffer-local-value 'decklet-db--session-buffer buf))
        (should-not (memq buf (decklet-db--session-buffers)))
        (should-not decklet-db--conn)))))

(ert-deftest decklet-test-db-release-lease-keeps-connection-for-others ()
  "Releasing one lease leaves the connection open for the remaining ones."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (decklet-test--with-temp-buffers (kept released)
      (with-current-buffer kept (decklet-db-register-session-buffer))
      (let ((release (with-current-buffer released
                       (decklet-db-acquire-session-buffer))))
        (funcall release)
        (should decklet-db--conn)
        (should (memq kept (decklet-db--session-buffers)))))))

(ert-deftest decklet-test-db-release-lease-is-idempotent ()
  "A disposer can be called twice, and after its buffer is dead."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (decklet-test--with-temp-buffers (buf)
      (let ((release (with-current-buffer buf
                       (decklet-db-acquire-session-buffer))))
        (funcall release)
        (funcall release)
        (should-not decklet-db--conn)
        (kill-buffer buf)
        (funcall release)))))

(ert-deftest decklet-test-db-kill-buffer-still-releases-lease ()
  "Killing a buffer that never releases its lease still disconnects."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (decklet-test--with-temp-buffers (buf)
      (with-current-buffer buf (decklet-db-acquire-session-buffer))
      (should decklet-db--conn)
      (kill-buffer buf)
      (should-not decklet-db--conn))))

(ert-deftest decklet-test-db-card-back-mode-off-releases-lease ()
  "Turning off `decklet-card-back-mode' releases the lease it acquired.
The popup buffer outlives the mode, so the connection must not be
left open with nothing holding it."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (decklet-test--with-temp-buffers (buf)
      (with-current-buffer buf
        (decklet-card-back-mode 1)
        (should decklet-db--session-buffer)
        (should decklet-db--conn)
        (decklet-card-back-mode -1)
        (should-not decklet-db--session-buffer))
      (should (buffer-live-p buf))
      (should-not decklet-db--conn))))

(ert-deftest decklet-test-db-disconnect-kills-session-buffers-and-closes-db ()
  "`decklet-disconnect' kills session buffers and closes the connection.
It fires the pre-disconnect hook exactly once."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (decklet-test--with-temp-buffers (buf-a buf-b)
      (dolist (buf (list buf-a buf-b))
	(with-current-buffer buf (decklet-db-register-session-buffer)))
      (let* ((hook-count 0)
	     (decklet-db-pre-disconnect-hook (list (lambda () (cl-incf hook-count)))))
	(decklet-disconnect)
	(should-not (buffer-live-p buf-a))
	(should-not (buffer-live-p buf-b))
	(should-not decklet-db--conn)
	(should (= hook-count 1))))))

(ert-deftest decklet-test-db-disconnect-aborts-when-buffer-cancels-kill ()
  "A session buffer refusing to die aborts disconnection.
The connection stays open and the pre-disconnect hook does not run."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (decklet-test--with-temp-buffers (buf)
      (with-current-buffer buf
	(decklet-db-register-session-buffer)
	(add-hook 'kill-buffer-query-functions #'ignore nil t))
      (let* ((hook-count 0)
	     (decklet-db-pre-disconnect-hook (list (lambda () (cl-incf hook-count)))))
	(should-error (decklet-disconnect) :type 'user-error)
	(should (buffer-live-p buf))
	(should decklet-db--conn)
	(should (= hook-count 0))))))

;;; Archive / unarchive

(ert-deftest decklet-test-db-archive-and-unarchive ()
  "Archiving hides a card from the active set; unarchiving restores it."
  (decklet-test--with-temp-db
    (let ((id (decklet-test--add-card-meta "archive-me")))
      (should (= 1 (length (decklet-db--select-card-rows 'all nil))))
      (decklet-db--archive-card id (decklet-test--ts (current-time)))
      (should (= 0 (length (decklet-db--select-card-rows 'all nil))))
      (should (= 1 (length (decklet-db--select-card-rows 'archived nil))))
      (decklet-db--unarchive-card id)
      (should (= 1 (length (decklet-db--select-card-rows 'all nil)))))))

;;; Due-card selection and counts

(ert-deftest decklet-test-db-select-due-card-ids-honors-review-order ()
  "The due queue follows `decklet-review-order': learning, then new, then review."
  (decklet-test--with-temp-db
    (let* ((decklet-review-order '((:learning . (sort :due :asc))
                                   (:new     . (sort :added :desc))
                                   (:review  . (sort :due :asc))))
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

(ert-deftest decklet-test-db-counts-per-slot ()
  "`decklet-db--counts' tallies reviewed-today, due-review, due-learning, and new."
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
        (should (= 1 (plist-get counts :new)))))))

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

;;; Review-order validation

(ert-deftest decklet-test-db-review-order-rejects-duplicate-target ()
  "A target used in more than one order step is rejected."
  (should-error
   (decklet-db--review-validate-order
    '((:review . shuffle) (:review . (sort :due :asc))))))

(ert-deftest decklet-test-db-review-order-rejects-invalid-learning-sort-field ()
  "Learning cards may only be sorted by :due or :added."
  (should-error
   (decklet-db--review-validate-order
    '((:learning . (sort :stability :desc))))))

(ert-deftest decklet-test-db-review-order-accepts-limit-and-spread ()
  "Daily limits and spread placement validate in their canonical nesting."
  (decklet-db--review-validate-order
   '(((:learning :relearning) . (sort :due :asc))
     (:review . (daily-limit 120 shuffle))
     (:new    . (spread (daily-limit 10 (sort :added :desc))))))
  (decklet-db--review-validate-order
   '((:review . shuffle)
     (:new    . (spread shuffle))))
  ;; A zero limit is a legitimate way to pause a step for the day.
  (decklet-db--review-validate-order
   '((:new . (daily-limit 0 shuffle)))))

(ert-deftest decklet-test-db-review-order-rejects-malformed-limit-and-spread ()
  "The spec grammar rejects bad limits and non-canonical nesting."
  ;; A limit must be a non-negative integer.
  (should-error
   (decklet-db--review-validate-order '((:new . (daily-limit -1 shuffle)))))
  (should-error
   (decklet-db--review-validate-order '((:new . (daily-limit 1.5 shuffle)))))
  ;; `spread' belongs outside `daily-limit', not inside it.
  (should-error
   (decklet-db--review-validate-order
    '((:review . shuffle)
      (:new . (daily-limit 10 (spread shuffle))))))
  ;; Nested wrappers of the same kind are meaningless.
  (should-error
   (decklet-db--review-validate-order
    '((:review . shuffle)
      (:new . (spread (spread shuffle))))))
  ;; A spread step placed first has nothing to distribute into.
  (should-error
   (decklet-db--review-validate-order '((:new . (spread shuffle)))))
  ;; The inner ordering still has to be a valid BASE.
  (should-error
   (decklet-db--review-validate-order
    '((:review . (daily-limit 10 (sort :due :sideways)))))))

(ert-deftest decklet-test-db-daily-limit-truncates-step ()
  "A step hands out at most its daily limit."
  (decklet-test--with-temp-db
    (let ((decklet-review-order '((:new . (daily-limit 2 (sort :added :asc)))))
          (ts "20250101T000000Z"))
      (dolist (word '("new-a" "new-b" "new-c"))
        (decklet-test--add-card-meta word :state :new :last-review nil
                                     :timestamp ts))
      (should (equal (decklet-db--select-due-card-ids)
                     (mapcar #'decklet-test--card-id '("new-a" "new-b")))))))

(ert-deftest decklet-test-db-daily-limit-subtracts-todays-ratings ()
  "The limit is a whole-day budget, so cards already graded today count."
  (decklet-test--with-temp-db
    (let ((decklet-review-order '((:new . (daily-limit 2 (sort :added :asc)))))
          (ts "20250101T000000Z"))
      (dolist (word '("new-a" "new-b" "new-c"))
        (decklet-test--add-card-meta word :state :new :last-review nil
                                     :timestamp ts))
      (decklet-test--log-rated "new")
      (setq decklet-review-log--scan-cache nil)
      (should (equal (decklet-db--select-due-card-ids)
                     (list (decklet-test--card-id "new-a"))))
      ;; A second rating exhausts the day's allowance entirely.
      (decklet-test--log-rated "new")
      (setq decklet-review-log--scan-cache nil)
      (should (null (decklet-db--select-due-card-ids))))))

(ert-deftest decklet-test-db-daily-limit-ignores-voided-ratings ()
  "An undone rating gives its allowance back."
  (decklet-test--with-temp-db
    (let ((decklet-review-order '((:new . (daily-limit 1 (sort :added :asc)))))
          (ts "20250101T000000Z"))
      (decklet-test--add-card-meta "new-a" :state :new :last-review nil
                                   :timestamp ts)
      (let ((id (decklet-test--log-rated "new")))
        (setq decklet-review-log--scan-cache nil)
        (should (null (decklet-db--select-due-card-ids)))
        (decklet-review-log-append-void id))
      (setq decklet-review-log--scan-cache nil)
      (should (equal (decklet-db--select-due-card-ids)
                     (list (decklet-test--card-id "new-a")))))))

(ert-deftest decklet-test-db-spread-distributes-step-through-queue ()
  "A spread step is interleaved into what the preceding steps gathered."
  (decklet-test--with-temp-db
    (let* ((decklet-review-order
            '((:review . (sort :due :asc))
              (:new    . (spread (sort :added :asc)))))
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

(ert-deftest decklet-test-db-counts-report-remaining-allowance ()
  "Counts report both what the deck holds and what today still offers."
  (decklet-test--with-temp-db
    (let ((decklet-review-order '((:new . (daily-limit 2 (sort :added :asc)))))
          (ts "20250101T000000Z"))
      (dolist (word '("new-a" "new-b" "new-c"))
        (decklet-test--add-card-meta word :state :new :last-review nil
                                     :timestamp ts))
      (let ((counts (decklet-db--counts)))
        (should (= 3 (plist-get counts :new)))
        (should (= 2 (plist-get counts :new-remaining)))
        (should (plist-get counts :limited)))
      ;; Without a limit nothing is held back.
      (let* ((decklet-review-order '((:new . (sort :added :asc))))
             (counts (decklet-db--counts)))
        (should (= 3 (plist-get counts :new-remaining)))
        (should-not (plist-get counts :limited))))))

;;; Card back — DB layer

(ert-deftest decklet-test-db-card-back-update-select-and-isolation ()
  "Card backs round-trip without interfering with scheduling.
Blank content normalizes to nil, and scheduling upserts preserve the back."
  (decklet-test--with-temp-db
    (let ((id (decklet-test--add-card-meta "lucid" :state :new
                                           :timestamp "20250101T000000Z")))
      (should (null (decklet-db--select-card-back id)))
      (decklet-db--update-back id "clear and bright")
      (should (string= "clear and bright" (decklet-db--select-card-back id)))
      (decklet-db--update-back id "   ")
      (should (null (decklet-db--select-card-back id)))
      (decklet-db--update-back id "example sentence")
      (decklet-db--upsert-card "lucid"
                               (decklet-test--make-card-meta :timestamp "20250102T000000Z"))
      (should (string= "example sentence" (decklet-db--select-card-back id))))))

(provide 'decklet-db-test)
;;; decklet-db-test.el ends here

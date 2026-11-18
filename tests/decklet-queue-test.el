;;; decklet-queue-test.el --- This file tests decklet-queue.el. -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

(defun decklet-queue-test--new (word &rest tags)
  "Create a new card for WORD with TAGS and return its card id."
  (let ((id (decklet-test--add-card-meta word :last-review nil
                                         :timestamp "20250101T000000Z")))
    (decklet-set-card-tags id tags)
    id))

;;; Order and placement

(ert-deftest decklet-test-queue-honors-review-order ()
  "The due queue follows `decklet-review-order': learning, then new, then review."
  (decklet-test--with-temp-db
    (let* ((decklet-review-order '(((state :learning) (sort :due :asc))
                                   ((state :new) (sort :added :desc))
                                   ((state :review) (sort :due :asc))))
           (now (current-time))
           (at (lambda (secs) (decklet-test--ts (time-add now (seconds-to-time secs))))))
      (decklet-test--add-card-meta
       "learn-a" :added-date (funcall at -7200) :last-review (funcall at -3600)
       :due (funcall at -600) :state :learning)
      (decklet-test--add-card-meta
       "new-a" :last-review nil :added-date (funcall at 0) :due (funcall at 0))
      (decklet-test--add-card-meta
       "review-a" :added-date (funcall at -7200) :last-review (funcall at -3600)
       :due (funcall at 1800))
      (should (equal (decklet-queue--due-card-ids)
                     (mapcar #'decklet-test--card-id '("learn-a" "new-a" "review-a")))))))

(ert-deftest decklet-test-queue-spread-distributes-group-through-queue ()
  "A spread group is interleaved into what the preceding groups gathered."
  (decklet-test--with-temp-db
    (let* ((decklet-review-order
            '(((state :review) (sort :due :asc))
              ((state :new) (sort :added :asc) spread)))
           (now (current-time))
           (at (lambda (secs)
                 (decklet-test--ts (time-add now (seconds-to-time secs))))))
      (dolist (pair '(("review-a" . -300) ("review-b" . -200) ("review-c" . -100)))
        (decklet-test--add-card-meta
         (car pair) :added-date (funcall at -7200) :last-review (funcall at -3600)
         :due (funcall at (cdr pair))))
      (decklet-test--add-card-meta "new-a" :last-review nil
                                   :added-date (funcall at 0)
                                   :due (funcall at 0))
      ;; Three review cards plus one new card: the new one lands at the
      ;; half-stride offset rather than at either end.
      (should (equal (decklet-queue--due-card-ids)
                     (mapcar #'decklet-test--card-id
                             '("review-a" "review-b" "new-a" "review-c")))))))

(ert-deftest decklet-test-queue-first-matching-group-owns-card ()
  "A card belongs to the first group whose filter matches it.
It stays there when that group's limit is spent, so it never reaches a
later group that would also match."
  (decklet-test--with-temp-db
    (let ((decklet-review-order
           '(((and (state :new) (tag "botany")) (limit 1))
             ((and (state :new) (tag "medicine")) shuffle)
             ((state :new) shuffle)))
          (rose (decklet-queue-test--new "rose" "botany"))
          (_shared (decklet-queue-test--new "shared" "botany" "medicine"))
          (medical (decklet-queue-test--new "medical" "medicine"))
          (plain (decklet-queue-test--new "plain")))
      (should (equal (decklet-queue--due-card-ids) (list rose medical plain)))
      (should (= (plist-get (decklet-queue--counts) :new-remaining) 3)))))

(ert-deftest decklet-test-queue-filters-cover-every-state ()
  "Filters combine states and tags with `and', `or' and `not'."
  (decklet-test--with-temp-db
    (let ((decklet-review-order
           '(((and (state :learning :relearning) (tag "botany") (not (tag "paused")))
              (sort :due :asc))
             ((and (state :review) (or (tag "medicine") (tag "astronomy"))) shuffle)
             ((and (state :new) (tag "botany")) shuffle)))
          (expected nil))
      (dolist (state '(:learning :relearning :review))
        (let ((id (decklet-test--add-card-meta (symbol-name state) :state state
                                               :timestamp "20250101T000000Z")))
          (decklet-set-card-tags id (if (eq state :review) '("medicine") '("botany")))
          (push id expected)))
      (push (decklet-queue-test--new "new" "botany") expected)
      ;; A paused learning card matches no group, so it is never offered.
      (decklet-set-card-tags
       (decklet-test--add-card-meta "blocked" :state :learning
                                    :timestamp "20250101T000000Z")
       '("botany" "paused"))
      (should (equal (sort (decklet-queue--due-card-ids) #'<) (sort expected #'<))))))

(ert-deftest decklet-test-queue-review-order-validation ()
  "The review-order grammar accepts its documented forms and rejects the rest."
  (dolist (order '((((state :learning :relearning) (sort :due :asc))
                    ((state :review) shuffle (limit 120))
                    ((state :new) (sort :added :desc) (limit 10) spread))
                   ;; A zero limit pauses a group, and operations are optional.
                   (((state :new) (limit 0)) ((state :review)))
                   ;; Filters nest, and any field sorts any group.
                   (((and (state :new) (tag "a") (not (tag "b"))) shuffle)
                    ((or (state :review) (tag "c")) (sort :stability :desc)))))
    (decklet-queue--compile-order order))
  (dolist (order '(;; States are keywords.
                   (((state new)))
                   (((tag "bad tag")))
                   (((and)))
                   (((not (tag "a") (tag "b"))))
                   (((state :new) (sort :due :sideways)))
                   (((state :new) (limit -1)))
                   ;; `spread' only places a group, so it comes last.
                   (((state :new) spread shuffle))
                   ;; The old (SOURCE SPEC) syntax.
                   ((new shuffle))
                   ((:new . shuffle))))
    (should-error (decklet-queue--compile-order order))))

;;; Daily limits and counters

(ert-deftest decklet-test-queue-daily-limit-is-a-whole-day-budget ()
  "A daily limit counts today's ratings, so cards graded earlier use it up.
Ratings from earlier days do not count, and a voided rating refunds
its slot."
  (decklet-test--with-temp-db
    (let ((decklet-review-order '(((state :new) (sort :added :asc) (limit 2)))))
      (dolist (word '("new-a" "new-b" "new-c"))
        (decklet-test--add-card-meta word :last-review nil
                                     :timestamp "20250101T000000Z"))
      (decklet-test--log-rated "new" "20250101T000000Z")
      (should (equal (decklet-queue--due-card-ids)
                     (mapcar #'decklet-test--card-id '("new-a" "new-b"))))
      (let ((first (decklet-test--log-rated "new")))
        (should (equal (decklet-queue--due-card-ids)
                       (list (decklet-test--card-id "new-a"))))
        (decklet-test--log-rated "new")
        (should-not (decklet-queue--due-card-ids))
        (decklet-review-log-append-void first))
      (should (equal (decklet-queue--due-card-ids)
                     (list (decklet-test--card-id "new-a")))))))

(ert-deftest decklet-test-queue-retrospective-budget-and-restart ()
  "Current tags regroup today's history, including after restarting the DB."
  (decklet-test--with-temp-db
    (let* ((decklet-review-order
            '(((and (state :new) (tag "botany")) shuffle (limit 1))
              ((and (state :new) (tag "medicine")) shuffle (limit 1))
              ((state :new) shuffle (limit 5))))
           (rated (decklet-queue-test--new "rose" "botany"))
           (plant (decklet-queue-test--new "lily" "botany"))
           (medical (decklet-queue-test--new "itis" "medicine")))
      (decklet-rate-card rated 4)
      (should (equal (decklet-queue--due-card-ids) (list medical)))
      (let ((before (decklet-test--read-log)))
        (decklet-set-card-tags rated '("medicine"))
        (should (equal before (decklet-test--read-log))))
      (should (equal (decklet-queue--due-card-ids) (list plant)))
      (should (= (plist-get (decklet-queue--counts) :new-remaining) 1))
      (decklet-db--disconnect)
      (setq decklet-review-log--scan-cache nil)
      (should (equal (decklet-queue--due-card-ids) (list plant)))
      (let ((future (time-add (decklet--next-day-start-time) 60)))
        (should (= (length (plist-get (decklet-queue--plan future) :items)) 2))))))

(ert-deftest decklet-test-queue-counts-report-due-cards-and-todays-allowance ()
  "Counts report the cards due today and what today still offers.
A daily limit lowers the `-remaining' count and sets `:limited'."
  (decklet-test--with-temp-db
    (let* ((now (current-time))
           (ts-now (decklet-test--ts now))
           (ts-old "20250101T000000Z")
           (ts-future (decklet-test--ts (time-add now (seconds-to-time 86400)))))
      (decklet-test--add-card-meta "reviewed" :added-date ts-old :last-review ts-now
                                   :due ts-future)
      (decklet-test--add-card-meta "due-review" :timestamp ts-old)
      (decklet-test--add-card-meta "due-learning" :timestamp ts-old :state :learning)
      (decklet-test--add-card-meta "new-card" :last-review nil :timestamp ts-old)
      ;; Not due yet, so neither the queue nor the counters include it.
      (decklet-test--add-card-meta "new-later" :last-review nil :added-date ts-old
                                   :due ts-future)
      (let ((counts (decklet-queue--counts)))
        (should (= 1 (plist-get counts :reviewed)))
        (should (= 1 (plist-get counts :due-review)))
        (should (= 1 (plist-get counts :due-learning)))
        (should (= 1 (plist-get counts :new)))
        (should (= 1 (plist-get counts :new-remaining)))
        (should-not (plist-get counts :limited)))
      (let* ((decklet-review-order '(((state :learning :relearning) (sort :due :asc))
                                     ((state :review) shuffle)
                                     ((state :new) shuffle (limit 0))))
             (counts (decklet-queue--counts)))
        (should (= 1 (plist-get counts :new)))
        (should (= 0 (plist-get counts :new-remaining)))
        (should (plist-get counts :limited))))))

(ert-deftest decklet-test-queue-counter-refresh-keeps-shuffle ()
  "Refreshing counters preserves a previously planned randomized queue."
  (decklet-test--with-temp-db
    (let ((decklet-review-order '(((state :new) shuffle (limit 2)))))
      (dotimes (i 8) (decklet-queue-test--new (format "word-%s" i)))
      (let ((ids (decklet-queue--due-card-ids)))
        (cl-letf (((symbol-function 'decklet-queue--shuffle)
                   (lambda (_) (error "Unexpected reshuffle"))))
          (should (= (plist-get (decklet-queue--counts) :new-remaining) 2))
          (should (equal ids (decklet-queue--due-card-ids))))))))

(provide 'decklet-queue-test)
;;; decklet-queue-test.el ends here

;;; decklet-tags-test.el --- Tests for tags and grouped review -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

(defun decklet-test-tags--new (word &rest tags)
  "Create a new WORD with TAGS and return its card id."
  (let ((id (decklet-test--add-card-meta word :state :new :last-review nil
                                         :timestamp "20250101T000000Z")))
    (decklet-set-card-tags id tags)
    id))

(ert-deftest decklet-test-tags-normalize-and-validate ()
  "Tags are stored sorted without duplicates; invalid tags are rejected."
  (decklet-test--with-temp-db
    (let ((id (decklet-test-tags--new "rose" "botany")))
      (should (equal (decklet-add-card-tags id '("flower" "botany"))
                     '("botany" "flower")))
      (decklet-remove-card-tags id '("flower"))
      (should (equal (decklet-list-tags) '("botany")))
      (should-error (decklet-set-card-tags id '("bad tag")))
      (should (equal (decklet-get-card-tags id) '("botany"))))))

(ert-deftest decklet-test-tags-migrates-existing-schema ()
  "Adding tags preserves an existing card and its scheduling data."
  (decklet-test--with-temp-db
    (let ((id (decklet-test-tags--new "legacy")))
      (sqlite-execute (decklet-db--ensure) "ALTER TABLE cards DROP COLUMN tags;")
      (decklet-db--disconnect)
      (should (equal (decklet-get-card-word id) "legacy"))
      (should-not (decklet-get-card-tags id))
      (decklet-set-card-tags id '("reading"))
      (should (equal (decklet-get-card-tags id) '("reading"))))))

(ert-deftest decklet-test-tags-batch-import-merges-tags ()
  "Re-adding a word in a batch merges its tags with the existing ones."
  (decklet-test--with-temp-db
    (let ((id (decklet-test-tags--new "rose" "reading")))
      (with-temp-buffer
        (insert "rose\n:botany\n# a flower\nlily\n:botany\n")
        (cl-letf (((symbol-function 'quit-window) #'ignore))
          (decklet-add-card-batch-confirm)))
      (should (equal (decklet-get-card-tags id) '("botany" "reading")))
      (should (equal (decklet-get-card-tags (decklet-get-card-id-by-word "lily")) '("botany"))))))

(ert-deftest decklet-test-tags-first-matching-step-owns-card ()
  "A card belongs to the first step whose filter matches it.
It stays there when that step's limit is spent, so it never reaches a
later step that would also match."
  (decklet-test--with-temp-db
    (let ((decklet-review-order
           '(((and (state :new) (tag "botany")) (limit 1))
             ((and (state :new) (tag "medicine")) shuffle)
             ((state :new) shuffle)))
          (rose (decklet-test-tags--new "rose" "botany"))
          (_shared (decklet-test-tags--new "shared" "botany" "medicine"))
          (medical (decklet-test-tags--new "medical" "medicine"))
          (plain (decklet-test-tags--new "plain")))
      (should (equal (decklet-db--select-due-card-ids) (list rose medical plain)))
      (should (= (plist-get (decklet-db--counts) :new-remaining) 3)))))

(ert-deftest decklet-test-tags-filters-cover-every-state ()
  "Filters combine states and tags with `and', `or' and `not'."
  (decklet-test--with-temp-db
    (let ((decklet-review-order
           '(((and (state :learning :relearning) (tag "botany") (not (tag "paused")))
              (sort :due :asc))
             ((and (state :review) (or (tag "medicine") (tag "astronomy"))) shuffle)
             ((and (state :new) (tag "botany")) shuffle)))
          (expected nil))
      (dolist (state '(:learning :relearning :review :new))
        (let ((id (decklet-test--add-card-meta
                   (symbol-name state) :state state
                   :last-review (unless (eq state :new) "20250101T000000Z")
                   :timestamp "20250101T000000Z")))
          (decklet-set-card-tags id (if (eq state :review) '("medicine") '("botany")))
          (push id expected)))
      ;; A paused learning card matches no step, so it is never offered.
      (decklet-set-card-tags
       (decklet-test--add-card-meta "blocked" :state :learning
                                    :last-review "20250101T000000Z"
                                    :timestamp "20250101T000000Z")
       '("botany" "paused"))
      (should (equal (sort (decklet-db--select-due-card-ids) #'<) (sort expected #'<))))))

(ert-deftest decklet-test-tags-retrospective-budget-and-restart ()
  "Current tags regroup today's history, including after restarting the DB."
  (decklet-test--with-temp-db
    (let* ((decklet-review-order
            '(((and (state :new) (tag "botany")) shuffle (limit 1))
              ((and (state :new) (tag "medicine")) shuffle (limit 1))
              ((state :new) shuffle (limit 5))))
           (rated (decklet-test-tags--new "rose" "botany"))
           (plant (decklet-test-tags--new "lily" "botany"))
           (medical (decklet-test-tags--new "itis" "medicine")))
      (decklet-rate-card rated 4)
      (should (equal (decklet-db--select-due-card-ids) (list medical)))
      (let ((before (decklet-test--read-log)))
        (decklet-set-card-tags rated '("medicine"))
        (should (equal before (decklet-test--read-log))))
      (should (equal (decklet-db--select-due-card-ids) (list plant)))
      (should (= (plist-get (decklet-db--counts) :new-remaining) 1))
      (decklet-db--disconnect)
      (setq decklet-review-log--scan-cache nil)
      (should (equal (decklet-db--select-due-card-ids) (list plant)))
      (let ((future (time-add (decklet--next-day-start-time) 60)))
        (should (= (length (plist-get (decklet-db--review-plan future) :items)) 2))))))

(ert-deftest decklet-test-tags-counter-reuses-shuffle ()
  "Refreshing counters preserves a previously planned randomized queue."
  (decklet-test--with-temp-db
    (let ((decklet-review-order '(((state :new) shuffle (limit 2)))))
      (dotimes (i 8) (decklet-test-tags--new (format "word-%s" i)))
      (let ((ids (decklet-db--select-due-card-ids)))
        (cl-letf (((symbol-function 'decklet--shuffle-list)
                   (lambda (_) (error "Unexpected reshuffle"))))
          (should (= (plist-get (decklet-db--counts) :new-remaining) 2))
          (should (equal ids (decklet-db--select-due-card-ids))))))))

(ert-deftest decklet-test-tags-retag-drops-pending-queue ()
  "Changing a card's tags drops the pending queue, which was grouped by tags."
  (decklet-test--with-temp-db
    (let* ((id (decklet-test-tags--new "rose" "botany"))
           (decklet-due-card-ids (list id)))
      (decklet-set-card-tags id '("medicine"))
      (should-not decklet-due-card-ids))))

(provide 'decklet-tags-test)
;;; decklet-tags-test.el ends here

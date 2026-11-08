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

(ert-deftest decklet-test-tags-selector-ownership-before-limit ()
  "Later tag selectors reserve their whole group before fallback selection."
  (decklet-test--with-temp-db
    (let* ((decklet-review-order
            '((new (sort :added :asc))
              ((new :tags "botany") (spread (daily-limit 1 (sort :added :asc))))))
           (plain (decklet-test-tags--new "plain"))
           (rose (decklet-test-tags--new "rose" "botany")))
      (decklet-test-tags--new "lily" "botany")
      (should (equal (decklet-db--select-due-card-ids) (list plain rose)))
      (should (= (plist-get (decklet-db--counts) :new-remaining) 2))
      (setcar (cdr (cadr (cadr decklet-review-order))) '(daily-limit 0 shuffle))
      (should (equal (decklet-db--select-due-card-ids) (list plain))))))

(ert-deftest decklet-test-tags-overlap-first-selector-wins ()
  "Matching cards never spill to another selector when their owner is paused."
  (decklet-test--with-temp-db
    (let ((decklet-review-order
           '((new shuffle)
             ((new :tags "botany") (daily-limit 0 shuffle))
             ((new :tags "medicine") shuffle))))
      (decklet-test-tags--new "shared" "botany" "medicine")
      (let ((id (decklet-test-tags--new "medical" "medicine")))
        (should (equal (decklet-db--select-due-card-ids) (list id)))))))

(ert-deftest decklet-test-tags-selector-all-states-and-expressions ()
  "Selectors apply consistently to every state and to combined sources."
  (decklet-test--with-temp-db
    (let ((decklet-review-order
           '((((learning relearning) :tags (and "botany" (not "paused")))
              (sort :due :asc))
             ((review :tags (or "medicine" "astronomy")) shuffle)
             ((new :tags "botany") shuffle)))
          (expected nil))
      (dolist (state '(:learning :relearning :review :new))
        (let ((id (decklet-test--add-card-meta
                   (symbol-name state) :state state
                   :last-review (unless (eq state :new) "20250101T000000Z")
                   :timestamp "20250101T000000Z")))
          (decklet-set-card-tags id (if (eq state :review) '("medicine") '("botany")))
          (push id expected)))
      (decklet-test-tags--new "blocked" "paused")
      (should (equal (sort (decklet-db--select-due-card-ids) #'<) (sort expected #'<))))))

(ert-deftest decklet-test-tags-retrospective-budget-and-restart ()
  "Current tags regroup today's history, including after restarting the DB."
  (decklet-test--with-temp-db
    (let* ((decklet-review-order
            '((new (daily-limit 5 shuffle))
              ((new :tags "botany") (daily-limit 1 shuffle))
              ((new :tags "medicine") (daily-limit 1 shuffle))))
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
    (let ((decklet-review-order '((new (daily-limit 2 shuffle)))))
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

;;; decklet-tags-test.el --- Tests for tags and grouped review -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

(defun decklet-test-tags--new (word &rest tags)
  "Create a new WORD with TAGS and return its card id."
  (let ((id (decklet-test--add-card-meta word :state :new :last-review nil
                                         :timestamp "20250101T000000Z")))
    (decklet-set-card-tags id tags)
    id))

(ert-deftest decklet-test-tags-storage-and-events ()
  "Tags normalize, survive scheduling and rename, and emit real changes only."
  (decklet-test--with-temp-db
    (let* ((id (decklet-test-tags--new "rose" "botany"))
           (events nil)
           (decklet-cards-field-updated-functions
            (list (lambda (batch) (setq events (append events batch))))))
      (should (equal (decklet-add-card-tags id '("flower" "botany"))
                     '("botany" "flower")))
      (decklet-set-card-tags id '("flower" "botany"))
      (should (= (length events) 1))
      (should (eq 'tags (plist-get (car events) :field)))
      (decklet-rate-card id 4)
      (decklet-set-card-word id "rose flower")
      (should (equal (plist-get (decklet-get-card id) :tags) '("botany" "flower")))
      (decklet-remove-card-tags id '("flower"))
      (should (equal (decklet-list-tags) '("botany")))
      (should-error (decklet-set-card-tags id '("bad tag")))
      (should (equal (decklet-get-card-tags id) '("botany")))
      (decklet-db--disconnect)
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

(ert-deftest decklet-test-tags-batch-order-and-validation ()
  "Tag and hint lines may interleave; invalid tokens fail before import."
  (let ((expected '((:word "rose" :hint "a flower\n:literal hint"
                           :tags ("botany" "flower")))))
    (dolist (text '("rose\n:flower :botany\n# a flower\n# :literal hint\n:flower\n"
                    "rose\n# a flower\n:botany\n# :literal hint\n:flower\n"))
      (with-temp-buffer (insert text) (should (equal (decklet--batch-collect-cards) expected))))
    (dolist (text '(":botany\nrose" "rose\n:" "rose\n:botany wrong" "rose\n:bad:tag"))
      (with-temp-buffer (insert text) (should-error (decklet--batch-collect-cards))))))

(ert-deftest decklet-test-tags-batch-import-merges-and-rolls-back ()
  "Batch additions merge tags, and a failing write rolls back all cards."
  (decklet-test--with-temp-db
    (let ((id (decklet-test-tags--new "rose" "reading")))
      (with-temp-buffer
        (insert "rose\n:botany\n# a flower\nlily\n:botany\n")
        (cl-letf (((symbol-function 'quit-window) #'ignore))
          (decklet-add-card-batch-confirm)))
      (should (equal (decklet-get-card-tags id) '("botany" "reading")))
      (should (equal (decklet-get-card-tags (decklet-get-card-id-by-word "lily")) '("botany")))
      (with-temp-buffer
        (insert "never-committed\n:botany\n")
        (cl-letf (((symbol-function 'decklet-db--update-tags)
                   (lambda (&rest _) (error "Write failed"))))
          (should-error (decklet-add-card-batch-confirm))))
      (should-not (decklet-get-card-id-by-word "never-committed")))))

(ert-deftest decklet-test-tags-batch-font-lock-and-keys ()
  "Tag lines have their own face and hint/tag keys are consistent."
  (with-temp-buffer
    (decklet-add-card-batch-mode)
    (insert "rose\n:botany :flower\n# a flower\n")
    (font-lock-ensure)
    (goto-char (point-min)) (forward-line)
    (should (eq (get-text-property (point) 'face) 'decklet-color-tags)))
  (should (eq (lookup-key decklet-review-mode-map "H") #'decklet-review-set-hint))
  (should (eq (lookup-key decklet-review-mode-map "t") #'decklet-review-set-tags))
  (should (eq (lookup-key decklet-edit-mode-map "H") #'decklet-edit-set-hint))
  (should (eq (lookup-key decklet-edit-mode-map "t") #'decklet-edit-set-tags)))

(ert-deftest decklet-test-tags-single-add-edits-both-fields ()
  "The single-card prompt lets the user edit hint and tags before leaving."
  (decklet-test--with-temp-db
    (let ((answers '(?H ?t ?n)) (read-count 0))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) (cl-incf read-count) "rose"))
                ((symbol-function 'read-char-choice)
                 (lambda (&rest _) (pop answers)))
                ((symbol-function 'decklet-prompt-set-hint)
                 (lambda (id) (decklet-set-card-hint id "a flower")))
                ((symbol-function 'decklet-read-tags)
                 (lambda (&rest _) '("botany"))))
        (call-interactively #'decklet-add-card))
      (should (= read-count 1))
      (should (equal (decklet-get-card-hint (decklet-get-card-id-by-word "rose")) "a flower"))
      (should (equal (decklet-get-card-tags (decklet-get-card-id-by-word "rose")) '("botany"))))))

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

(ert-deftest decklet-test-tags-void-and-current-rule-reclassification ()
  "Rule order and void records recompute which tagged group spent the slot."
  (decklet-test--with-temp-db
    (let* ((decklet-review-order
            '(((new :tags "botany") (daily-limit 1 shuffle))
              ((new :tags "medicine") (daily-limit 1 shuffle))))
           (rated (decklet-test-tags--new "shared" "botany" "medicine"))
           (plant (decklet-test-tags--new "plant" "botany"))
           (medical (decklet-test-tags--new "medical" "medicine"))
           (log-id (decklet-rate-card rated 4)))
      (should (equal (decklet-db--select-due-card-ids) (list medical)))
      (setq decklet-review-order (reverse decklet-review-order))
      (should (equal (decklet-db--select-due-card-ids) (list plant)))
      (decklet-review-log-append-void log-id)
      (should (= (length (decklet-db--select-due-card-ids)) 2)))))

(ert-deftest decklet-test-tags-invalid-rules ()
  "Malformed selectors, old syntax and duplicate fallbacks are rejected."
  (dolist (order '(((new :tags) shuffle)
                   (((new :tags nil) shuffle))
                   (((new :tags (not "a" "b")) shuffle))
                   (((new :tags (or)) shuffle))
                   (((new :tags (eval "a")) shuffle))
                   ((:new . shuffle))
                   ((new shuffle) ((new review) shuffle))))
    (should-error (decklet-db--review-validate-order order))))

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

(ert-deftest decklet-test-tags-json-roundtrip-and-missing-preserves ()
  "JSON exports tags and supports explicit clearing without losing absent tags."
  (decklet-test--with-temp-db
    (let* ((id (decklet-test-tags--new "rose" "botany"))
           (file (expand-file-name "tags.json" tmp-dir)))
      (decklet-db-export-json file)
      (decklet-set-card-tags id '("wrong"))
      (cl-letf (((symbol-function 'decklet-transfer--import-read-conflict-choice)
                 (lambda (_) (cons :overwrite nil))))
        (decklet-db-import-json file)
        (should (equal (decklet-get-card-tags id) '("botany")))
        (decklet-test--import '(((word . "rose"))))
        (should (equal (decklet-get-card-tags id) '("botany")))
        (decklet-test--import '(((word . "rose") (tags . []))))
        (should-not (decklet-get-card-tags id)))
      (should-error (decklet-test--import '(((word . "bad") (tags . ["has space"])))))
      (should-not (decklet-get-card-id-by-word "bad")))))

(ert-deftest decklet-test-tags-edit-column-filter-and-pending-queue ()
  "The edit table displays tags, filters them, and tag edits clear pending cards."
  (decklet-test--with-temp-db
    (let* ((id (decklet-test-tags--new "rose" "botany"))
           (decklet-edit--filter 'all)
           (decklet-edit--tag-filter "botany")
           (tabulated-list-sort-key nil)
           (decklet-edit-sidecar-columns nil)
           (decklet-due-card-ids (list id)))
      (decklet-test-tags--new "plain")
      (let* ((rows (decklet-edit--entries))
             (index (cdr (assoc "Tags" (decklet-edit--column-indices)))))
        (should (= (length rows) 1))
        (should (equal (substring-no-properties (aref (cadar rows) index)) "botany")))
      (setq decklet-due-card-ids (list id))
      (decklet-set-card-tags id '("medicine"))
      (should-not decklet-due-card-ids)
      (should-not (decklet-edit--entries)))))

(provide 'decklet-tags-test)
;;; decklet-tags-test.el ends here

;;; decklet-review-log-test.el --- This file tests decklet-review-log.el. -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

;;; Record format

(ert-deftest decklet-test-review-log-rating-writes-rated-record ()
  "Each rating appends one JSONL record in the documented shape.
A first review records null memory data and zero elapsed days; the
next review starts from the memory state the first one produced."
  (decklet-test--with-temp-db
    (decklet--add-card "inveigh")
    (let* ((card-id (decklet-test--card-id "inveigh"))
           (first-id (decklet-rate-card card-id 3))
           (second-id (decklet-rate-card card-id 3)))
      (pcase-let ((`(,first ,second) (decklet-test--read-log)))
        ;; Field order is not part of the format; the field set is.
        (should (equal (sort (cl-loop for (key _) on first by #'cddr collect key)
                             #'string<)
                       '(:card_id :elapsed_days :grade :id :kind
                                  :post_difficulty :post_stability :post_state
                                  :pre_difficulty :pre_effective_state
                                  :pre_stability :pre_state :t :word)))
        (should (equal "rated" (plist-get first :kind)))
        (should (= first-id (plist-get first :id)))
        (should (= card-id (plist-get first :card_id)))
        (should (equal "inveigh" (plist-get first :word)))
        (should (= 3 (plist-get first :grade)))
        (should (equal "learning" (plist-get first :pre_state)))
        (should (equal "new" (plist-get first :pre_effective_state)))
        (should-not (plist-get first :pre_stability))
        (should-not (plist-get first :pre_difficulty))
        (should (equal "learning" (plist-get first :post_state)))
        (should (numberp (plist-get first :post_stability)))
        (should (= 0 (plist-get first :elapsed_days)))
        (should (= second-id (plist-get second :id)))
        (should (equal "learning" (plist-get second :pre_effective_state)))
        (should (= (plist-get first :post_stability)
                   (plist-get second :pre_stability)))))))

(ert-deftest decklet-test-review-log-rename-card-appends-rename ()
  "`decklet-set-card-word' logs a rename event with both words."
  (decklet-test--with-temp-db
    (decklet--add-card "colour")
    (let ((id (decklet-test--card-id "colour")))
      (decklet-set-card-word id "color")
      (let ((rec (car (decklet-test--read-log))))
        (should (equal "rename" (plist-get rec :kind)))
        (should (= id (plist-get rec :card_id)))
        (should (equal "colour" (plist-get rec :old)))
        (should (equal "color" (plist-get rec :new)))))))

;;; Daily consumption accounting

(ert-deftest decklet-test-review-log-daily-counts-count-cards-once ()
  "Repeated ratings of one card from the same state consume one slot."
  (decklet-test--with-temp-db
    (dotimes (_ 3)
      (decklet-review-log--append-line
       (list :kind "rated"
             :id (decklet-review-log--mint-record-id)
             :card_id 1
             :t (decklet--now)
             :word "repeat"
             :grade 3
             :pre_state "learning"
             :pre_effective_state "learning"
             :pre_stability 1.0
             :elapsed_days 0.0)))
    (should (equal '((:learning . 1)) (decklet-review-log-daily-state-counts)))))

(ert-deftest decklet-test-review-log-daily-counts-classify-legacy-records ()
  "Records without `pre_effective_state' are still classified.
A null `pre_stability' marks a card's first ever review, which the
stored `pre_state' cannot distinguish from an ongoing learning step."
  (decklet-test--with-temp-db
    (pcase-dolist (`(,card-id ,stability) '((1 nil) (2 2.5)))
      (decklet-review-log--append-line
       (list :kind "rated"
             :id (decklet-review-log--mint-record-id)
             :card_id card-id
             :t (decklet--now)
             :word (format "legacy-%d" card-id)
             :grade 3
             :pre_state "learning"
             :pre_stability stability
             :elapsed_days 0.0)))
    (let ((counts (decklet-review-log-daily-state-counts)))
      (should (= 1 (cdr (assq :new counts))))
      (should (= 1 (cdr (assq :learning counts)))))))

(provide 'decklet-review-log-test)
;;; decklet-review-log-test.el ends here

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

(provide 'decklet-review-log-test)
;;; decklet-review-log-test.el ends here

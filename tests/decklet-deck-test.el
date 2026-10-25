;;; decklet-deck-test.el --- This file tests decklet-deck.el. -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

;;; Effective state derivation

(ert-deftest decklet-test-deck-card-effective-state ()
  "A card is `:new' until its first review, then mirrors its stored state.
Holds for both the raw state+last-review form and the card-meta form."
  (should (eq (decklet-card-effective-state :learning nil) :new))
  (should (eq (decklet-card-effective-state :learning "") :new))
  (should (eq (decklet-card-effective-state :learning "2025-01-01T00:00:00Z") :learning))
  (should (eq (decklet-card-effective-state :relearning "2025-01-01T00:00:00Z") :relearning))
  (should (eq (decklet-card-effective-state :review "2025-01-01T00:00:00Z") :review))
  (should (eq (decklet-card-effective-state :unknown "2025-01-01T00:00:00Z") :review))
  (should (eq (decklet-card-meta-effective-state
               (make-decklet-card-meta :state :learning :last-review nil))
              :new))
  (should (eq (decklet-card-meta-effective-state
               (make-decklet-card-meta :state :learning :last-review "2025-01-01T00:00:00Z"))
              :learning)))

;;; Field setters

(ert-deftest decklet-test-deck-field-setters-fire-hook-only-on-change ()
  "Hint/back setters notify only for normalized value changes."
  (decklet-test--with-temp-db
    (let ((id (decklet-test--add-card-meta "glow" :state :learning
                                           :timestamp "20250101T000000Z"))
          (events nil))
      (let ((decklet-cards-field-updated-functions
             (list (lambda (evs) (setq events (append events evs))))))
        (should (decklet-set-card-hint id "old hint"))
        (should-not (decklet-set-card-hint id " old hint "))
        (should (decklet-set-card-back id "old back"))
        (should-not (decklet-set-card-back id "old back")))
      (should (equal (mapcar (lambda (e) (plist-get e :field)) events) '(hint back))))))

;;; Card identity

(ert-deftest decklet-test-deck-add-card-refresh-preserves-id ()
  "Re-adding an existing new card refreshes it in place with the same id."
  (decklet-test--with-temp-db
    (let ((decklet-add-and-refresh t))
      (decklet--add-card "alpha")
      (let ((first (decklet-test--card-id "alpha")))
        (decklet--add-card "alpha")
        (should (= first (decklet-test--card-id "alpha")))))))

(ert-deftest decklet-test-deck-delete-and-readd-mints-new-id ()
  "Deleting then re-adding a word gives the new card a fresh id."
  (decklet-test--with-temp-db
    (decklet--add-card "beta")
    (let ((first (decklet-test--card-id "beta")))
      (decklet-delete-card first)
      (decklet--add-card "beta")
      (should-not (= first (decklet-test--card-id "beta"))))))

;;; Rating commit

(ert-deftest decklet-test-deck-rating-survives-failure-after-db-write ()
  "A failure after the DB write leaves the rating standing in the log.
Only a failed DB write retires the freshly written log record."
  (decklet-test--with-temp-db
    (decklet--add-card "w")
    (let ((id (decklet-test--card-id "w")))
      (cl-letf (((symbol-function 'decklet--refresh-counter)
                 (lambda () (error "Counter refresh failed"))))
        (should-error (decklet-rate-card id 3)))
      (should (decklet-card-meta-last-review (decklet-get-card-meta id)))
      (should (equal (list decklet-review-log-kind-rated)
                     (mapcar (lambda (r) (plist-get r :kind))
                             (decklet-test--read-log)))))))

(ert-deftest decklet-test-deck-rating-voids-log-when-db-write-fails ()
  "A failed DB write retires the log record written for the rating."
  (decklet-test--with-temp-db
    (decklet--add-card "w")
    (let ((id (decklet-test--card-id "w")))
      (cl-letf (((symbol-function 'decklet-db--upsert-card)
                 (lambda (&rest _) (error "Disk full"))))
        (should-error (decklet-rate-card id 3)))
      (should-not (decklet-card-meta-last-review (decklet-get-card-meta id)))
      (should (equal (list decklet-review-log-kind-rated
                           decklet-review-log-kind-void)
                     (mapcar (lambda (r) (plist-get r :kind))
                             (decklet-test--read-log)))))))

;;; decklet-deck-test.el ends here

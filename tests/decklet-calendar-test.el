;;; decklet-calendar-test.el --- Tests for decklet calendar integration -*- lexical-binding: t; -*-

(require 'decklet-test-helpers)

;; ---------------------------------------------------------------------------
;; Calendar-facing DB aggregation
;; ---------------------------------------------------------------------------
;; Keep this at DB layer: verify overdue and in-range due counts are split
;; correctly for `decklet-db--due-counts-by-date'.

(ert-deftest decklet-test-db-due-counts-by-date-splits-overdue-and-range ()
  (decklet-test--with-temp-db
    (let* ((now (current-time))
           (day-start (decklet--day-start-time now))
           (cutoff (decklet--next-day-start-time now))
           (overdue-time (time-subtract day-start (seconds-to-time 60)))
           (in-range-time (time-add day-start (seconds-to-time 3600)))
           (ts-added (decklet-test--ts (time-subtract now (seconds-to-time 7200))))
           (ts-last (decklet-test--ts (time-subtract now (seconds-to-time 1800)))))
      ;; Overdue reviewed card.
      (decklet-db--upsert-card
       "overdue-card"
       (make-decklet-card-meta
        :added-date ts-added
        :last-review ts-last
        :due (decklet-test--ts overdue-time)
        :state :review))
      ;; Due in current [day-start, cutoff) window.
      (decklet-db--upsert-card
       "range-card"
       (make-decklet-card-meta
        :added-date ts-added
        :last-review ts-last
        :due (decklet-test--ts in-range-time)
        :state :review))
      (let* ((result (decklet-db--due-counts-by-date day-start cutoff))
             (rows (plist-get result :rows))
             (overdue (plist-get result :overdue))
             (in-range-count (apply #'+ (mapcar #'cadr rows))))
        (should (= overdue 1))
        (should (= in-range-count 1))))))

(provide 'decklet-calendar-test)
;;; decklet-calendar-test.el ends here

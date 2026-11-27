;;; decklet-scheduler-test.el --- Tests for decklet-scheduler.el -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)
(require 'fsrs)

;;; Review-day boundaries

(defmacro decklet-test-scheduler--in-los-angeles (&rest body)
  "Run BODY with TZ set to America/Los_Angeles, restoring it afterwards."
  (declare (indent 0) (debug t))
  `(let ((old-tz (getenv "TZ")))
     (unwind-protect
         (progn (setenv "TZ" "America/Los_Angeles") ,@body)
       (setenv "TZ" old-tz))))

(defun decklet-test-scheduler--local (time)
  "Format TIME as a Los Angeles wall-clock string with its offset."
  (format-time-string "%F %T %z" time "America/Los_Angeles"))

(ert-deftest decklet-test-scheduler-rollover-follows-calendar-across-dst ()
  "Review-day boundaries keep their wall-clock hour across DST changes."
  (decklet-test-scheduler--in-los-angeles
    (let ((decklet-day-rollover-hour 4))
      (should (equal (decklet-test-scheduler--local
                      (decklet--next-day-start-time
                       (date-to-time "2026-03-07T12:00:00-08:00")))
                     "2026-03-08 04:00:00 -0700"))
      (should (equal (decklet-test-scheduler--local
                      (decklet-day-start-time
                       (date-to-time "2026-03-08T03:30:00-07:00")))
                     "2026-03-07 04:00:00 -0800"))
      (should (equal (decklet-test-scheduler--local
                      (decklet--next-day-start-time
                       (date-to-time "2026-10-31T12:00:00-07:00")))
                     "2026-11-01 04:00:00 -0800"))
      (should (equal (decklet-test-scheduler--local
                      (decklet-day-start-time
                       (date-to-time "2026-11-01T03:30:00-08:00")))
                     "2026-10-31 04:00:00 -0700")))))

(ert-deftest decklet-test-scheduler-rollover-normalizes-missing-dst-hour ()
  "A rollover in the spring DST gap advances to the next valid hour."
  (decklet-test-scheduler--in-los-angeles
    (let ((decklet-day-rollover-hour 2))
      (should (equal (decklet-test-scheduler--local
                      (decklet--next-day-start-time
                       (date-to-time "2026-03-07T12:00:00-08:00")))
                     "2026-03-08 03:00:00 -0700"))
      (should (equal (decklet-test-scheduler--local
                      (decklet--next-day-start-time
                       (date-to-time "2026-03-08T12:00:00-07:00")))
                     "2026-03-09 02:00:00 -0700")))))

;;; FSRS parameters

(ert-deftest decklet-test-scheduler-new-parameters-apply-to-next-review ()
  "Setting `decklet-fsrs-parameters' through Customize takes effect at once.
The scheduler is cached, so a stale cache would keep the old weights."
  (decklet-test--with-temp-db
    (let ((override (copy-sequence fsrs-default-parameters)))
      (aset override 0 0.5)
      (should (equal (fsrs-scheduler-parameters (decklet--get-fsrs-scheduler))
                     fsrs-default-parameters))
      (customize-set-variable 'decklet-fsrs-parameters override)
      (should (equal (fsrs-scheduler-parameters (decklet--get-fsrs-scheduler))
                     override)))))

(ert-deftest decklet-test-scheduler-early-next-day-review-uses-long-term-stability ()
  "Reviewing a 1-day card earlier on the next review day still counts as 1 day.
The stored `last-review' stays at the real review timestamp."
  (decklet-test--with-temp-db
    (decklet-test-scheduler--in-los-angeles
      (let* ((decklet-day-rollover-hour 4)
             (t-prev (date-to-time "2026-01-01T21:00:00-08:00"))
             (t-early (date-to-time "2026-01-02T20:00:00-08:00"))
             (t-exact (date-to-time "2026-01-02T21:00:00-08:00"))
             (meta (decklet-test--make-card-meta
                    :added-date (decklet-test--ts t-prev)
                    :last-review (decklet-test--ts t-prev)
                    :due (decklet-test--ts t-exact)
                    :state :review :stability 1.4 :difficulty 7.0))
             (early-good (car (decklet--simulate-fsrs-review meta 3 t-early)))
             (exact-good (car (decklet--simulate-fsrs-review meta 3 t-exact)))
             (early-hard (car (decklet--simulate-fsrs-review meta 2 t-early))))
        (should (< (abs (- (fsrs-card-stability early-good)
                           (fsrs-card-stability exact-good)))
                   0.001))
        (should (> (fsrs-card-stability early-hard) 1.4))
        (should (equal (fsrs-card-last-review early-good)
                       (decklet-test--ts t-early)))))))

(provide 'decklet-scheduler-test)
;;; decklet-scheduler-test.el ends here

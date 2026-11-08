;;; decklet-scheduler-test.el --- This file tests decklet-scheduler.el. -*- lexical-binding: t; -*-

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

(provide 'decklet-scheduler-test)
;;; decklet-scheduler-test.el ends here

;;; decklet-scheduler-test.el --- This file tests decklet-scheduler.el. -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)
(require 'fsrs)

;;; Review-day boundaries

(ert-deftest decklet-test-scheduler-rollover-follows-calendar-across-dst ()
  "Review-day boundaries keep their wall-clock hour across DST changes."
  (let ((old-tz (getenv "TZ"))
        (decklet-day-rollover-hour 4))
    (unwind-protect
        (progn
          (setenv "TZ" "America/Los_Angeles")
          (cl-labels ((format-local (time)
                        (format-time-string "%F %T %z" time
                                            "America/Los_Angeles")))
            (should
             (equal
              (format-local
               (decklet--next-day-start-time
                (date-to-time "2026-03-07T12:00:00-08:00")))
              "2026-03-08 04:00:00 -0700"))
            (should
             (equal
              (format-local
               (decklet-day-start-time
                (date-to-time "2026-03-08T03:30:00-07:00")))
              "2026-03-07 04:00:00 -0800"))
            (should
             (equal
              (format-local
               (decklet--next-day-start-time
                (date-to-time "2026-10-31T12:00:00-07:00")))
              "2026-11-01 04:00:00 -0800"))
            (should
             (equal
              (format-local
               (decklet-day-start-time
                (date-to-time "2026-11-01T03:30:00-08:00")))
              "2026-10-31 04:00:00 -0700"))))
      (setenv "TZ" old-tz))))

(ert-deftest decklet-test-scheduler-rollover-normalizes-missing-dst-hour ()
  "A rollover in the spring DST gap advances to the next valid hour."
  (let ((old-tz (getenv "TZ"))
        (decklet-day-rollover-hour 2))
    (unwind-protect
        (progn
          (setenv "TZ" "America/Los_Angeles")
          (cl-labels ((format-local (time)
                        (format-time-string "%F %T %z" time
                                            "America/Los_Angeles")))
            (should
             (equal
              (format-local
               (decklet--next-day-start-time
                (date-to-time "2026-03-07T12:00:00-08:00")))
              "2026-03-08 03:00:00 -0700"))
            (should
             (equal
              (format-local
               (decklet--next-day-start-time
                (date-to-time "2026-03-08T12:00:00-07:00")))
              "2026-03-09 02:00:00 -0700"))))
      (setenv "TZ" old-tz))))

;;; FSRS parameter override

(ert-deftest decklet-test-scheduler-parameter-override-round-trips ()
  "The scheduler falls back to FSRS defaults around overrides.
It passes a non-nil override through and reverts when the override is cleared."
  (decklet-test--with-temp-db
    (setq decklet--fsrs-scheduler nil)
    (should (equal (fsrs-scheduler-parameters (decklet--get-fsrs-scheduler))
                   fsrs-default-parameters))
    (let ((override (copy-sequence fsrs-default-parameters)))
      ;; Tweak two entries that stay within their bounds.
      (aset override 0 0.5)
      (aset override 20 0.25)
      (let ((decklet-fsrs-parameters override))
        (setq decklet--fsrs-scheduler nil)
        (should (equal (fsrs-scheduler-parameters (decklet--get-fsrs-scheduler))
                       override))))
    (setq decklet--fsrs-scheduler nil)
    (should (equal (fsrs-scheduler-parameters (decklet--get-fsrs-scheduler))
                   fsrs-default-parameters))))

(ert-deftest decklet-test-scheduler-set-handler-invalidates-cache ()
  "The custom setter invalidates the cached scheduler.
New weights take effect on the next review without a manual cache clear."
  (decklet-test--with-temp-db
    (let ((handler (get 'decklet-fsrs-parameters 'custom-set)))
      (should handler)
      (setq decklet--fsrs-scheduler :stale-sentinel)
      (funcall handler 'decklet-fsrs-parameters
               (copy-sequence fsrs-default-parameters))
      (should-not decklet--fsrs-scheduler))))

;;; State normalization at the FSRS boundary

(ert-deftest decklet-test-scheduler-schedules-effective-new-state ()
  "A `:new' card is scheduled as FSRS learning and records a last-review."
  (decklet-test--with-temp-db
    (let* ((now (decklet--now))
           (meta (make-decklet-card-meta :card-id 1 :added-date now :last-review nil
                                         :due now :state :new :step 0))
           (updated (decklet--update-meta-with-grade meta 3)))
      (should (memq (decklet-card-meta-state updated)
                    '(:learning :review :relearning)))
      (should (decklet-card-meta-last-review updated)))))

(provide 'decklet-scheduler-test)
;;; decklet-scheduler-test.el ends here

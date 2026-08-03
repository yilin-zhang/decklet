;;; decklet-scheduler-test.el --- Tests for decklet-scheduler -*- lexical-binding: t; -*-

(require 'decklet-test-helpers)
(require 'fsrs)

;;; FSRS parameter override

(ert-deftest decklet-test-scheduler-parameter-override-round-trips ()
  "The scheduler uses FSRS defaults when no override is set, passes a non-nil
override vector through, and reverts to defaults once the override is cleared."
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
  "The defcustom :set handler clears the cached scheduler so new weights take
effect on the next review without a manual cache clear."
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

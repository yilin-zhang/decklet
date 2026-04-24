;;; decklet-scheduler-test.el --- Tests for decklet-scheduler -*- lexical-binding: t; -*-

(require 'decklet-test-helpers)
(require 'fsrs)

;; ---------------------------------------------------------------------------
;; decklet-fsrs-parameters override path
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-fsrs-scheduler-uses-library-defaults-when-override-nil ()
  "With `decklet-fsrs-parameters' nil, the scheduler uses FSRS defaults."
  (decklet-test--with-temp-db
   (let ((decklet-fsrs-parameters nil))
     (setq decklet--fsrs-scheduler nil)
     (let ((scheduler (decklet--get-fsrs-scheduler)))
       (should (equal (fsrs-scheduler-parameters scheduler)
                      fsrs-default-parameters))))))

(ert-deftest decklet-test-fsrs-scheduler-override-passes-through ()
  "A non-nil `decklet-fsrs-parameters' vector reaches the FSRS scheduler."
  (decklet-test--with-temp-db
   ;; Build a valid-but-non-default vector by tweaking two entries that
   ;; lie inside their bounds.  Index 0 default is 0.212 (bounds
   ;; [0.001, 100]); index 20 default is 0.1542 (bounds [0.1, 0.8]).
   (let ((override (copy-sequence fsrs-default-parameters)))
     (aset override 0 0.5)
     (aset override 20 0.25)
     (let ((decklet-fsrs-parameters override))
       (setq decklet--fsrs-scheduler nil)
       (let ((scheduler (decklet--get-fsrs-scheduler)))
         (should (equal (fsrs-scheduler-parameters scheduler) override))
         ;; Independence: tweaking the source vector after the fact
         ;; must not mutate the scheduler's internal copy.
         (should-not (equal (aref (fsrs-scheduler-parameters scheduler) 0)
                            0.212)))))))

(ert-deftest decklet-test-fsrs-scheduler-override-restored-when-set-back-to-nil ()
  "Clearing the override to nil restores the library defaults on next build."
  (decklet-test--with-temp-db
   (let ((override (copy-sequence fsrs-default-parameters)))
     (aset override 0 0.5)
     ;; First build: with override.
     (let ((decklet-fsrs-parameters override))
       (setq decklet--fsrs-scheduler nil)
       (should (equal (fsrs-scheduler-parameters (decklet--get-fsrs-scheduler))
                      override)))
     ;; Second build: override cleared.
     (let ((decklet-fsrs-parameters nil))
       (setq decklet--fsrs-scheduler nil)
       (should (equal (fsrs-scheduler-parameters (decklet--get-fsrs-scheduler))
                      fsrs-default-parameters))))))

(ert-deftest decklet-test-fsrs-parameters-set-handler-invalidates-cache ()
  "The defcustom's :set handler must clear the cached scheduler.
This guards the contract that `customize-set-variable' (and the
tuner extension's apply path) installs the new weights on the
next review without a manual cache clear."
  (decklet-test--with-temp-db
   (let ((handler (get 'decklet-fsrs-parameters 'custom-set)))
     (should handler)
     (setq decklet--fsrs-scheduler :stale-sentinel)
     (funcall handler 'decklet-fsrs-parameters
              (copy-sequence fsrs-default-parameters))
     (should-not decklet--fsrs-scheduler))))

;; ---------------------------------------------------------------------------
;; State normalization at the FSRS boundary
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-fsrs-scheduler-accepts-effective-new-state ()
  "Legacy `:new' metadata is scheduled as FSRS learning state."
  (decklet-test--with-temp-db
   (let* ((now (decklet--now))
          (meta (make-decklet-card-meta
                 :card-id 1
                 :added-date now
                 :last-review nil
                 :due now
                 :state :new
                 :step 0))
          (updated (decklet--update-meta-with-grade meta 3)))
     (should (memq (decklet-card-meta-state updated)
                   '(:learning :review :relearning)))
     (should (decklet-card-meta-last-review updated)))))

(provide 'decklet-scheduler-test)
;;; decklet-scheduler-test.el ends here

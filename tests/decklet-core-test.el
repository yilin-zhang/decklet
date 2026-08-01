;;; decklet-core-test.el --- Tests for decklet-core.el -*- lexical-binding: t; -*-

(require 'decklet-test-helpers)

(ert-deftest decklet-test-core-timestamp-utc-format ()
  "Filename timestamps use the compact UTC representation."
  (should (string-match-p "\\`[0-9]\\{8\\}T[0-9]\\{6\\}Z\\'"
                          (decklet--timestamp-utc))))

(ert-deftest decklet-test-core-event-hook-isolates-subscriber-errors ()
  "Every event subscriber runs even when an earlier subscriber fails."
  (let ((seen nil)
        (decklet-cards-added-functions
         '(decklet-test--broken-subscriber decklet-test--recording-subscriber)))
    (cl-letf (((symbol-function 'decklet-test--broken-subscriber)
               (lambda (_events) (error "broken extension")))
              ((symbol-function 'decklet-test--recording-subscriber)
               (lambda (events) (setq seen events)))
              ((symbol-function 'display-warning) #'ignore))
      (decklet-run-hook-isolated 'decklet-cards-added-functions
                                 '((:card-id 42))))
    (should (equal seen '((:card-id 42))))))

(provide 'decklet-core-test)
;;; decklet-core-test.el ends here

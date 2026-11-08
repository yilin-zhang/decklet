;;; decklet-core-test.el --- This file tests decklet-core.el. -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

(ert-deftest decklet-test-core-event-hook-isolates-subscriber-errors ()
  "Every event subscriber runs even when an earlier subscriber fails."
  (let ((seen nil)
        (decklet-cards-added-functions
         '(decklet-test--broken-subscriber decklet-test--recording-subscriber)))
    (cl-letf (((symbol-function 'decklet-test--broken-subscriber)
               (lambda (_events) (error "Broken extension")))
              ((symbol-function 'decklet-test--recording-subscriber)
               (lambda (events) (setq seen events)))
              ((symbol-function 'display-warning) #'ignore))
      (decklet-run-hook-isolated 'decklet-cards-added-functions
                                 '((:card-id 42))))
    (should (equal seen '((:card-id 42))))))

(ert-deftest decklet-test-core-card-sidecar-file-keys-by-id ()
  "Per-card files are named by card id, so case variants get distinct files."
  (should (equal "/media/42.png" (decklet-card-sidecar-file "/media/" 42 "png")))
  (should-error (decklet-card-sidecar-file "/media" "Polish" "png")))

(provide 'decklet-core-test)
;;; decklet-core-test.el ends here

;;; decklet-batch-test.el --- This file tests decklet-batch.el. -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

;;; Batch transaction

(ert-deftest decklet-test-batch-quit-rolls-back-transaction ()
  "Quitting mid-batch rolls back and leaves no transaction open."
  (decklet-test--with-temp-db
    (with-temp-buffer
      (insert "first\nsecond\n# hint\n")
      (cl-letf (((symbol-function 'decklet-set-card-hint)
                 (lambda (&rest _) (signal 'quit nil))))
        (should (eq 'quit (condition-case nil
                              (decklet-add-card-batch-confirm)
                            (quit 'quit))))))
    (should-not (decklet-list-words))
    ;; A dangling transaction would make this BEGIN fail.
    (with-sqlite-transaction (decklet-db--ensure)
      (decklet--add-card "after"))
    (should (equal '("after") (decklet-list-words)))))

;;; Batch collection parsing

(ert-deftest decklet-test-batch-collect-cards-with-hints ()
  "Batch parsing attaches hint lines to the preceding word.
It recognizes the `#' prefix and joins multi-line hints."
  (with-temp-buffer
    (insert "\n  lucid  \n# adj.\n\n\t\n# lucid rain\n  dirt\n# ...\n")
    (should (equal (decklet--batch-collect-cards)
                   '((:word "lucid" :hint "adj.\nlucid rain")
                     (:word "dirt" :hint "..."))))))

(ert-deftest decklet-test-batch-collect-cards-rejects-orphan-hint ()
  "A hint line with no preceding word is an error."
  (with-temp-buffer
    (insert "# lonely hint\nlucid\n")
    (should-error (decklet--batch-collect-cards))))

(provide 'decklet-batch-test)
;;; decklet-batch-test.el ends here

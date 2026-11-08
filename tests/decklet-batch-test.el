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

;;; Batch parsing

(ert-deftest decklet-test-batch-collect-cards-attaches-hints-and-tags ()
  "Hint and tag lines attach to the preceding word, in any order.
Blank lines and surrounding whitespace are ignored, multi-line hints
are joined, and repeated tags collapse."
  (dolist (text '("\n  rose  \n:flower :botany\n# a flower\n\n\t\n# :literal hint\n:flower\n  dirt\n# ...\n"
                  "rose\n# a flower\n:botany\n# :literal hint\n:flower\ndirt\n# ...\n"))
    (with-temp-buffer
      (insert text)
      (should (equal (decklet--batch-collect-cards)
                     '((:word "rose" :hint "a flower\n:literal hint"
                              :tags ("botany" "flower"))
                       (:word "dirt" :hint "...")))))))

(ert-deftest decklet-test-batch-collect-cards-rejects-malformed-lines ()
  "Orphan hint or tag lines and invalid tag tokens are errors."
  (dolist (text '("# lonely hint\nlucid\n" ":botany\nrose" "rose\n:"
                  "rose\n:botany wrong" "rose\n:bad:tag"))
    (with-temp-buffer
      (insert text)
      (should-error (decklet--batch-collect-cards)))))

(provide 'decklet-batch-test)
;;; decklet-batch-test.el ends here

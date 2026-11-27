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

;;; Batch format

(ert-deftest decklet-test-batch-format ()
  "Hint and tag lines attach to the preceding word; malformed lines are errors.
Hint and tag lines may come in any order, blank lines and surrounding
whitespace are ignored, multi-line hints are joined, and repeated tags
collapse."
  (dolist (text '("\n  rose  \n:flower :botany\n# a flower\n\n\t\n# :literal hint\n:flower\n  dirt\n# ...\n"
                  "rose\n# a flower\n:botany\n# :literal hint\n:flower\ndirt\n# ...\n"))
    (with-temp-buffer
      (insert text)
      (should (equal (decklet--batch-collect-cards)
                     '((:word "rose" :hint "a flower\n:literal hint"
                              :tags ("botany" "flower"))
                       (:word "dirt" :hint "..."))))))
  (dolist (text '(;; A hint or tag line with no word before it.
                  "# lonely hint\nlucid\n" ":botany\nrose"
                  ;; Every tag token is a colon followed by a name.
                  "rose\n:" "rose\n:botany wrong"
                  ;; A tag name cannot contain a colon.
                  "rose\n:bad:tag"))
    (with-temp-buffer
      (insert text)
      (should-error (decklet--batch-collect-cards) :type 'user-error))))

(ert-deftest decklet-test-batch-readd-merges-tags ()
  "Re-adding a word in a batch merges its tags with the existing ones."
  (decklet-test--with-temp-db
    (let ((id (plist-get (decklet--add-card "rose") :card-id)))
      (decklet-set-card-tags id '("reading"))
      (with-temp-buffer
        (insert "rose\n:botany\n# a flower\nlily\n:botany\n")
        (cl-letf (((symbol-function 'quit-window) #'ignore))
          (decklet-add-card-batch-confirm)))
      (should-not decklet-db--conn)
      (should (equal (decklet-get-card-tags id) '("botany" "reading")))
      (should (equal (decklet-get-card-tags (decklet-get-card-id-by-word "lily"))
                     '("botany"))))))

(provide 'decklet-batch-test)
;;; decklet-batch-test.el ends here

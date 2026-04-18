;;; decklet-import-test.el --- Tests for decklet import modules -*- lexical-binding: t; -*-

(require 'decklet-test-helpers)

;; ---------------------------------------------------------------------------
;; Batch card collection
;; ---------------------------------------------------------------------------
;; These tests protect batch-mode hint parsing: multi-line hints accumulate
;; under the preceding word, and orphan hints (no preceding word) must fail.

(ert-deftest decklet-test-batch-collect-cards-supports-hint-lines ()
  (with-temp-buffer
    (insert "\n  lucid  \n# adj.\n\n\t\n# lucid rain\n  dirt\n# ...\n")
    (should
     (equal (decklet--batch-collect-cards)
            '((:word "lucid" :hint "adj.\nlucid rain")
              (:word "dirt" :hint "..."))))))

(ert-deftest decklet-test-batch-collect-cards-rejects-orphan-hint ()
  (with-temp-buffer
    (insert "# lonely hint\nlucid\n")
    (should-error (decklet--batch-collect-cards))))

;; ---------------------------------------------------------------------------
;; Kindle import
;; ---------------------------------------------------------------------------
;; Covers row-to-batch-line conversion (with and without usage examples),
;; parsing of two delimiter formats, and case-sensitive word highlighting.

(ert-deftest decklet-test-import-kindle-rows-to-batch-lines-with-usage ()
  (let ((decklet-import-kindle-usage t))
    (should
     (equal (decklet-import-kindle--rows->batch-lines
             '(("lucid" "lucid" "A lucid dream")
               ("lucid" "lucid" "Lucid writing")
               ("dirt" "dirt" "Dirt road")))
            '("lucid"
              "# A *lucid* dream"
              "# *Lucid* writing"
              "dirt"
              "# *Dirt* road")))))

(ert-deftest decklet-test-import-kindle-rows-to-batch-lines-without-usage ()
  (let ((decklet-import-kindle-usage nil))
    (should
     (equal (decklet-import-kindle--rows->batch-lines
             '(("lucid" "lucid" "A lucid dream")
               ("dirt" "dirt" "soil")))
            '("lucid" "dirt")))))

(ert-deftest decklet-test-import-kindle-read-rows-parses-delimited-output ()
  (cl-letf (((symbol-function 'decklet-import--sqlite-call)
             (lambda (&rest _)
               (let ((sep (string 31)))
                 (concat "lunge" sep "lunge" sep "example one\n"
                         "parry" sep "parry" sep "example two\n")))))
    (should (equal (decklet-import-kindle--read-rows "dummy.db")
                   '(("lunge" "lunge" "example one")
                     ("parry" "parry" "example two"))))))

(ert-deftest decklet-test-import-kindle-read-rows-parses-caret-delimited-output ()
  (cl-letf (((symbol-function 'decklet-import--sqlite-call)
             (lambda (&rest _)
               (concat "lunge^_lunge^_example one\n"
                       "parry^_parry^_example two\n"))))
    (should (equal (decklet-import-kindle--read-rows "dummy.db")
                   '(("lunge" "lunge" "example one")
                     ("parry" "parry" "example two"))))))

(ert-deftest decklet-test-import-kindle-highlight-word-lowercase-is-case-insensitive ()
  (should
   (equal (decklet-import-kindle--highlight-usage-word
           "Apple apple APPLE"
           "apple")
          "*Apple* *apple* *APPLE*")))

(ert-deftest decklet-test-import-kindle-highlight-word-uppercase-is-exact-match ()
  (should
   (equal (decklet-import-kindle--highlight-usage-word
           "Iphone iPhone IPHONE"
           "iPhone")
          "Iphone *iPhone* IPHONE")))

(provide 'decklet-import-test)
;;; decklet-import-test.el ends here

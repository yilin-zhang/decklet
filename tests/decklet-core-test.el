;;; decklet-core-test.el --- Tests for decklet-core.el -*- lexical-binding: t; -*-

(require 'decklet-test-helpers)

(ert-deftest decklet-test-core-timestamp-utc-format ()
  "Filename timestamps use the compact UTC representation."
  (should (string-match-p "\\`[0-9]\\{8\\}T[0-9]\\{6\\}Z\\'"
                          (decklet--timestamp-utc))))

(provide 'decklet-core-test)
;;; decklet-core-test.el ends here

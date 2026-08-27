;;; decklet-core-test.el --- This file tests decklet-core.el. -*- lexical-binding: t; -*-

;;; Code:

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
               (lambda (_events) (error "Broken extension")))
              ((symbol-function 'decklet-test--recording-subscriber)
               (lambda (events) (setq seen events)))
              ((symbol-function 'display-warning) #'ignore))
      (decklet-run-hook-isolated 'decklet-cards-added-functions
                                 '((:card-id 42))))
    (should (equal seen '((:card-id 42))))))

(defconst decklet-test--color-carriers
  '((decklet-color-word         . ansi-color-red)
    (decklet-color-state-new    . ansi-color-magenta)
    (decklet-color-state-learning . ansi-color-yellow)
    (decklet-color-state-review . ansi-color-green)
    (decklet-color-card-back    . ansi-color-bright-blue))
  "Shared color carriers and the palette face each one draws from.
`decklet-color-hint' is excluded: it inherits from `shadow', which
specifies no background and so needs no `:background reset'.")

(ert-deftest decklet-test-core-color-carriers-track-the-theme ()
  "Carriers inherit their color instead of freezing it at load time.
A spec that embeds a `face-attribute' lookup is evaluated once when
the file loads, so it keeps whatever palette was active then.  Only
`:inherit', which is resolved at face-realization time, follows a
theme change."
  (pcase-dolist (`(,carrier . ,palette) decklet-test--color-carriers)
    (let ((spec (get carrier 'face-defface-spec)))
      (should (equal (plist-get (cdar spec) :inherit) palette))
      (should-not (plist-get (cdar spec) :foreground)))))

(ert-deftest decklet-test-core-color-carriers-drop-the-palette-background ()
  "Carriers suppress the background the `ansi-color' faces carry.
Those faces set `:background' to the same color as `:foreground',
which would render as a solid block, so each carrier pins the
background back to the `default' face with the `reset' pseudo-value."
  (pcase-dolist (`(,carrier . ,_palette) decklet-test--color-carriers)
    (should (eq (plist-get (cdar (get carrier 'face-defface-spec)) :background)
                'reset))
    ;; Resolved through the inherit chain, the background must not be
    ;; the palette color itself.
    (should-not (stringp (face-attribute carrier :background nil t)))))

(ert-deftest decklet-test-core-no-defface-evaluates-face-attribute ()
  "No `defface' in the package builds its spec from `face-attribute'.
This is the invariant the carriers exist to protect: colors come
from `:inherit', never from a value baked in at load time."
  (let ((offenders nil))
    (dolist (file (directory-files (file-name-directory (locate-library "decklet-core"))
                                   t "\\`decklet-.*\\.el\\'"))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward "^(defface " nil t)
          (goto-char (match-beginning 0))
          (let ((form (read (current-buffer))))
            (when (string-match-p "face-attribute" (format "%S" form))
              (push (cons (file-name-nondirectory file) (cadr form))
                    offenders))))))
    (should-not offenders)))

(ert-deftest decklet-test-core-interleave-evenly-spaces-items ()
  "Items land at half-stride offsets through the base list."
  (should (equal (decklet--interleave-evenly '(a b c) '(x))
                 '(a b x c)))
  (should (equal (decklet--interleave-evenly '(a b c d e f g h i) '(x y z))
                 '(a b x c d e y f g h z i))))

(ert-deftest decklet-test-core-interleave-evenly-handles-degenerate-input ()
  "Empty inputs and item-heavy lists still return every element once."
  (should (equal (decklet--interleave-evenly '(a b c) nil) '(a b c)))
  (should (equal (decklet--interleave-evenly nil '(x y)) '(x y)))
  (should (equal (decklet--interleave-evenly nil nil) nil))
  ;; More items than base entries: nothing is dropped or duplicated.
  (let ((merged (decklet--interleave-evenly '(a) '(x y z))))
    (should (= 4 (length merged)))
    (should (equal (sort (copy-sequence merged) #'string<) '(a x y z)))))

(provide 'decklet-core-test)
;;; decklet-core-test.el ends here

;;; decklet-core.el --- Core shared settings for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yilin Zhang

;;; Commentary:

;; Shared root group and directory settings used by all modules.

;;; Code:

(require 'ansi-color)
(require 'subr-x)

(defgroup decklet nil
  "A spaced repetition system using the FSRS algorithm."
  :group 'applications)

(defcustom decklet-directory
  (expand-file-name "decklet/" user-emacs-directory)
  "Base directory for all Decklet data files."
  :type 'directory
  :group 'decklet)

;; Shared colors.  Each face only sets a foreground, inherited from
;; the theme's `ansi-color' palette, so it follows theme changes.  The
;; `ansi-color' faces also paint the background in the same color, and
;; `:background reset' undoes that.

(defface decklet-color-word
  '((t :inherit ansi-color-red :background reset))
  "Shared color for words."
  :group 'decklet)

(defface decklet-color-state-new
  '((t :inherit ansi-color-magenta :background reset))
  "Shared color for new-card state indicators."
  :group 'decklet)

(defface decklet-color-state-learning
  '((t :inherit ansi-color-yellow :background reset))
  "Shared color for learning-card state indicators."
  :group 'decklet)

(defface decklet-color-state-review
  '((t :inherit ansi-color-green :background reset))
  "Shared color for review-card state indicators."
  :group 'decklet)

(defface decklet-color-hint
  '((t :inherit shadow))
  "Shared color for hint-like elements."
  :group 'decklet)

(defface decklet-color-card-back
  '((t :inherit ansi-color-bright-blue :background reset))
  "Shared color for card-back indicators."
  :group 'decklet)

;; Tags

(defface decklet-color-tags
  '((t :inherit ansi-color-cyan :background reset))
  "Shared face for card tags."
  :group 'decklet)

(defun decklet-normalize-tags (tags)
  "Validate TAGS and return a sorted list of unique tag strings.
Names are case-sensitive, nonempty, and contain no whitespace or colon."
  (unless (proper-list-p tags)
    (user-error "Tags must be a list of strings"))
  (dolist (tag tags)
    (unless (and (stringp tag) (not (string-empty-p tag))
                 (not (string-match-p "[[:space:]:]" tag)))
      (user-error "Invalid tag: %S" tag)))
  (sort (delete-dups (copy-sequence tags)) #'string<))

(defun decklet--normalize-word (word)
  "Normalize WORD and signal an error if empty."
  (let* ((trimmed (string-trim (or word "")))
         (single-line (replace-regexp-in-string "[\r\n]+" " " trimmed)))
    (if (string-empty-p single-line)
        (user-error "Word cannot be empty")
      single-line)))

(defun decklet--normalize-optional-text (text)
  "Trim TEXT and return nil if blank."
  (when text
    (let ((trimmed (string-trim text)))
      (unless (string-empty-p trimmed)
        trimmed))))

;; Lifecycle hooks for extensions.  Each is called with one argument,
;; a non-empty list of per-card event plists.  A batch add fires it once
;; for the whole batch.  Every event has a `:card-id'; each hook's
;; docstring lists the other keys.

(defvar decklet-cards-added-functions nil
  "Abnormal hook called with (EVENTS) after new cards are added.
Each event plist has keys:
  :card-id  id of the added card.")

(defvar decklet-cards-deleted-functions nil
  "Abnormal hook called with (EVENTS) after cards are deleted.
Each event plist has keys:
  :card-id  id of the deleted card.
  :card     full card plist captured before deletion, with keys
            `:word', `:hint', `:back', `:tags', and `:meta'.")

(defvar decklet-cards-renamed-functions nil
  "Abnormal hook called with (EVENTS) after cards are renamed.
Each event plist has keys:
  :card-id   id of the renamed card.
  :old-word  word before the rename.
  :new-word  word after the rename.
Extensions that key data by word must migrate it here.")

(defvar decklet-cards-archived-functions nil
  "Abnormal hook called with (EVENTS) after cards are archived.
Each event plist has keys:
  :card-id  id of the archived card.")

(defvar decklet-cards-unarchived-functions nil
  "Abnormal hook called with (EVENTS) after cards are unarchived.
Each event plist has keys:
  :card-id  id of the unarchived card.")

(defvar decklet-cards-field-updated-functions nil
  "Abnormal hook called with (EVENTS) after card fields are updated.
Each event plist has keys:
  :card-id  id of the updated card.
  :field    symbol naming the field (`hint', `back', `tags', or an
            extension-defined symbol such as `image').")

(defvar decklet-cards-rated-functions nil
  "Abnormal hook called with (EVENTS) after cards are graded.
Each event plist has keys:
  :card-id      id of the graded card.
  :old-meta     card meta before this grading (the FSRS base state used).
  :grade        the grade (1=Again, 2=Hard, 3=Good, 4=Easy).
  :new-meta     card meta after FSRS scheduled the rating.
  :prior-grade  the grade being replaced when the user undoes a rating
                and re-rates the card, or nil.  Per-grade counters
                should take it back.
Undo, confirming an undone rating and skipping a card fire nothing.")

(defun decklet-run-hook-isolated (hook &rest args)
  "Run abnormal HOOK with ARGS, isolating subscriber failures.
Every subscriber runs.  An error from one is reported as a warning,
since the core operation has already committed."
  (apply
   #'run-hook-wrapped
   hook
   (lambda (function &rest args)
     (condition-case err
         (apply function args)
       (error
        (display-warning
         'decklet
         (format "Hook %S failed in %S: %s"
                 hook function (error-message-string err))
         :error)))
     nil)
   args))

(defun decklet-fire-one-card-event (hook &rest plist)
  "Fire HOOK with a one-element event list built from PLIST.
Shorthand for `decklet-run-hook-isolated' with a single-card event."
  (decklet-run-hook-isolated hook (list plist)))

;; Per-card files.  Extensions name them by card id, which survives
;; renames.  Words make bad file names, since "Polish" and "polish"
;; are two cards but one file on a case-insensitive file system.

(defun decklet-card-sidecar-file (directory card-id extension)
  "Return CARD-ID's file with EXTENSION under DIRECTORY.
The file need not exist.  This is the shared naming scheme for
per-card files kept by extensions."
  (unless (integerp card-id)
    (error "Invalid card id: %S" card-id))
  (expand-file-name (format "%d.%s" card-id extension) directory))

;; Utility functions used across modules

(defun decklet--clamp (value min-val max-val)
  "Clamp VALUE to be between MIN-VAL and MAX-VAL."
  (min max-val (max min-val value)))

(defun decklet--mint-monotonic-id (counter-sym &optional seed-fn)
  "Return the next id from the counter in COUNTER-SYM.
The id is the current time in microseconds, or one more than the last
id when the clock has not moved past it.  An empty counter starts from
the value of SEED-FN, or 0."
  (unless (symbol-value counter-sym)
    (set counter-sym (if seed-fn (funcall seed-fn) 0)))
  (let ((now (truncate (* (float-time) 1e6))))
    (set counter-sym (max (1+ (symbol-value counter-sym)) now)))
  (symbol-value counter-sym))

(provide 'decklet-core)
;;; decklet-core.el ends here

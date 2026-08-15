;;; decklet-core.el --- Core shared settings for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Shared root group and directory settings used by all modules.

;;; Code:

(require 'ansi-color)

(defgroup decklet nil
  "A spaced repetition system using the FSRS algorithm."
  :group 'applications)

(defcustom decklet-directory
  (expand-file-name "decklet/" user-emacs-directory)
  "Base directory for all Decklet data files."
  :type 'directory
  :group 'decklet)

;; Shared colors
;;
;; These are pure color definitions: both `:foreground' and
;; `:background' are set to the same color value and no weight is
;; specified.  Derived faces should pull either the foreground or the
;; background via `face-attribute' and layer on whatever weight or
;; height they need for their context.

(defface decklet-color-word
  `((t :foreground ,(face-attribute 'ansi-color-red :foreground)
       :background ,(face-attribute 'ansi-color-red :foreground)))
  "Shared color for words."
  :group 'decklet)

(defface decklet-color-state-new
  `((t :foreground ,(face-attribute 'ansi-color-magenta :foreground)
       :background ,(face-attribute 'ansi-color-magenta :foreground)))
  "Shared color for new-card state indicators."
  :group 'decklet)

(defface decklet-color-state-learning
  `((t :foreground ,(face-attribute 'ansi-color-yellow :foreground)
       :background ,(face-attribute 'ansi-color-yellow :foreground)))
  "Shared color for learning-card state indicators."
  :group 'decklet)

(defface decklet-color-state-review
  `((t :foreground ,(face-attribute 'ansi-color-green :foreground)
       :background ,(face-attribute 'ansi-color-green :foreground)))
  "Shared color for review-card state indicators."
  :group 'decklet)

(defface decklet-color-hint
  `((t :foreground ,(face-attribute 'shadow :foreground)
       :background ,(face-attribute 'shadow :foreground)))
  "Shared color for hint-like elements."
  :group 'decklet)

(defface decklet-color-card-back
  `((t :foreground ,(face-attribute 'ansi-color-bright-blue :foreground)
       :background ,(face-attribute 'ansi-color-bright-blue :foreground)))
  "Shared color for card-back indicators."
  :group 'decklet)

;; Lifecycle hooks for extensions
;;
;; These abnormal hooks allow extensions to react to card mutations
;; without touching Decklet internals.
;;
;; Every hook is an abnormal hook called with a single EVENTS argument:
;; a non-empty list of per-card plists.  Bulk operations (imports, batch
;; add) fire the hook once with all events; single-card operations fire
;; it once with a one-element list.  Every event plist carries at least
;; a `:card-id' key; richer events carry extra keys documented per hook.
;;
;; Consumers iterate:
;;
;;   (defun my/on-cards-deleted (events)
;;     (dolist (event events)
;;       (let ((card-id (plist-get event :card-id))
;;             (card (plist-get event :card)))
;;         ...)))
;;   (add-hook \\='decklet-cards-deleted-functions #\\='my/on-cards-deleted)

(defvar decklet-cards-added-functions nil
  "Abnormal hook called with (EVENTS) after new cards are added.
Each event plist has keys:
  :card-id  id of the added card.")

(defvar decklet-cards-deleted-functions nil
  "Abnormal hook called with (EVENTS) after cards are deleted.
Each event plist has keys:
  :card-id  id of the deleted card.
  :card     full card plist captured before deletion, with keys
            `:word', `:hint', `:back', and `:meta'.")

(defvar decklet-cards-renamed-functions nil
  "Abnormal hook called with (EVENTS) after cards are renamed.
Each event plist has keys:
  :card-id   id of the renamed card.
  :old-word  word before the rename.
  :new-word  word after the rename.
Extensions that key sidecar data by word should migrate their
files or records in this hook.")

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
  :field    symbol naming the field (`hint', `back', `import' for
            bulk JSON imports, or an extension-defined symbol such
            as `image').")

(defvar decklet-cards-rated-functions nil
  "Abnormal hook called with (EVENTS) after cards are graded.
Each event plist has keys:
  :card-id      id of the graded card.
  :old-meta     card meta before this grading (the FSRS base state used).
  :grade        the grade (1=Again, 2=Hard, 3=Good, 4=Easy).
  :new-meta     card meta after FSRS scheduled the rating.
  :prior-grade  nil for fresh ratings.  When the user undoes a rating
                and re-rates within the same session, this is the grade
                being replaced.  Extensions that track per-grade
                statistics should decrement the prior-grade counter to
                compensate for the original event.

This hook does NOT fire on:
  - undo (no DB change)
  - confirming an undone rating (the original event already stands)
  - skip (no rating given)")

(defun decklet-run-hook-isolated (hook &rest args)
  "Run abnormal HOOK with ARGS, isolating subscriber failures.
Every subscriber is attempted.  An error from an extension is reported as a
warning instead of escaping into an already-committed core operation."
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
Convenience wrapper around `decklet-run-hook-isolated' for the common
case of a single-card lifecycle event — avoids hand-writing the
`(list (list ...))' shape at every fire site."
  (decklet-run-hook-isolated hook (list plist)))

;; Utility functions used across modules

(defun decklet--clamp (value min-val max-val)
  "Clamp VALUE to be between MIN-VAL and MAX-VAL."
  (min max-val (max min-val value)))

(defun decklet--timestamp-utc (&optional time)
  "Return TIME formatted as a UTC timestamp for filenames."
  (format-time-string "%Y%m%dT%H%M%SZ" (or time (current-time)) "UTC0"))

(defun decklet--shuffle-list (lst)
  "Return a new randomly shuffled copy of LST.
Fisher-Yates; Emacs has no built-in shuffle."
  (let* ((vec (vconcat lst))
         (len (length vec)))
    (dotimes (i len)
      (let* ((j (+ i (random (- len i))))
             (tmp (aref vec i)))
        (aset vec i (aref vec j))
        (aset vec j tmp)))
    (append vec nil)))

(defun decklet--mint-monotonic-id (counter-sym &optional seed-fn)
  "Return the next strictly monotonic microsecond id stored in COUNTER-SYM.
When the counter is nil, it is seeded from SEED-FN (a zero-arg
function returning an integer) or from the current microsecond
timestamp.  Each subsequent call returns
\(max (1+ previous) current-microsecond) and stores it back.
This yields ids that are dense in time, never collide even under
sub-microsecond bursts, and remain monotonic across Emacs sessions
as long as the system clock advances."
  (unless (symbol-value counter-sym)
    (set counter-sym (if seed-fn (funcall seed-fn) 0)))
  (let ((now (truncate (* (float-time) 1e6))))
    (set counter-sym (max (1+ (symbol-value counter-sym)) now)))
  (symbol-value counter-sym))

(provide 'decklet-core)
;;; decklet-core.el ends here

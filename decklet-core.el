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

;; Shared faces

(defface decklet-word-face
  `((t :foreground ,(face-attribute 'ansi-color-red :foreground)
       :weight bold))
  "Shared face for displaying words."
  :group 'decklet)

(defface decklet-state-new-face
  `((t :foreground ,(face-attribute 'ansi-color-magenta :foreground)
       :weight bold))
  "Shared face for new-card state indicators."
  :group 'decklet)

(defface decklet-state-learning-face
  `((t :foreground ,(face-attribute 'ansi-color-yellow :foreground)
       :weight bold))
  "Shared face for learning-card state indicators."
  :group 'decklet)

(defface decklet-state-review-face
  `((t :foreground ,(face-attribute 'ansi-color-green :foreground)
       :weight bold))
  "Shared face for review-card state indicators."
  :group 'decklet)

(defface decklet-card-back-indicator-face
  `((t :foreground ,(face-attribute 'ansi-color-bright-blue :foreground)
       :weight bold))
  "Face for the card back indicator."
  :group 'decklet)

;; Lifecycle hooks for extensions
;;
;; These abnormal hooks allow extensions to react to card mutations
;; without touching Decklet internals.  Each hook is called with
;; arguments matching the event's natural shape — see the docstrings.

(defvar decklet-card-added-functions nil
  "Abnormal hook called with (WORD) after a new card is added.")

(defvar decklet-card-deleted-functions nil
  "Abnormal hook called with (WORD) after a card is deleted.")

(defvar decklet-card-renamed-functions nil
  "Abnormal hook called with (OLD-WORD NEW-WORD) after a card is renamed.
Extensions that key sidecar data by word should migrate their
files or records in this hook.")

(defvar decklet-card-archived-functions nil
  "Abnormal hook called with (WORD) after a card is archived.")

(defvar decklet-card-unarchived-functions nil
  "Abnormal hook called with (WORD) after a card is unarchived.")

(defvar decklet-card-field-updated-functions nil
  "Abnormal hook called with (WORD FIELD) after a card field is updated.
FIELD is one of the symbols `hint' or `back'.")

(defvar decklet-card-rated-functions nil
  "Abnormal hook called with (WORD OLD-META GRADE NEW-META PRIOR-GRADE)
after a card is graded via review or edit mode.

Arguments:
  WORD         the word being graded.
  OLD-META     card meta before this grading (the FSRS base state used).
  GRADE        the grade (1=Again, 2=Hard, 3=Good, 4=Easy).
  NEW-META     card meta after FSRS scheduled the rating.
  PRIOR-GRADE  nil for fresh ratings.  When the user undoes a rating
               and re-rates within the same session, this is the grade
               being replaced.  Extensions that track per-grade
               statistics should decrement the PRIOR-GRADE counter to
               compensate for the original event.

This hook does NOT fire on:
  - undo (no DB change)
  - confirming an undone rating (the original event already stands)
  - skip (no rating given)")

;; Utility functions used across modules

(defun decklet--clamp (value min-val max-val)
  "Clamp VALUE to be between MIN-VAL and MAX-VAL."
  (min max-val (max min-val value)))

(defun decklet--shuffle-list (lst)
  "Return a new randomly shuffled copy of LST."
  (let* ((vec (vconcat lst))
         (len (length vec)))
    ;; Fisher-Yates shuffle for unbiased results.
    (dotimes (i len)
      (let* ((j (+ i (random (- len i))))
             (tmp (aref vec i)))
        (aset vec i (aref vec j))
        (aset vec j tmp)))
    (append vec nil)))

(defun decklet--json-parse-safe (json-string context)
  "Parse JSON-STRING, reporting errors with CONTEXT."
  (condition-case err
      (json-parse-string json-string :object-type 'alist)
    (error
     (message "%s: %s" context (error-message-string err))
     nil)))

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

;;; decklite-schedular.el --- Scheduler core for DeckLite -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Scheduler and shared data structures for DeckLite.

;;; Code:

(require 'cl-lib)
(require 'fsrs)
(require 'json)
(require 'subr-x)

(require 'decklite-core)

(defgroup decklite-scheduler nil
  "Scheduler for DeckLite."
  :group 'decklite)

(defvar decklite--fsrs-scheduler nil
  "Cached FSRS scheduler instance for DeckLite.")

;; Shared configuration is defined in decklite.el.

(defcustom decklite-desired-retention 0.9
  "Desired retention (between 0.0 and 1.0) for scheduling reviews.
Higher values (closer to 1.0) mean more frequent reviews.
Lower values allow longer intervals but higher risk of forgetting."
  :type 'float
  :set (lambda (symbol value)
         (set-default symbol value)
         (setq decklite--fsrs-scheduler nil))
  :group 'decklite-scheduler)

(defcustom decklite-learning-steps '((10 :minute) (1 :day))
  "Learning steps for FSRS.
Each step is a list of (AMOUNT UNIT), where UNIT is :sec/:minute/:hour/:day.
Set to nil to disable the learning stage."
  :type '(repeat (list (number :tag "Amount")
                       (choice (const :sec)
                               (const :minute)
                               (const :hour)
                               (const :day))))
  :set (lambda (symbol value)
         (set-default symbol value)
         (setq decklite--fsrs-scheduler nil))
  :group 'decklite-scheduler)

(defcustom decklite-relearning-steps '((10 :minute))
  "Relearning steps for FSRS after a lapse.
Each step is a list of (AMOUNT UNIT), where UNIT is :sec/:minute/:hour/:day.
Set to nil to disable relearning steps."
  :type '(repeat (list (number :tag "Amount")
                       (choice (const :sec)
                               (const :minute)
                               (const :hour)
                               (const :day))))
  :set (lambda (symbol value)
         (set-default symbol value)
         (setq decklite--fsrs-scheduler nil))
  :group 'decklite-scheduler)

(defcustom decklite-day-rollover-hour 4
  "Hour of day (0-23) that starts a new review day."
  :type 'integer
  :group 'decklite-scheduler)

(defvar decklite--counter '(:reviewed 0 :due-review 0 :due-learning 0 :new 0)
  "Counter for reviewed, due-review, due-learning, and new cards.")

(cl-defstruct (decklite-card-meta)
  ;; Card metadata keyed by word string.
  (added-date (fsrs-now))
  (last-review nil)
  (due (fsrs-now))
  (state :learning)
  (step 0)
  (stability nil)
  (difficulty nil)
  (hint nil))

(defun decklite-card-meta-is-new (meta)
  "Check if the card described by META is new (never reviewed)."
  (null (decklite-card-meta-last-review meta)))

(defun decklite--clamp (value min-val max-val)
  "Clamp VALUE to be between MIN-VAL and MAX-VAL."
  (min max-val (max min-val value)))

(defun decklite--shuffle-list (lst)
  "Shuffle LST randomly."
  (let* ((vec (vconcat lst))
         (len (length vec)))
    ;; Fisher-Yates shuffle for unbiased results.
    (dotimes (i len)
      (let* ((j (+ i (random (- len i))))
             (tmp (aref vec i)))
        (aset vec i (aref vec j))
        (aset vec j tmp)))
    (append vec nil)))

(defun decklite--json-parse-safe (json-string context)
  "Parse JSON-STRING, reporting errors with CONTEXT."
  (condition-case err
      (json-parse-string json-string :object-type 'alist)
    (error
     (message "%s: %s" context (error-message-string err))
     nil)))

(defun decklite--get-fsrs-scheduler ()
  "Return a configured FSRS scheduler for DeckLite."
  (or decklite--fsrs-scheduler
      (setq decklite--fsrs-scheduler
            (fsrs-make-scheduler
             :desired-retention decklite-desired-retention
             :learning-steps decklite-learning-steps
             :relearning-steps decklite-relearning-steps
             :enable-fuzzing-p nil))))

(defun decklite--normalize-fsrs-state (state)
  "Normalize STATE into an FSRS keyword."
  (cond
   ((keywordp state) state)
   ((stringp state)
    (intern (if (string-prefix-p ":" state) state (concat ":" state))))
   (t nil)))

(defun decklite--fsrs-state-string (state)
  "Return the serialized string representation of STATE."
  (when state
    (let ((name (symbol-name state)))
      (if (string-prefix-p ":" name) (substring name 1) name))))

(defun decklite--fsrs-rating-from-grade (grade)
  "Convert numeric GRADE to FSRS rating keyword."
  (pcase grade
    (1 :again)
    (2 :hard)
    (3 :good)
    (4 :easy)
    (_ (error "Invalid grade: %s" grade))))

(defun decklite--day-start-time (&optional time)
  "Return the start time of the review day containing TIME."
  (let* ((time (or time (current-time)))
         (decoded (decode-time time))
         (day (nth 3 decoded))
         (month (nth 4 decoded))
         (year (nth 5 decoded))
         (rollover (decklite--clamp decklite-day-rollover-hour 0 23))
         (day-start (encode-time 0 0 rollover day month year)))
    (if (time-less-p time day-start)
        (time-subtract day-start (days-to-time 1))
      day-start)))

(defun decklite--next-day-start-time (&optional time)
  "Return the next review day start time after TIME."
  (time-add (decklite--day-start-time time) (days-to-time 1)))

(defun decklite--time->fsrs-timestamp (time)
  "Return TIME formatted as an FSRS timestamp string."
  (fsrs-now time))

(defun decklite--card-meta->fsrs-card (word meta)
  "Create an FSRS card for WORD from card META."
  (let ((card-id (abs (sxhash word))))
    (fsrs-make-card
     :card-id card-id
     :state (or (decklite-card-meta-state meta) :learning)
     :step (decklite-card-meta-step meta)
     :stability (decklite-card-meta-stability meta)
     :difficulty (decklite-card-meta-difficulty meta)
     :due (or (decklite-card-meta-due meta) (fsrs-now))
     :last-review (decklite-card-meta-last-review meta))))

(defun decklite--apply-fsrs-card (meta card)
  "Update card META in-place from FSRS CARD and return META."
  (setf (decklite-card-meta-state meta) (fsrs-card-state card))
  (setf (decklite-card-meta-step meta) (fsrs-card-step card))
  (setf (decklite-card-meta-stability meta) (fsrs-card-stability card))
  (setf (decklite-card-meta-difficulty meta) (fsrs-card-difficulty card))
  (setf (decklite-card-meta-due meta) (fsrs-card-due card))
  (setf (decklite-card-meta-last-review meta) (fsrs-card-last-review card))
  meta)

(defun decklite--update-card-with-grade (word meta grade)
  "Update card META for WORD based on GRADE rating (1-4)."
  (let* ((scheduler (decklite--get-fsrs-scheduler))
         (rating (decklite--fsrs-rating-from-grade grade))
         (review-time (fsrs-now))
         (card (decklite--card-meta->fsrs-card word meta))
         (new-card (cl-nth-value 0
                                 (fsrs-scheduler-review-card
                                  scheduler card rating review-time))))
    (decklite--apply-fsrs-card meta new-card))
  meta)

(provide 'decklite-schedular)
;;; decklite-schedular.el ends here

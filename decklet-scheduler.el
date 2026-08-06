;;; decklet-scheduler.el --- Scheduler core for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Scheduler and shared data structures for Decklet.

;;; Code:

(require 'cl-lib)
(require 'fsrs)
(require 'subr-x)

(require 'decklet-core)

(defgroup decklet-scheduler nil
  "Scheduler for Decklet."
  :group 'decklet)

(defvar decklet--fsrs-scheduler nil
  "Cached FSRS scheduler instance for Decklet.")

;; Shared configuration is defined in decklet.el.

(defcustom decklet-desired-retention 0.9
  "Desired retention (between 0.0 and 1.0) for scheduling reviews.
Higher values (closer to 1.0) mean more frequent reviews.
Lower values allow longer intervals but higher risk of forgetting."
  :type 'float
  :set (lambda (symbol value)
         (set-default symbol value)
         (setq decklet--fsrs-scheduler nil))
  :group 'decklet-scheduler)

(defcustom decklet-learning-steps '((10 :minute) (1 :day))
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
         (setq decklet--fsrs-scheduler nil))
  :group 'decklet-scheduler)

(defcustom decklet-relearning-steps '((10 :minute))
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
         (setq decklet--fsrs-scheduler nil))
  :group 'decklet-scheduler)

(defcustom decklet-day-rollover-hour 4
  "Hour of day (0-23) that starts a new review day."
  :type '(integer :tag "Hour (0-23)")
  :group 'decklet-scheduler)

(defcustom decklet-fsrs-parameters nil
  "Optional override for the FSRS parameter weight vector.
When non-nil, must be a vector of 21 floats passed as the
`:parameters' argument to `fsrs-make-scheduler'.  When nil, the
FSRS library's built-in defaults are used.

Typically set by an external tuner after fine-tuning on the
persistent review log."
  :type '(choice (const :tag "FSRS library defaults" nil)
                 (restricted-sexp :tag "Custom 21-float parameter vector"
                                  :match-alternatives (vectorp)))
  :set (lambda (symbol value)
         (set-default symbol value)
         (setq decklet--fsrs-scheduler nil))
  :group 'decklet-scheduler)

(defvar decklet--counter '(:reviewed 0 :due-review 0 :due-learning 0 :new 0)
  "Counter for reviewed, due-review, due-learning, and new cards.")

(cl-defstruct (decklet-card-meta)
  ;; Scheduling metadata only.  Content fields (hint, back) live in the DB.
  (card-id nil)
  (added-date (decklet--now))
  (last-review nil)
  (due (decklet--now))
  (state :learning)
  (step 0)
  (stability nil)
  (difficulty nil))

(defun decklet-last-review-empty-p (last-review)
  "Return non-nil when LAST-REVIEW means never reviewed.
LAST-REVIEW is considered empty when it is nil or an empty string."
  (string-empty-p (or last-review "")))

(defun decklet-card-meta-effective-state-new-p (meta)
  "Check if the card described by META is new (never reviewed)."
  (eq (decklet-card-meta-effective-state meta) :new))

(defun decklet-card-effective-state (state last-review)
  "Return effective state derived from STATE and LAST-REVIEW.
The result is one of `:new', `:learning', `:relearning', or `:review'."
  (if (decklet-last-review-empty-p last-review)
      :new
    (pcase (decklet--normalize-fsrs-state state)
      (:learning :learning)
      (:relearning :relearning)
      (_ :review))))

(defun decklet-card-meta-effective-state (meta)
  "Return effective state keyword for card META.
The result is one of `:new', `:learning', `:relearning', or `:review'."
  (decklet-card-effective-state (decklet-card-meta-state meta)
                                (decklet-card-meta-last-review meta)))


(defun decklet--get-fsrs-scheduler ()
  "Return a configured FSRS scheduler for Decklet."
  (or decklet--fsrs-scheduler
      (setq decklet--fsrs-scheduler
            (apply #'fsrs-make-scheduler
                   :desired-retention decklet-desired-retention
                   :learning-steps decklet-learning-steps
                   :relearning-steps decklet-relearning-steps
                   :enable-fuzzing-p nil
                   (when decklet-fsrs-parameters
                     (list :parameters decklet-fsrs-parameters))))))

(defun decklet--normalize-fsrs-state (state)
  "Normalize STATE into an FSRS keyword."
  (cond
   ((keywordp state) state)
   ((stringp state)
    (intern (if (string-prefix-p ":" state) state (concat ":" state))))
   (t nil)))

(defun decklet--fsrs-schedulable-state (state)
  "Return the FSRS scheduler state for STATE.
Decklet uses `:new' as an effective display state for never-reviewed
cards, but FSRS schedules those cards from the learning state."
  (let ((state (decklet--normalize-fsrs-state state)))
    (cond
     ((eq state :new) :learning)
     ((memq state '(:learning :review :relearning)) state)
     (t (error "Invalid FSRS state: %S" state)))))

(defun decklet-fsrs-state-string (state)
  "Return the serialized string representation of STATE."
  (when state
    (let ((name (symbol-name state)))
      (if (string-prefix-p ":" name) (substring name 1) name))))

(defun decklet--fsrs-rating-from-grade (grade)
  "Convert numeric GRADE to FSRS rating keyword."
  (pcase grade
    (1 :again)
    (2 :hard)
    (3 :good)
    (4 :easy)
    (_ (error "Invalid grade: %s" grade))))

(defun decklet--rollover-time-on-relative-date (time day-offset)
  "Return rollover time DAY-OFFSET calendar days from TIME's local date."
  (let* ((decoded (decode-time time))
         (day (+ (nth 3 decoded) day-offset))
         (month (nth 4 decoded))
         (year (nth 5 decoded))
         (rollover (decklet--clamp decklet-day-rollover-hour 0 23)))
    (encode-time 0 0 rollover day month year)))

(defun decklet-day-start-time (&optional time)
  "Return the start time of the review day containing TIME."
  (let* ((time (or time (current-time)))
         (day-start (decklet--rollover-time-on-relative-date time 0)))
    (if (time-less-p time day-start)
        (decklet--rollover-time-on-relative-date time -1)
      day-start)))

(defun decklet--next-day-start-time (&optional time)
  "Return the next review day start time after TIME."
  (decklet--rollover-time-on-relative-date
   (decklet-day-start-time time) 1))

(defun decklet--now ()
  "Return the current time as an FSRS timestamp string."
  (fsrs-now))

(defun decklet--time->fsrs-timestamp (time)
  "Return TIME formatted as an FSRS timestamp string."
  (fsrs-now time))

(defun decklet--elapsed-days-since (last-review &optional now)
  "Return the number of days elapsed between LAST-REVIEW and NOW.
Both arguments are FSRS timestamp strings; NOW defaults to the
current time via `decklet--now'.  Returns 0.0 when LAST-REVIEW is
nil or empty (i.e. the card has never been reviewed)."
  (if (or (null last-review) (string-empty-p last-review))
      0.0
    (/ (fsrs-timestamp-difference (or now (decklet--now)) last-review)
       86400.0)))

(defun decklet--card-meta->fsrs-card (meta)
  "Create an FSRS card from card META.
META's `card-id' is used directly as the FSRS card id."
  (fsrs-make-card
   :card-id (decklet-card-meta-card-id meta)
   :state (decklet--fsrs-schedulable-state
           (decklet-card-meta-state meta))
   :step (decklet-card-meta-step meta)
   :stability (decklet-card-meta-stability meta)
   :difficulty (decklet-card-meta-difficulty meta)
   :due (decklet-card-meta-due meta)
   :last-review (decklet-card-meta-last-review meta)))

(defun decklet--apply-fsrs-card (meta card)
  "Update card META in-place from FSRS CARD and return META."
  (setf (decklet-card-meta-state meta)       (fsrs-card-state card)
        (decklet-card-meta-step meta)        (fsrs-card-step card)
        (decklet-card-meta-stability meta)   (fsrs-card-stability card)
        (decklet-card-meta-difficulty meta)  (fsrs-card-difficulty card)
        (decklet-card-meta-due meta)         (fsrs-card-due card)
        (decklet-card-meta-last-review meta) (fsrs-card-last-review card))
  meta)

(defun decklet--simulate-fsrs-review (meta grade)
  "Run FSRS scheduler on META with GRADE without mutating META.
Return the list (NEW-FSRS-CARD REVIEW-TIME)."
  (let* ((scheduler (decklet--get-fsrs-scheduler))
         (rating (decklet--fsrs-rating-from-grade grade))
         (review-time (decklet--now))
         (card (decklet--card-meta->fsrs-card meta)))
    (list (cl-nth-value 0 (fsrs-scheduler-review-card
                           scheduler card rating review-time))
          review-time)))

(defun decklet--simulate-review-interval (meta grade)
  "Return predicted interval in seconds for GRADE on card META.
Simulates one FSRS review without mutating META."
  (pcase-let ((`(,new-card ,review-time)
               (decklet--simulate-fsrs-review meta grade)))
    (fsrs-timestamp-difference (fsrs-card-due new-card) review-time)))

(defun decklet--update-meta-with-grade (meta grade)
  "Return a new card META with GRADE applied via FSRS.
Does not mutate META; the returned value is a fresh copy with the
scheduling fields updated."
  (let ((new-card (car (decklet--simulate-fsrs-review meta grade))))
    (decklet--apply-fsrs-card (copy-decklet-card-meta meta) new-card)))

(provide 'decklet-scheduler)
;;; decklet-scheduler.el ends here

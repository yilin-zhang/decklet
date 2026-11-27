;;; decklet-scheduler.el --- Scheduler core for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yilin Zhang

;;; Commentary:

;; Scheduler and shared data structures for Decklet.

;;; Code:

(require 'cl-lib)
(require 'fsrs)

(require 'decklet-core)

(defgroup decklet-scheduler nil
  "Scheduler for Decklet."
  :group 'decklet)

(defvar decklet--fsrs-scheduler nil
  "Cached FSRS scheduler instance for Decklet.")

(defun decklet--set-scheduler-option (symbol value)
  "Set SYMBOL to VALUE and invalidate the cached FSRS scheduler."
  (set-default symbol value)
  (setq decklet--fsrs-scheduler nil))

(defcustom decklet-desired-retention 0.9
  "Desired retention (between 0.0 and 1.0) for scheduling reviews.
Higher values (closer to 1.0) mean more frequent reviews.
Lower values allow longer intervals but higher risk of forgetting."
  :type 'float
  :set #'decklet--set-scheduler-option
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
  :set #'decklet--set-scheduler-option
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
  :set #'decklet--set-scheduler-option
  :group 'decklet-scheduler)

(defcustom decklet-day-rollover-hour 4
  "Hour of day (0-23) that starts a new review day."
  :type '(integer :tag "Hour (0-23)")
  :group 'decklet-scheduler)

(defcustom decklet-fsrs-parameters nil
  "Vector of 21 FSRS weights, or nil for the FSRS library defaults."
  :type '(choice (const :tag "FSRS library defaults" nil)
                 (restricted-sexp :tag "Custom 21-float parameter vector"
                                  :match-alternatives (vectorp)))
  :set #'decklet--set-scheduler-option
  :group 'decklet-scheduler)

(defun decklet-set-fsrs-parameters (params)
  "Set `decklet-fsrs-parameters' to PARAMS and drop the cached scheduler."
  (decklet--set-scheduler-option 'decklet-fsrs-parameters params))

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

(defun decklet-card-effective-state (state last-review)
  "Return effective state derived from STATE and LAST-REVIEW.
The result is one of `:new', `:learning', `:relearning', or `:review'."
  (if (null last-review)
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
  (if (stringp state)
      (intern (concat ":" state))
    state))

(defun decklet-fsrs-state-string (state)
  "Return the serialized string representation of STATE."
  (when state
    (substring (symbol-name state) 1)))

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

(defun decklet--now (&optional time)
  "Return TIME, or the current time, as an FSRS timestamp string."
  (fsrs-now time))

(defun decklet--timestamp-difference (ts1 ts2)
  "Return the difference in seconds between timestamps TS1 and TS2."
  (fsrs-timestamp-difference ts1 ts2))

(defun decklet--card-meta->fsrs-card (meta)
  "Create an FSRS card from card META.
META's `card-id' is used directly as the FSRS card id."
  (let* ((raw-state (decklet--normalize-fsrs-state
                     (decklet-card-meta-state meta)))
         ;; Never-reviewed cards use `:new' for display, `:learning' in FSRS.
         (state (cond
                 ((eq raw-state :new) :learning)
                 ((memq raw-state '(:learning :review :relearning)) raw-state)
                 (t (error "Invalid FSRS state: %S" raw-state)))))
    (fsrs-make-card
     :card-id (decklet-card-meta-card-id meta)
     :state state
     :step (decklet-card-meta-step meta)
     :stability (decklet-card-meta-stability meta)
     :difficulty (decklet-card-meta-difficulty meta)
     :due (decklet-card-meta-due meta)
     :last-review (decklet-card-meta-last-review meta))))

(defun decklet--simulate-fsrs-review (meta grade)
  "Run FSRS scheduler on META with GRADE without mutating META.
Return the list (NEW-FSRS-CARD REVIEW-TIME)."
  (let* ((scheduler (decklet--get-fsrs-scheduler))
         (rating (pcase grade
                   (1 :again)
                   (2 :hard)
                   (3 :good)
                   (4 :easy)
                   (_ (error "Invalid grade: %s" grade))))
         (review-time (decklet--now))
         (card (decklet--card-meta->fsrs-card meta)))
    (list (car (fsrs-scheduler-review-card scheduler card rating review-time))
          review-time)))

(defun decklet--simulate-review-interval (meta grade)
  "Return predicted interval in seconds for GRADE on card META.
Simulates one FSRS review without mutating META."
  (pcase-let ((`(,new-card ,review-time)
               (decklet--simulate-fsrs-review meta grade)))
    (fsrs-timestamp-difference (fsrs-card-due new-card) review-time)))

(defun decklet--update-meta-with-grade (meta grade)
  "Return a copy of card META with GRADE applied via FSRS."
  (let ((new-card (car (decklet--simulate-fsrs-review meta grade)))
        (updated (copy-decklet-card-meta meta)))
    (setf (decklet-card-meta-state updated)       (fsrs-card-state new-card)
          (decklet-card-meta-step updated)        (fsrs-card-step new-card)
          (decklet-card-meta-stability updated)   (fsrs-card-stability new-card)
          (decklet-card-meta-difficulty updated)  (fsrs-card-difficulty new-card)
          (decklet-card-meta-due updated)         (fsrs-card-due new-card)
          (decklet-card-meta-last-review updated) (fsrs-card-last-review new-card))
    updated))

(provide 'decklet-scheduler)
;;; decklet-scheduler.el ends here

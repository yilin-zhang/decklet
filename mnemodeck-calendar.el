;;; mnemodeck-calendar.el --- Calendar integration for MnemoDeck -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Calendar due-count highlighting.

;;; Code:

(require 'ansi-color)
(require 'calendar)

(require 'mnemodeck-db)

(defgroup mnemodeck-calendar nil
  "Calendar integration for MnemoDeck."
  :group 'mnemodeck)

(defcustom mnemodeck-calendar-days-ahead 90
  "Number of days ahead to calculate due cards for calendar display."
  :type 'integer
  :group 'mnemodeck-calendar)

(defcustom mnemodeck-calendar-thresholds
  '(25 50 75)
  "List of 3 thresholds for highlighting calendar dates with due cards.
Each value represents the maximum number of cards for a new color level."
  :type '(repeat integer)
  :group 'mnemodeck-calendar)

(defface mnemodeck-calendar-level-1-face
  `((t :background ,(face-attribute 'ansi-color-green :foreground)
       :foreground ,(face-attribute 'ansi-color-black :foreground)
       :weight bold))
  "Face for dates with few due cards (level 1)."
  :group 'mnemodeck-calendar)

(defface mnemodeck-calendar-level-2-face
  `((t :background ,(face-attribute 'ansi-color-yellow :foreground)
       :foreground ,(face-attribute 'ansi-color-black :foreground)
       :weight bold))
  "Face for dates with some due cards (level 2)."
  :group 'mnemodeck-calendar)

(defface mnemodeck-calendar-level-3-face
  `((t :background ,(face-attribute 'ansi-color-red :foreground)
       :foreground ,(face-attribute 'ansi-color-black :foreground)
       :weight bold))
  "Face for dates with many due cards (level 3)."
  :group 'mnemodeck-calendar)

(defface mnemodeck-calendar-level-4-face
  `((t :background ,(face-attribute 'ansi-color-magenta :foreground)
       :foreground ,(face-attribute 'ansi-color-black :foreground)
       :weight bold))
  "Face for dates with very many due cards (level 4)."
  :group 'mnemodeck-calendar)

(defvar mnemodeck-calendar--due-counts (make-hash-table :test 'equal)
  "Cache of due-card counts keyed by calendar date.")

;; Internal functions

(defun mnemodeck-calendar--get-face-for-count (count)
  "Return the appropriate face for COUNT due cards."
  (let ((thresholds mnemodeck-calendar-thresholds))
    (cond
     ((< count (nth 0 thresholds)) 'mnemodeck-calendar-level-1-face)
     ((< count (nth 1 thresholds)) 'mnemodeck-calendar-level-2-face)
     ((< count (nth 2 thresholds)) 'mnemodeck-calendar-level-3-face)
     (t 'mnemodeck-calendar-level-4-face))))

(defun mnemodeck-calendar--date-string-to-date (date-string)
  "Convert DATE-STRING (YYYY-MM-DD) into (month day year) calendar date."
  (when (and date-string (string-match "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)\\'" date-string))
    (list (string-to-number (match-string 2 date-string))
          (string-to-number (match-string 3 date-string))
          (string-to-number (match-string 1 date-string)))))

(defun mnemodeck-calendar--time->calendar-date (time)
  "Convert TIME to a calendar date list (month day year)."
  (let ((decoded (decode-time time)))
    (list (nth 4 decoded) (nth 3 decoded) (nth 5 decoded))))

(defun mnemodeck-calendar--hash-inc (table key delta)
  "Increment TABLE at KEY by DELTA."
  (puthash key (+ delta (gethash key table 0)) table))

(defun mnemodeck-calendar--get-due-cards-by-date ()
  "Get a hash table mapping due dates to card counts.
Dates follow the review day defined by `mnemodeck-day-rollover-hour'."
  (let* ((due-counts (make-hash-table :test 'equal))
         (day-start (mnemodeck--day-start-time))
         (cutoff (time-add day-start (days-to-time mnemodeck-calendar-days-ahead)))
         (result (mnemodeck-db--due-counts-by-date day-start cutoff))
         (rows (plist-get result :rows))
         (overdue-count (plist-get result :overdue)))
    ;; Rows are grouped by local date; add each to the calendar hash.
    (dolist (row rows)
      (pcase-let ((`(,date-string ,count) row))
        (when-let ((date (mnemodeck-calendar--date-string-to-date date-string)))
          (mnemodeck-calendar--hash-inc due-counts date count))))
    ;; Overdue cards are shown on today so they remain visible.
    (when (> overdue-count 0)
      (let ((today-date (mnemodeck-calendar--time->calendar-date day-start)))
        (mnemodeck-calendar--hash-inc due-counts today-date overdue-count)))
    due-counts))

(defun mnemodeck-calendar--refresh-due-counts ()
  "Refresh cached due-counts for calendar display."
  (setq mnemodeck-calendar--due-counts (mnemodeck-calendar--get-due-cards-by-date)))

(defun mnemodeck-calendar--mark-dates-with-due-cards ()
  "Mark calendar dates with due cards using appropriate faces."
  (let* ((displayed-month (and (boundp 'displayed-month) displayed-month))
         (displayed-year (and (boundp 'displayed-year) displayed-year)))
    (when (and displayed-month displayed-year)
      (maphash (lambda (date count)
                 (let* ((due-month (nth 0 date))
                        (due-year (nth 2 date))
                        (due-n-month (+ due-month (* 12 due-year)))
                        (max-n-month (+ (1+ displayed-month) (* 12 displayed-year)))
                        (min-n-month (+ (1- displayed-month) (* 12 displayed-year))))
                   ;; Filter out dates that are not currently displayed.
                   (when (and (<= due-n-month max-n-month)
                              (<= min-n-month due-n-month))
                     (let ((face (mnemodeck-calendar--get-face-for-count count)))
                       (calendar-mark-visible-date date face)))))
               mnemodeck-calendar--due-counts))))

;;;###autoload
(defun mnemodeck-calendar-mark-due-dates ()
  "Mark dates with due cards on the calendar."
  (interactive)
  (mnemodeck-calendar--refresh-due-counts)
  ;; First clear any existing marks
  (calendar-unmark)
  ;; Then mark dates with due cards
  (mnemodeck-calendar--mark-dates-with-due-cards)
  (message "Marked dates with due cards"))

;;;###autoload
(defun mnemodeck-calendar-show-due-count-at-date ()
  "Show the number of cards due on the selected date."
  (interactive)
  (let* ((date (calendar-cursor-to-date))
         (count (gethash date mnemodeck-calendar--due-counts 0)))
    (if (> count 0)
        (message "%d card%s due on %s"
                 count
                 (if (= count 1) "" "s")
                 (calendar-date-string date)))))

;; Define a minor mode for the calendar integration
;;;###autoload
(define-minor-mode mnemodeck-calendar-mode
  "Toggle MnemoDeck calendar integration.
When enabled, dates with due cards are highlighted in the calendar."
  :global t
  :lighter " MnemoDeckCal"
  :group 'mnemodeck-calendar
  (if mnemodeck-calendar-mode
      (progn
        (add-hook 'calendar-mode-hook 'mnemodeck-calendar--refresh-due-counts)
        (add-hook 'calendar-today-visible-hook 'mnemodeck-calendar-mark-due-dates)
        (add-hook 'calendar-today-invisible-hook 'mnemodeck-calendar-mark-due-dates)
        (add-hook 'calendar-move-hook 'mnemodeck-calendar-show-due-count-at-date))
    (remove-hook 'calendar-mode-hook 'mnemodeck-calendar--refresh-due-counts)
    (remove-hook 'calendar-today-visible-hook 'mnemodeck-calendar-mark-due-dates)
    (remove-hook 'calendar-today-invisible-hook 'mnemodeck-calendar-mark-due-dates)
    (remove-hook 'calendar-move-hook 'mnemodeck-calendar-show-due-count-at-date)))

(provide 'mnemodeck-calendar)
;;; mnemodeck-calendar.el ends here

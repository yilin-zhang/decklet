;;; decklite-calendar.el --- Calendar integration for DeckLite -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Calendar due-count highlighting.

;;; Code:

(require 'ansi-color)
(require 'calendar)

(require 'decklite-db)

(defgroup decklite-calendar nil
  "Calendar integration for DeckLite."
  :group 'decklite)

(defcustom decklite-calendar-days-ahead 90
  "Number of days ahead to calculate due cards for calendar display."
  :type 'integer
  :group 'decklite-calendar)

(defcustom decklite-calendar-thresholds
  '(25 50 75)
  "List of 3 thresholds for highlighting calendar dates with due cards.
Each value represents the maximum number of cards for a new color level."
  :type '(repeat integer)
  :group 'decklite-calendar)

(defface decklite-calendar-level-1-face
  `((t :background ,(face-attribute 'ansi-color-green :foreground)
       :foreground ,(face-attribute 'ansi-color-black :foreground)
       :weight bold))
  "Face for dates with few due cards (level 1)."
  :group 'decklite-calendar)

(defface decklite-calendar-level-2-face
  `((t :background ,(face-attribute 'ansi-color-yellow :foreground)
       :foreground ,(face-attribute 'ansi-color-black :foreground)
       :weight bold))
  "Face for dates with some due cards (level 2)."
  :group 'decklite-calendar)

(defface decklite-calendar-level-3-face
  `((t :background ,(face-attribute 'ansi-color-red :foreground)
       :foreground ,(face-attribute 'ansi-color-black :foreground)
       :weight bold))
  "Face for dates with many due cards (level 3)."
  :group 'decklite-calendar)

(defface decklite-calendar-level-4-face
  `((t :background ,(face-attribute 'ansi-color-magenta :foreground)
       :foreground ,(face-attribute 'ansi-color-black :foreground)
       :weight bold))
  "Face for dates with very many due cards (level 4)."
  :group 'decklite-calendar)

(defvar decklite-calendar--due-counts (make-hash-table :test 'equal)
  "Cache of due-card counts keyed by calendar date.")

;; Internal functions

(defun decklite-calendar--get-face-for-count (count)
  "Return the appropriate face for COUNT due cards."
  (let ((thresholds decklite-calendar-thresholds))
    (cond
     ((< count (nth 0 thresholds)) 'decklite-calendar-level-1-face)
     ((< count (nth 1 thresholds)) 'decklite-calendar-level-2-face)
     ((< count (nth 2 thresholds)) 'decklite-calendar-level-3-face)
     (t 'decklite-calendar-level-4-face))))

(defun decklite-calendar--date-string-to-date (date-string)
  "Convert DATE-STRING (YYYY-MM-DD) into (month day year) calendar date."
  (when (and date-string (string-match "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)\\'" date-string))
    (list (string-to-number (match-string 2 date-string))
          (string-to-number (match-string 3 date-string))
          (string-to-number (match-string 1 date-string)))))

(defun decklite-calendar--time->calendar-date (time)
  "Convert TIME to a calendar date list (month day year)."
  (let ((decoded (decode-time time)))
    (list (nth 4 decoded) (nth 3 decoded) (nth 5 decoded))))

(defun decklite-calendar--hash-inc (table key delta)
  "Increment TABLE at KEY by DELTA."
  (puthash key (+ delta (gethash key table 0)) table))

(defun decklite-calendar--get-due-cards-by-date ()
  "Get a hash table mapping due dates to card counts.
Dates follow the review day defined by `decklite-day-rollover-hour'."
  (let* ((due-counts (make-hash-table :test 'equal))
         (day-start (decklite--day-start-time))
         (cutoff (time-add day-start (days-to-time decklite-calendar-days-ahead)))
         (result (decklite-db--due-counts-by-date day-start cutoff))
         (rows (plist-get result :rows))
         (overdue-count (plist-get result :overdue)))
    ;; Rows are grouped by local date; add each to the calendar hash.
    (dolist (row rows)
      (pcase-let ((`(,date-string ,count) row))
        (when-let ((date (decklite-calendar--date-string-to-date date-string)))
          (decklite-calendar--hash-inc due-counts date count))))
    ;; Overdue cards are shown on today so they remain visible.
    (when (> overdue-count 0)
      (let ((today-date (decklite-calendar--time->calendar-date day-start)))
        (decklite-calendar--hash-inc due-counts today-date overdue-count)))
    due-counts))

(defun decklite-calendar--refresh-due-counts ()
  "Refresh cached due-counts for calendar display."
  (setq decklite-calendar--due-counts (decklite-calendar--get-due-cards-by-date)))

(defun decklite-calendar--mark-dates-with-due-cards ()
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
                     (let ((face (decklite-calendar--get-face-for-count count)))
                       (calendar-mark-visible-date date face)))))
               decklite-calendar--due-counts))))

;;;###autoload
(defun decklite-calendar-mark-due-dates ()
  "Mark dates with due cards on the calendar."
  (interactive)
  (decklite-calendar--refresh-due-counts)
  ;; First clear any existing marks
  (calendar-unmark)
  ;; Then mark dates with due cards
  (decklite-calendar--mark-dates-with-due-cards)
  (message "Marked dates with due cards"))

;;;###autoload
(defun decklite-calendar-show-due-count-at-date ()
  "Show the number of cards due on the selected date."
  (interactive)
  (let* ((date (calendar-cursor-to-date))
         (count (gethash date decklite-calendar--due-counts 0)))
    (if (> count 0)
        (message "%d card%s due on %s"
                 count
                 (if (= count 1) "" "s")
                 (calendar-date-string date)))))

;; Define a minor mode for the calendar integration
;;;###autoload
(define-minor-mode decklite-calendar-mode
  "Toggle DeckLite calendar integration.
When enabled, dates with due cards are highlighted in the calendar."
  :global t
  :lighter " DeckLiteCal"
  :group 'decklite-calendar
  (if decklite-calendar-mode
      (progn
        (add-hook 'calendar-mode-hook 'decklite-calendar--refresh-due-counts)
        (add-hook 'calendar-today-visible-hook 'decklite-calendar-mark-due-dates)
        (add-hook 'calendar-today-invisible-hook 'decklite-calendar-mark-due-dates)
        (add-hook 'calendar-move-hook 'decklite-calendar-show-due-count-at-date))
    (remove-hook 'calendar-mode-hook 'decklite-calendar--refresh-due-counts)
    (remove-hook 'calendar-today-visible-hook 'decklite-calendar-mark-due-dates)
    (remove-hook 'calendar-today-invisible-hook 'decklite-calendar-mark-due-dates)
    (remove-hook 'calendar-move-hook 'decklite-calendar-show-due-count-at-date)))

(provide 'decklite-calendar)
;;; decklite-calendar.el ends here

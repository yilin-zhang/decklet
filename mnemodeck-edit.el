;;; mnemodeck-edit.el --- Edit mode for MnemoDeck -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Tabulated-list based edit UI.

;;; Code:

(require 'ansi-color)
(require 'cl-lib)
(require 'seq)
(require 'tabulated-list)

(require 'mnemodeck-schedular)
(require 'mnemodeck-db)
(require 'mnemodeck-deck)

(defgroup mnemodeck-edit nil
  "Edit mode for MnemoDeck."
  :group 'mnemodeck)

;; Faces

(defface mnemodeck-edit-word-face
  `((t :foreground ,(face-attribute 'ansi-color-red :foreground)
       :weight bold))
  "Face for displaying the word in edit lists."
  :group 'mnemodeck-edit)

(defface mnemodeck-edit-word-archived-face
  `((t :foreground ,(face-attribute 'ansi-color-cyan :foreground)
       :weight bold))
  "Face for displaying archived words in edit lists."
  :group 'mnemodeck-edit)

(defface mnemodeck-edit-hint-face
  `((t :inherit shadow))
  "Face for displaying the hint in edit lists."
  :group 'mnemodeck-edit)

(defface mnemodeck-edit-added-face
  `((t :foreground ,(face-attribute 'ansi-color-bright-blue :foreground)))
  "Face for displaying added timestamps in edit lists."
  :group 'mnemodeck-edit)

(defface mnemodeck-edit-last-review-face
  `((t :foreground ,(face-attribute 'ansi-color-bright-cyan :foreground)))
  "Face for displaying last review timestamps in edit lists."
  :group 'mnemodeck-edit)

(defface mnemodeck-edit-due-face
  `((t :foreground ,(face-attribute 'ansi-color-bright-green :foreground)))
  "Face for displaying due timestamps in edit lists."
  :group 'mnemodeck-edit)

(defface mnemodeck-edit-state-face
  `((t :foreground ,(face-attribute 'ansi-color-magenta :foreground)))
  "Face for displaying state values in edit lists."
  :group 'mnemodeck-edit)

(defface mnemodeck-edit-stability-face
  `((t :foreground ,(face-attribute 'ansi-color-green :foreground)))
  "Face for displaying stability values in edit lists."
  :group 'mnemodeck-edit)

(defface mnemodeck-edit-difficulty-face
  `((t :foreground ,(face-attribute 'ansi-color-yellow :foreground)))
  "Face for displaying difficulty values in edit lists."
  :group 'mnemodeck-edit)

(defface mnemodeck-edit-mark-face
  '((((background dark)) (:background "DarkGoldenrod4"))
    (t (:background "LightYellow1")))
  "Face for marked rows in the edit table."
  :group 'mnemodeck-edit)

;; Hooks

(defcustom mnemodeck-edit-start-hook nil
  "Hook run when mnemodeck edit session starts."
  :type 'hook
  :group 'mnemodeck-edit)

(defcustom mnemodeck-edit-quit-hook nil
  "Hook run when mnemodeck edit session quits."
  :type 'hook
  :group 'mnemodeck-edit)

;; Internal

(defvar mnemodeck-edit-buffer-name "*MnemoDeck Edit*"
  "Name of the buffer used for card editing.")

(defvar mnemodeck-edit--marked (make-hash-table :test 'equal)
  "Hash table of marked words in the edit view.")

(defvar mnemodeck-edit--mark-overlays (make-hash-table :test 'equal)
  "Hash table of word -> overlay for marked rows.")

(defvar mnemodeck-edit--filter 'all
  "Current filter for the edit table.
One of: all, review, learning, archived.")

(defconst mnemodeck-edit--columns
  '("Word" "Hint" "Added" "Last Review" "Due" "State" "Stability" "Difficulty")
  "Column names for the edit table.")

(defconst mnemodeck-edit--numeric-columns
  '("Stability" "Difficulty")
  "Columns that should be sorted numerically.")

(defconst mnemodeck-edit--time-sort-columns
  '("Added" "Last Review" "Due")
  "Columns that default to descending order when sorting.")

(defconst mnemodeck-edit--column-indices
  (let ((index 0)
        (table nil))
    (dolist (name mnemodeck-edit--columns (nreverse table))
      (push (cons name index) table)
      (setq index (1+ index))))
  "Alist mapping edit table column names to indices.")

;; Edit table formatting and sorting

(defun mnemodeck--parse-iso-date (date-string)
  "Parse DATE-STRING as ISO 8601 date to internal time format."
  (when date-string
    (if (fboundp 'parse-iso8601-time-string)
        (parse-iso8601-time-string date-string)
      (encode-time (parse-time-string date-string)))))

(defun mnemodeck-edit--format-timestamp (timestamp)
  "Format TIMESTAMP for display in the edit table."
  (if (string-empty-p (or timestamp ""))
      ""
    (format-time-string "%Y-%m-%d %H:%M"
                        (mnemodeck--parse-iso-date timestamp))))

(defun mnemodeck-edit--entry-sort-string (entry column)
  "Return sortable string for ENTRY at COLUMN."
  (let* ((cell (aref (cadr entry) column))
         (value (or (get-text-property 0 'mnemodeck-sort-key cell)
                    (and (stringp cell) (substring-no-properties cell))
                    "")))
    (if (stringp value) value (format "%s" value))))

(defun mnemodeck-edit--entry-sort-number (entry column)
  "Return sortable number for ENTRY at COLUMN."
  (let* ((cell (aref (cadr entry) column))
         (value (or (get-text-property 0 'mnemodeck-sort-number cell)
                    (and (stringp cell) (substring-no-properties cell))
                    "")))
    (if (numberp value) value (string-to-number value))))

(defun mnemodeck-edit--restore-position (line win-line)
  "Restore edit-buffer position using LINE and WIN-LINE.
LINE is the 1-based buffer line number to move point to.
WIN-LINE is the point's screen-line offset from window start, used by
`recenter' to keep a stable on-screen position after refresh."
  (let ((max-line (line-number-at-pos (point-max))))
    (goto-char (point-min))
    (forward-line (1- (min line max-line))))
  (when (and win-line (numberp win-line))
    (recenter win-line)))

(defun mnemodeck-edit--nearest-surviving-word (deleted-words)
  "Return the nearest table word not listed in DELETED-WORDS.
If multiple words are equally near point, prefer a following line."
  (let* ((origin-line (line-number-at-pos))
         (best-word nil)
         (best-distance nil)
         (best-forward nil))
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (let ((word (tabulated-list-get-id)))
          (when (and word
                     (not (member word deleted-words)))
            (let* ((line (line-number-at-pos))
                   (delta (abs (- line origin-line)))
                   (forward (>= line origin-line)))
              (when (or (null best-distance)
                        (< delta best-distance)
                        (and (= delta best-distance)
                             (and forward (not best-forward))))
                (setq best-word word
                      best-distance delta
                      best-forward forward)))))
        (forward-line 1)))
    best-word))

(defun mnemodeck-edit--line-of-word (word)
  "Return line number of WORD in current edit table, or nil if not found."
  (when word
    (save-excursion
      (goto-char (point-min))
      (let (line)
        (while (and (not line) (< (point) (point-max)))
          (when (let ((row-word (tabulated-list-get-id)))
                  (and row-word (string-equal row-word word)))
            (setq line (line-number-at-pos)))
          (forward-line 1))
        line))))

(defmacro mnemodeck-edit--column-sorter (column)
  "Return a sorter lambda for COLUMN."
  `(lambda (a b)
     (let ((index (or (alist-get ,column mnemodeck-edit--column-indices nil nil #'string=)
                      (error "Unknown column: %s" ,column))))
       (if (member ,column mnemodeck-edit--numeric-columns)
           (< (mnemodeck-edit--entry-sort-number a index)
              (mnemodeck-edit--entry-sort-number b index))
         (string< (mnemodeck-edit--entry-sort-string a index)
                  (mnemodeck-edit--entry-sort-string b index))))))

(defmacro mnemodeck-edit--column-sort-command (column)
  "Return an interactive command to sort by COLUMN."
  `(lambda ()
     (interactive)
     ;; `tabulated-list-sort-key' is (COLUMN . DESC), where DESC is t/nil.
     (let* ((current (car tabulated-list-sort-key))
            ;; When sorting the same column, toggle direction.
            ;; Otherwise use the column's default direction.
            ;; Force DESC to be a strict boolean so sort key cdr is t/nil.
            (descending (if (equal current ,column)
                            (not (cdr tabulated-list-sort-key))
                          (not (null (member ,column mnemodeck-edit--time-sort-columns))))))
       ;; Update the global sort key and immediately redraw the table.
       (setq tabulated-list-sort-key
             (cons ,column
                   descending))
       (mnemodeck-edit-refresh)
       ;; Report the selected column and direction for quick feedback.
       (message "Sort: %s (%s)"
                ,column
                (if descending "descending" "ascending")))))

;; Lightweight ratings from the edit table

(defun mnemodeck-edit--ensure-not-current (words)
  "Signal an error if WORDS include the current review word.
WORDS can be a single word string or a list of words."
  (let ((current mnemodeck-current-word))
    (when (and current
               (if (listp words)
                   (seq-find (lambda (word)
                               (string-equal word current))
                             words)
                 (string-equal words current)))
      (user-error "Current review word \"%s\" can only be modified in review mode" current))))

(defun mnemodeck-edit-rate-card ()
  "Rate the card at point, regardless of its current state."
  (interactive)
  (let* ((word (or (tabulated-list-get-id)
                   (user-error "No card on this line")))
         (line (line-number-at-pos))
         (win-line (count-screen-lines (window-start) (point)))
         (grade-options '((1 . "Again") (2 . "Hard") (3 . "Good") (4 . "Easy")))
         (prompt (concat (format "Rate \"%s\" " word)
                         (mapconcat (lambda (g)
                                      (format "[%d] %s" (car g) (cdr g)))
                                    grade-options " ")
                         ": "))
         (grade (- (read-char-choice prompt '(?1 ?2 ?3 ?4)) ?0))
         (label (alist-get grade grade-options "" nil #'=)))
    (mnemodeck-edit--ensure-not-current word)
    (when (eq mnemodeck-edit--filter 'archived)
      (mnemodeck-unarchive-card word))
    (mnemodeck-rate-card word grade)
    (mnemodeck-edit-refresh)
    (mnemodeck-edit--restore-position line win-line)
    (message "Rated \"%s\" as %s" word label)))

;; Edit table mode and commands

(defun mnemodeck-edit--entries ()
  "Return tabulated list entries for the edit buffer."
  (mapcar
   (lambda (row)
     (pcase-let ((`(,word ,added ,last-review ,due ,state ,_step ,stability ,difficulty ,hint) row))
       (let* ((state (mnemodeck--normalize-fsrs-state state))
              (word-face (if (eq mnemodeck-edit--filter 'archived)
                             'mnemodeck-edit-word-archived-face
                           'mnemodeck-edit-word-face))
              (hint (if hint
                        (replace-regexp-in-string "[\r\n]+" " ↵ " hint nil 'literal)
                      ""))
              (added (or added ""))
              (last-review (or last-review ""))
              (due (or due "")))
         (list word
               (vector
                (propertize word 'face word-face)
                (propertize hint 'face 'mnemodeck-edit-hint-face)
                (propertize (mnemodeck-edit--format-timestamp added)
                            'face 'mnemodeck-edit-added-face
                            'mnemodeck-sort-key added)
                (propertize (mnemodeck-edit--format-timestamp last-review)
                            'face 'mnemodeck-edit-last-review-face
                            'mnemodeck-sort-key last-review)
                (propertize (mnemodeck-edit--format-timestamp due)
                            'face 'mnemodeck-edit-due-face
                            'mnemodeck-sort-key due)
                (propertize (or (mnemodeck--fsrs-state-string state) "")
                            'face 'mnemodeck-edit-state-face)
                (propertize (if stability (format "%.3f" stability) "")
                            'face 'mnemodeck-edit-stability-face
                            'mnemodeck-sort-number (or stability 0))
                (propertize (if difficulty (format "%.3f" difficulty) "")
                            'face 'mnemodeck-edit-difficulty-face
                            'mnemodeck-sort-number (or difficulty 0)))))))
   (mnemodeck-db--select-cards mnemodeck-edit--filter tabulated-list-sort-key)))

(defun mnemodeck-edit-refresh ()
  "Refresh the card list buffer."
  (interactive)
  (setq tabulated-list-entries (delq nil (mnemodeck-edit--entries)))
  (tabulated-list-print t)
  (mnemodeck-edit--apply-marks))

(defun mnemodeck-edit--apply-marks ()
  "Apply marked-row faces to the edit buffer."
  (mnemodeck-edit--clear-mark-overlays)
  (save-excursion
    (goto-char (point-min))
    (forward-line 1)
    (while (not (eobp))
      (let ((word (tabulated-list-get-id)))
        (when (and word (gethash word mnemodeck-edit--marked))
          (mnemodeck-edit--add-mark-overlay word)))
      (forward-line 1))))

(defun mnemodeck-edit--marked-words ()
  "Return a list of marked words."
  (let (words)
    (maphash (lambda (word _value) (push word words)) mnemodeck-edit--marked)
    (nreverse words)))

(defun mnemodeck-edit--clear-marks ()
  "Clear all mark in the edit view."
  (clrhash mnemodeck-edit--marked))

(defun mnemodeck-edit--clear-mark-overlays ()
  "Remove all mark overlays in the edit view."
  (maphash (lambda (_word ov)
             (when (overlayp ov)
               (delete-overlay ov)))
           mnemodeck-edit--mark-overlays)
  (clrhash mnemodeck-edit--mark-overlays))

(defun mnemodeck-edit--add-mark-overlay (word)
  "Add a mark overlay for WORD on the current line."
  (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
    (overlay-put ov 'face 'mnemodeck-edit-mark-face)
    (overlay-put ov 'mnemodeck-edit-mark t)
    (puthash word ov mnemodeck-edit--mark-overlays)))

(defun mnemodeck-edit-mark ()
  "Mark the card at point and move to the next line."
  (interactive)
  (let ((word (tabulated-list-get-id)))
    (unless word
      (user-error "No card on this line"))
    (puthash word t mnemodeck-edit--marked)
    (mnemodeck-edit--add-mark-overlay word)
    (forward-line 1)))

(defun mnemodeck-edit-unmark ()
  "Unmark the card at point and move to the next line."
  (interactive)
  (let ((word (tabulated-list-get-id)))
    (unless word
      (user-error "No card on this line"))
    (remhash word mnemodeck-edit--marked)
    (when-let ((ov (gethash word mnemodeck-edit--mark-overlays)))
      (delete-overlay ov)
      (remhash word mnemodeck-edit--mark-overlays))
    (forward-line 1)))

(defun mnemodeck-edit-unmark-all ()
  "Clear all mark in the edit view."
  (interactive)
  (mnemodeck-edit--clear-marks)
  (mnemodeck-edit--clear-mark-overlays)
  (message "Cleared all marks"))

(defun mnemodeck-edit-filter-review ()
  "Show only review cards in the edit table."
  (interactive)
  (setq mnemodeck-edit--filter 'review)
  (mnemodeck-edit-refresh)
  (message "Filter: review"))

(defun mnemodeck-edit-filter-learning ()
  "Show only learning cards in the edit table."
  (interactive)
  (setq mnemodeck-edit--filter 'learning)
  (mnemodeck-edit-refresh)
  (message "Filter: learning"))

(defun mnemodeck-edit-filter-toggle-archive ()
  "Toggle between archived cards and all cards in the edit table."
  (interactive)
  (setq mnemodeck-edit--filter
        (cond
         ((eq mnemodeck-edit--filter 'archived) 'all)
         ((eq mnemodeck-edit--filter 'all) 'archived)
         (t 'all)))
  (mnemodeck-edit-refresh)
  (message "Filter: %s" mnemodeck-edit--filter))

(defun mnemodeck-edit--edit-card-at-point (edit-word edit-hint)
  "Edit the card at point using EDIT-WORD and EDIT-HINT flags."
  (let ((word (tabulated-list-get-id))
        (line (line-number-at-pos))
        (win-line (count-screen-lines (window-start) (point))))
    (unless word
      (user-error "No card on this line"))
    (mnemodeck-edit--ensure-not-current word)
    (setq word (mnemodeck-prompt-edit-card-fields word edit-word edit-hint))
    (mnemodeck-edit-refresh)
    (mnemodeck-edit--restore-position line win-line)
    (message "Updated \"%s\"" word)))

(defun mnemodeck-edit-word ()
  "Edit the word at point."
  (interactive)
  (mnemodeck-edit--edit-card-at-point t nil))

(defun mnemodeck-edit-hint ()
  "Edit the hint at point."
  (interactive)
  (mnemodeck-edit--edit-card-at-point nil t))

(defun mnemodeck-edit-delete-card ()
  "Delete the card at point from the deck."
  (interactive)
  (let ((word (tabulated-list-get-id))
        (line (line-number-at-pos))
        (win-line (count-screen-lines (window-start) (point))))
    (unless word
      (user-error "No card on this line"))
    (mnemodeck-edit--ensure-not-current word)
    (when (yes-or-no-p (format "Delete \"%s\" from the deck? " word))
      (mnemodeck-delete-card word)
      (mnemodeck-edit-refresh)
      (mnemodeck-edit--restore-position line win-line)
      (message "Deleted \"%s\"" word))))

(defun mnemodeck-edit-delete ()
  "Delete marked cards, or the card at point."
  (interactive)
  (let ((marked (mnemodeck-edit--marked-words)))
    (if marked
        (let* ((win-line (count-screen-lines (window-start) (point)))
               (target-word (mnemodeck-edit--nearest-surviving-word marked)))
          (mnemodeck-edit--ensure-not-current marked)
          (when (yes-or-no-p (format "Delete %d marked cards? " (length marked)))
            (dolist (word marked)
              (mnemodeck-delete-card word))
            (mnemodeck-edit--clear-marks)
            (mnemodeck-edit-refresh)
            (when-let ((target-line (mnemodeck-edit--line-of-word target-word)))
              (mnemodeck-edit--restore-position target-line win-line))
            (message "Deleted %d cards" (length marked))))
      (mnemodeck-edit-delete-card))))

(defun mnemodeck-edit-archive-card ()
  "Archive the card at point."
  (interactive)
  (let ((word (tabulated-list-get-id))
        (line (line-number-at-pos))
        (win-line (count-screen-lines (window-start) (point))))
    (unless word
      (user-error "No card on this line"))
    (mnemodeck-edit--ensure-not-current word)
    (when (yes-or-no-p (format "Archive \"%s\" from review? " word))
      (mnemodeck-archive-card word)
      (mnemodeck-edit-refresh)
      (mnemodeck-edit--restore-position line win-line)
      (message "Archived \"%s\"" word))))

(defun mnemodeck-edit-unarchive-card ()
  "Unarchive the card at point."
  (interactive)
  (let ((word (tabulated-list-get-id))
        (line (line-number-at-pos))
        (win-line (count-screen-lines (window-start) (point))))
    (unless word
      (user-error "No card on this line"))
    (mnemodeck-edit--ensure-not-current word)
    (mnemodeck-unarchive-card word)
    (mnemodeck-edit-refresh)
    (mnemodeck-edit--restore-position line win-line)
    (message "Unarchived \"%s\"" word)))

(defun mnemodeck-edit-archive ()
  "Archive or unarchive marked cards, or the card at point."
  (interactive)
  (let ((marked (mnemodeck-edit--marked-words)))
    (if marked
        (let* ((unarchive-p (eq mnemodeck-edit--filter 'archived))
               (verb (if unarchive-p "Unarchive" "Archive"))
               (done-verb (if unarchive-p "Unarchived" "Archived"))
               (action (if unarchive-p #'mnemodeck-unarchive-card #'mnemodeck-archive-card))
               (win-line (count-screen-lines (window-start) (point)))
               (target-word (mnemodeck-edit--nearest-surviving-word marked)))
          (mnemodeck-edit--ensure-not-current marked)
          (when (yes-or-no-p (format "%s %d marked cards? " verb (length marked)))
            (dolist (word marked)
              (funcall action word))
            (mnemodeck-edit--clear-marks)
            (mnemodeck-edit-refresh)
            (when-let ((target-line (mnemodeck-edit--line-of-word target-word)))
              (mnemodeck-edit--restore-position target-line win-line))
            (message "%s %d cards" done-verb (length marked))))
      (if (eq mnemodeck-edit--filter 'archived)
          (mnemodeck-edit-unarchive-card)
        (mnemodeck-edit-archive-card)))))

;; Edit mode setup

;;;###autoload
(defun mnemodeck-edit ()
  "Open the card list for editing."
  (interactive)
  (run-hooks 'mnemodeck-edit-start-hook)
  (let ((buffer (get-buffer-create mnemodeck-edit-buffer-name)))
    (with-current-buffer buffer
      (mnemodeck-edit-mode)
      (mnemodeck-edit-refresh))
    (switch-to-buffer buffer)))

(defun mnemodeck-edit-quit ()
  "Quit the edit buffer."
  (interactive)
  (run-hooks 'mnemodeck-edit-quit-hook)
  (quit-window)
  (mnemodeck-db--disconnect-if-idle))

;; Backup
(add-hook 'mnemodeck-edit-start-hook #'mnemodeck-db-backup)
(add-hook 'mnemodeck-edit-quit-hook #'mnemodeck-db-backup)

(defvar mnemodeck-edit-mode-map
  (define-keymap
    :parent tabulated-list-mode-map
    "e" #'mnemodeck-edit-word
    "t" #'mnemodeck-edit-hint
    "D" #'mnemodeck-edit-delete
    "/ r" #'mnemodeck-edit-filter-review
    "/ l" #'mnemodeck-edit-filter-learning
    "/ a" #'mnemodeck-edit-filter-toggle-archive
    "; w" (mnemodeck-edit--column-sort-command "Word")
    "; a" (mnemodeck-edit--column-sort-command "Added")
    "; l" (mnemodeck-edit--column-sort-command "Last Review")
    "; d" (mnemodeck-edit--column-sort-command "Due")
    "; s" (mnemodeck-edit--column-sort-command "Stability")
    "; f" (mnemodeck-edit--column-sort-command "Difficulty")
    "R" #'mnemodeck-edit-rate-card
    "A" #'mnemodeck-edit-archive
    "m" #'mnemodeck-edit-mark
    "u" #'mnemodeck-edit-unmark
    "U" #'mnemodeck-edit-unmark-all
    "<remap> <tabulated-list-sort>" #'mnemodeck-edit-refresh
    "g" #'mnemodeck-edit-refresh
    "+" #'mnemodeck-add-card
    "q" #'mnemodeck-edit-quit)
  "Keymap for `mnemodeck-edit-mode'.")

(define-derived-mode mnemodeck-edit-mode tabulated-list-mode "MnemoDeck-Edit"
  "Major mode for listing and editing MnemoDeck cards."
  (setq tabulated-list-format
        (vector
         (list "Word" 24 (mnemodeck-edit--column-sorter "Word"))
         (list "Hint" 40 t)
         (list "Added" 20 (mnemodeck-edit--column-sorter "Added"))
         (list "Last Review" 20 (mnemodeck-edit--column-sorter "Last Review"))
         (list "Due" 20 (mnemodeck-edit--column-sorter "Due"))
         (list "State" 10 t)
         (list "Stability" 10 (mnemodeck-edit--column-sorter "Stability"))
         (list "Difficulty" 10 (mnemodeck-edit--column-sorter "Difficulty"))))
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(provide 'mnemodeck-edit)
;;; mnemodeck-edit.el ends here

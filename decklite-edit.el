;;; decklite-edit.el --- Edit mode for DeckLite -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Tabulated-list based edit UI.

;;; Code:

(require 'ansi-color)
(require 'cl-lib)
(require 'seq)
(require 'tabulated-list)

(require 'decklite-schedular)
(require 'decklite-db)
(require 'decklite-deck)

(defgroup decklite-edit nil
  "Edit mode for DeckLite."
  :group 'decklite)

;; Faces

(defface decklite-edit-word-face
  `((t :foreground ,(face-attribute 'ansi-color-red :foreground)
       :weight bold))
  "Face for displaying the word in edit lists."
  :group 'decklite-edit)

(defface decklite-edit-word-archived-face
  `((t :foreground ,(face-attribute 'ansi-color-cyan :foreground)
       :weight bold))
  "Face for displaying archived words in edit lists."
  :group 'decklite-edit)

(defface decklite-edit-hint-face
  `((t :inherit shadow))
  "Face for displaying the hint in edit lists."
  :group 'decklite-edit)

(defface decklite-edit-added-face
  `((t :foreground ,(face-attribute 'ansi-color-bright-blue :foreground)))
  "Face for displaying added timestamps in edit lists."
  :group 'decklite-edit)

(defface decklite-edit-last-review-face
  `((t :foreground ,(face-attribute 'ansi-color-bright-cyan :foreground)))
  "Face for displaying last review timestamps in edit lists."
  :group 'decklite-edit)

(defface decklite-edit-due-face
  `((t :foreground ,(face-attribute 'ansi-color-bright-green :foreground)))
  "Face for displaying due timestamps in edit lists."
  :group 'decklite-edit)

(defface decklite-edit-state-face
  `((t :foreground ,(face-attribute 'ansi-color-magenta :foreground)))
  "Face for displaying state values in edit lists."
  :group 'decklite-edit)

(defface decklite-edit-stability-face
  `((t :foreground ,(face-attribute 'ansi-color-green :foreground)))
  "Face for displaying stability values in edit lists."
  :group 'decklite-edit)

(defface decklite-edit-difficulty-face
  `((t :foreground ,(face-attribute 'ansi-color-yellow :foreground)))
  "Face for displaying difficulty values in edit lists."
  :group 'decklite-edit)

(defface decklite-edit-mark-face
  '((((background dark)) (:background "DarkGoldenrod4"))
    (t (:background "LightYellow1")))
  "Face for marked rows in the edit table."
  :group 'decklite-edit)

;; Hooks

(defcustom decklite-edit-start-hook nil
  "Hook run when decklite edit session starts."
  :type 'hook
  :group 'decklite-edit)

(defcustom decklite-edit-quit-hook nil
  "Hook run when decklite edit session quits."
  :type 'hook
  :group 'decklite-edit)

;; Internal

(defvar decklite-edit-buffer-name "*DeckLite Edit*"
  "Name of the buffer used for card editing.")

(defvar decklite-edit--marked (make-hash-table :test 'equal)
  "Hash table of marked words in the edit view.")

(defvar decklite-edit--mark-overlays (make-hash-table :test 'equal)
  "Hash table of word -> overlay for marked rows.")

(defvar decklite-edit--filter 'all
  "Current filter for the edit table.
One of: all, review, learning, archived.")

(defconst decklite-edit--columns
  '("Word" "Hint" "Added" "Last Review" "Due" "State" "Stability" "Difficulty")
  "Column names for the edit table.")

(defconst decklite-edit--numeric-columns
  '("Stability" "Difficulty")
  "Columns that should be sorted numerically.")

(defconst decklite-edit--time-sort-columns
  '("Added" "Last Review" "Due")
  "Columns that default to descending order when sorting.")

(defconst decklite-edit--column-indices
  (let ((index 0)
        (table nil))
    (dolist (name decklite-edit--columns (nreverse table))
      (push (cons name index) table)
      (setq index (1+ index))))
  "Alist mapping edit table column names to indices.")

;; Edit table formatting and sorting

(defun decklite--parse-iso-date (date-string)
  "Parse DATE-STRING as ISO 8601 date to internal time format."
  (when date-string
    (if (fboundp 'parse-iso8601-time-string)
        (parse-iso8601-time-string date-string)
      (encode-time (parse-time-string date-string)))))

(defun decklite-edit--format-timestamp (timestamp)
  "Format TIMESTAMP for display in the edit table."
  (if (string-empty-p (or timestamp ""))
      ""
    (format-time-string "%Y-%m-%d %H:%M"
                        (decklite--parse-iso-date timestamp))))

(defun decklite-edit--entry-sort-string (entry column)
  "Return sortable string for ENTRY at COLUMN."
  (let* ((cell (aref (cadr entry) column))
         (value (or (get-text-property 0 'decklite-sort-key cell)
                    (and (stringp cell) (substring-no-properties cell))
                    "")))
    (if (stringp value) value (format "%s" value))))

(defun decklite-edit--entry-sort-number (entry column)
  "Return sortable number for ENTRY at COLUMN."
  (let* ((cell (aref (cadr entry) column))
         (value (or (get-text-property 0 'decklite-sort-number cell)
                    (and (stringp cell) (substring-no-properties cell))
                    "")))
    (if (numberp value) value (string-to-number value))))

(defun decklite-edit--restore-position (line win-line)
  "Restore edit-buffer position using LINE and WIN-LINE.
LINE is the 1-based buffer line number to move point to.
WIN-LINE is the point's screen-line offset from window start, used by
`recenter' to keep a stable on-screen position after refresh."
  (let ((max-line (line-number-at-pos (point-max))))
    (goto-char (point-min))
    (forward-line (1- (min line max-line))))
  (when (and win-line (numberp win-line))
    (recenter win-line)))

(defun decklite-edit--nearest-surviving-word (deleted-words)
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

(defun decklite-edit--line-of-word (word)
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

(defmacro decklite-edit--column-sorter (column)
  "Return a sorter lambda for COLUMN."
  `(lambda (a b)
     (let ((index (or (alist-get ,column decklite-edit--column-indices nil nil #'string=)
                      (error "Unknown column: %s" ,column))))
       (if (member ,column decklite-edit--numeric-columns)
           (< (decklite-edit--entry-sort-number a index)
              (decklite-edit--entry-sort-number b index))
         (string< (decklite-edit--entry-sort-string a index)
                  (decklite-edit--entry-sort-string b index))))))

(defmacro decklite-edit--column-sort-command (column)
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
                          (not (null (member ,column decklite-edit--time-sort-columns))))))
       ;; Update the global sort key and immediately redraw the table.
       (setq tabulated-list-sort-key
             (cons ,column
                   descending))
       (decklite-edit-refresh)
       ;; Report the selected column and direction for quick feedback.
       (message "Sort: %s (%s)"
                ,column
                (if descending "descending" "ascending")))))

;; Lightweight ratings from the edit table

(defun decklite-edit--ensure-not-current (words)
  "Signal an error if WORDS include the current review word.
WORDS can be a single word string or a list of words."
  (let ((current decklite-current-word))
    (when (and current
               (if (listp words)
                   (seq-find (lambda (word)
                               (string-equal word current))
                             words)
                 (string-equal words current)))
      (user-error "Current review word \"%s\" can only be modified in review mode" current))))

(defun decklite-edit-rate-card ()
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
    (decklite-edit--ensure-not-current word)
    (when (eq decklite-edit--filter 'archived)
      (decklite-unarchive-card word))
    (decklite-rate-card word grade)
    (decklite-edit-refresh)
    (decklite-edit--restore-position line win-line)
    (message "Rated \"%s\" as %s" word label)))

;; Edit table mode and commands

(defun decklite-edit--entries ()
  "Return tabulated list entries for the edit buffer."
  (mapcar
   (lambda (row)
     (pcase-let ((`(,word ,added ,last-review ,due ,state ,_step ,stability ,difficulty ,hint) row))
       (let* ((state (decklite--normalize-fsrs-state state))
              (word-face (if (eq decklite-edit--filter 'archived)
                             'decklite-edit-word-archived-face
                           'decklite-edit-word-face))
              (hint (if hint
                        (replace-regexp-in-string "[\r\n]+" "↵" hint nil 'literal)
                      ""))
              (added (or added ""))
              (last-review (or last-review ""))
              (due (or due "")))
         (list word
               (vector
                (propertize word 'face word-face)
                (propertize hint 'face 'decklite-edit-hint-face)
                (propertize (decklite-edit--format-timestamp added)
                            'face 'decklite-edit-added-face
                            'decklite-sort-key added)
                (propertize (decklite-edit--format-timestamp last-review)
                            'face 'decklite-edit-last-review-face
                            'decklite-sort-key last-review)
                (propertize (decklite-edit--format-timestamp due)
                            'face 'decklite-edit-due-face
                            'decklite-sort-key due)
                (propertize (or (decklite--fsrs-state-string state) "")
                            'face 'decklite-edit-state-face)
                (propertize (if stability (format "%.3f" stability) "")
                            'face 'decklite-edit-stability-face
                            'decklite-sort-number (or stability 0))
                (propertize (if difficulty (format "%.3f" difficulty) "")
                            'face 'decklite-edit-difficulty-face
                            'decklite-sort-number (or difficulty 0)))))))
   (decklite-db--select-cards decklite-edit--filter tabulated-list-sort-key)))

(defun decklite-edit-refresh ()
  "Refresh the card list buffer."
  (interactive)
  (setq tabulated-list-entries (delq nil (decklite-edit--entries)))
  (tabulated-list-print t)
  (decklite-edit--apply-marks))

(defun decklite-edit--apply-marks ()
  "Apply marked-row faces to the edit buffer."
  (decklite-edit--clear-mark-overlays)
  (save-excursion
    (goto-char (point-min))
    (forward-line 1)
    (while (not (eobp))
      (let ((word (tabulated-list-get-id)))
        (when (and word (gethash word decklite-edit--marked))
          (decklite-edit--add-mark-overlay word)))
      (forward-line 1))))

(defun decklite-edit--marked-words ()
  "Return a list of marked words."
  (let (words)
    (maphash (lambda (word _value) (push word words)) decklite-edit--marked)
    (nreverse words)))

(defun decklite-edit--clear-marks ()
  "Clear all mark in the edit view."
  (clrhash decklite-edit--marked))

(defun decklite-edit--clear-mark-overlays ()
  "Remove all mark overlays in the edit view."
  (maphash (lambda (_word ov)
             (when (overlayp ov)
               (delete-overlay ov)))
           decklite-edit--mark-overlays)
  (clrhash decklite-edit--mark-overlays))

(defun decklite-edit--add-mark-overlay (word)
  "Add a mark overlay for WORD on the current line."
  (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
    (overlay-put ov 'face 'decklite-edit-mark-face)
    (overlay-put ov 'decklite-edit-mark t)
    (puthash word ov decklite-edit--mark-overlays)))

(defun decklite-edit-mark ()
  "Mark the card at point and move to the next line."
  (interactive)
  (let ((word (tabulated-list-get-id)))
    (unless word
      (user-error "No card on this line"))
    (puthash word t decklite-edit--marked)
    (decklite-edit--add-mark-overlay word)
    (forward-line 1)))

(defun decklite-edit-unmark ()
  "Unmark the card at point and move to the next line."
  (interactive)
  (let ((word (tabulated-list-get-id)))
    (unless word
      (user-error "No card on this line"))
    (remhash word decklite-edit--marked)
    (when-let ((ov (gethash word decklite-edit--mark-overlays)))
      (delete-overlay ov)
      (remhash word decklite-edit--mark-overlays))
    (forward-line 1)))

(defun decklite-edit-unmark-all ()
  "Clear all mark in the edit view."
  (interactive)
  (decklite-edit--clear-marks)
  (decklite-edit--clear-mark-overlays)
  (message "Cleared all marks"))

(defun decklite-edit-filter-review ()
  "Show only review cards in the edit table."
  (interactive)
  (setq decklite-edit--filter 'review)
  (decklite-edit-refresh)
  (message "Filter: review"))

(defun decklite-edit-filter-learning ()
  "Show only learning cards in the edit table."
  (interactive)
  (setq decklite-edit--filter 'learning)
  (decklite-edit-refresh)
  (message "Filter: learning"))

(defun decklite-edit-filter-toggle-archive ()
  "Toggle between archived cards and all cards in the edit table."
  (interactive)
  (setq decklite-edit--filter
        (cond
         ((eq decklite-edit--filter 'archived) 'all)
         ((eq decklite-edit--filter 'all) 'archived)
         (t 'all)))
  (decklite-edit-refresh)
  (message "Filter: %s" decklite-edit--filter))

(defun decklite-edit--edit-card-at-point (edit-word edit-hint)
  "Edit the card at point using EDIT-WORD and EDIT-HINT flags."
  (let ((word (tabulated-list-get-id))
        (line (line-number-at-pos))
        (win-line (count-screen-lines (window-start) (point))))
    (unless word
      (user-error "No card on this line"))
    (decklite-edit--ensure-not-current word)
    (setq word (decklite-prompt-edit-card-fields word edit-word edit-hint))
    (decklite-edit-refresh)
    (decklite-edit--restore-position line win-line)
    (message "Updated \"%s\"" word)))

(defun decklite-edit-word ()
  "Edit the word at point."
  (interactive)
  (decklite-edit--edit-card-at-point t nil))

(defun decklite-edit-hint ()
  "Edit the hint at point."
  (interactive)
  (decklite-edit--edit-card-at-point nil t))

(defun decklite-edit-delete-card ()
  "Delete the card at point from the deck."
  (interactive)
  (let ((word (tabulated-list-get-id))
        (line (line-number-at-pos))
        (win-line (count-screen-lines (window-start) (point))))
    (unless word
      (user-error "No card on this line"))
    (decklite-edit--ensure-not-current word)
    (when (yes-or-no-p (format "Delete \"%s\" from the deck? " word))
      (decklite-delete-card word)
      (decklite-edit-refresh)
      (decklite-edit--restore-position line win-line)
      (message "Deleted \"%s\"" word))))

(defun decklite-edit-delete ()
  "Delete marked cards, or the card at point."
  (interactive)
  (let ((marked (decklite-edit--marked-words)))
    (if marked
        (let* ((win-line (count-screen-lines (window-start) (point)))
               (target-word (decklite-edit--nearest-surviving-word marked)))
          (decklite-edit--ensure-not-current marked)
          (when (yes-or-no-p (format "Delete %d marked cards? " (length marked)))
            (dolist (word marked)
              (decklite-delete-card word))
            (decklite-edit--clear-marks)
            (decklite-edit-refresh)
            (when-let ((target-line (decklite-edit--line-of-word target-word)))
              (decklite-edit--restore-position target-line win-line))
            (message "Deleted %d cards" (length marked))))
      (decklite-edit-delete-card))))

(defun decklite-edit-archive-card ()
  "Archive the card at point."
  (interactive)
  (let ((word (tabulated-list-get-id))
        (line (line-number-at-pos))
        (win-line (count-screen-lines (window-start) (point))))
    (unless word
      (user-error "No card on this line"))
    (decklite-edit--ensure-not-current word)
    (when (yes-or-no-p (format "Archive \"%s\" from review? " word))
      (decklite-archive-card word)
      (decklite-edit-refresh)
      (decklite-edit--restore-position line win-line)
      (message "Archived \"%s\"" word))))

(defun decklite-edit-unarchive-card ()
  "Unarchive the card at point."
  (interactive)
  (let ((word (tabulated-list-get-id))
        (line (line-number-at-pos))
        (win-line (count-screen-lines (window-start) (point))))
    (unless word
      (user-error "No card on this line"))
    (decklite-edit--ensure-not-current word)
    (decklite-unarchive-card word)
    (decklite-edit-refresh)
    (decklite-edit--restore-position line win-line)
    (message "Unarchived \"%s\"" word)))

(defun decklite-edit-archive ()
  "Archive or unarchive marked cards, or the card at point."
  (interactive)
  (let ((marked (decklite-edit--marked-words)))
    (if marked
        (let* ((unarchive-p (eq decklite-edit--filter 'archived))
               (verb (if unarchive-p "Unarchive" "Archive"))
               (done-verb (if unarchive-p "Unarchived" "Archived"))
               (action (if unarchive-p #'decklite-unarchive-card #'decklite-archive-card))
               (win-line (count-screen-lines (window-start) (point)))
               (target-word (decklite-edit--nearest-surviving-word marked)))
          (decklite-edit--ensure-not-current marked)
          (when (yes-or-no-p (format "%s %d marked cards? " verb (length marked)))
            (dolist (word marked)
              (funcall action word))
            (decklite-edit--clear-marks)
            (decklite-edit-refresh)
            (when-let ((target-line (decklite-edit--line-of-word target-word)))
              (decklite-edit--restore-position target-line win-line))
            (message "%s %d cards" done-verb (length marked))))
      (if (eq decklite-edit--filter 'archived)
          (decklite-edit-unarchive-card)
        (decklite-edit-archive-card)))))

;; Edit mode setup

;;;###autoload
(defun decklite-edit ()
  "Open the card list for editing."
  (interactive)
  (run-hooks 'decklite-edit-start-hook)
  (let ((buffer (get-buffer-create decklite-edit-buffer-name)))
    (with-current-buffer buffer
      (decklite-edit-mode)
      (decklite-edit-refresh))
    (switch-to-buffer buffer)))

(defun decklite-edit-quit ()
  "Quit the edit buffer."
  (interactive)
  (run-hooks 'decklite-edit-quit-hook)
  (quit-window)
  (decklite-db--disconnect-if-idle))

;; Backup
(add-hook 'decklite-edit-start-hook #'decklite-db-backup)
(add-hook 'decklite-edit-quit-hook #'decklite-db-backup)

(defvar decklite-edit-mode-map
  (define-keymap
    :parent tabulated-list-mode-map
    "e" #'decklite-edit-word
    "t" #'decklite-edit-hint
    "D" #'decklite-edit-delete
    "/ r" #'decklite-edit-filter-review
    "/ l" #'decklite-edit-filter-learning
    "/ a" #'decklite-edit-filter-toggle-archive
    "; w" (decklite-edit--column-sort-command "Word")
    "; a" (decklite-edit--column-sort-command "Added")
    "; l" (decklite-edit--column-sort-command "Last Review")
    "; d" (decklite-edit--column-sort-command "Due")
    "; s" (decklite-edit--column-sort-command "Stability")
    "; f" (decklite-edit--column-sort-command "Difficulty")
    "R" #'decklite-edit-rate-card
    "A" #'decklite-edit-archive
    "m" #'decklite-edit-mark
    "u" #'decklite-edit-unmark
    "U" #'decklite-edit-unmark-all
    "<remap> <tabulated-list-sort>" #'decklite-edit-refresh
    "g" #'decklite-edit-refresh
    "+" #'decklite-add-card
    "q" #'decklite-edit-quit)
  "Keymap for `decklite-edit-mode'.")

(define-derived-mode decklite-edit-mode tabulated-list-mode "DeckLite-Edit"
  "Major mode for listing and editing DeckLite cards."
  (setq tabulated-list-format
        (vector
         (list "Word" 24 (decklite-edit--column-sorter "Word"))
         (list "Hint" 40 t)
         (list "Added" 20 (decklite-edit--column-sorter "Added"))
         (list "Last Review" 20 (decklite-edit--column-sorter "Last Review"))
         (list "Due" 20 (decklite-edit--column-sorter "Due"))
         (list "State" 10 t)
         (list "Stability" 10 (decklite-edit--column-sorter "Stability"))
         (list "Difficulty" 10 (decklite-edit--column-sorter "Difficulty"))))
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(provide 'decklite-edit)
;;; decklite-edit.el ends here

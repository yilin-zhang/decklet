;;; decklet-edit.el --- Edit mode for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Tabulated-list based edit UI.

;;; Code:

(require 'ansi-color)
(require 'cl-lib)
(require 'seq)
(require 'tabulated-list)

(require 'decklet-core)
(require 'decklet-schedular)
(require 'decklet-db)
(require 'decklet-deck)

(defgroup decklet-edit nil
  "Edit mode for Decklet."
  :group 'decklet)

;; Faces

(defface decklet-edit-word-face
  '((t :inherit decklet-word-face))
  "Face for displaying the word in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-word-archived-face
  `((t :foreground ,(face-attribute 'ansi-color-cyan :foreground)
       :weight bold))
  "Face for displaying archived words in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-hint-face
  `((t :inherit shadow))
  "Face for displaying the hint in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-added-face
  `((t :foreground ,(face-attribute 'ansi-color-bright-blue :foreground)))
  "Face for displaying added timestamps in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-last-review-face
  `((t :foreground ,(face-attribute 'ansi-color-bright-cyan :foreground)))
  "Face for displaying last review timestamps in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-due-face
  `((t :foreground ,(face-attribute 'ansi-color-bright-green :foreground)))
  "Face for displaying due timestamps in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-state-face
  `((t :foreground ,(face-attribute 'ansi-color-magenta :foreground)))
  "Face for displaying state values in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-stability-face
  `((t :foreground ,(face-attribute 'ansi-color-green :foreground)))
  "Face for displaying stability values in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-difficulty-face
  `((t :foreground ,(face-attribute 'ansi-color-yellow :foreground)))
  "Face for displaying difficulty values in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-mark-face
  '((((background dark)) (:background "DarkGoldenrod4"))
    (t (:background "LightYellow1")))
  "Face for marked rows in the edit table."
  :group 'decklet-edit)

;; Hooks

(defcustom decklet-edit-start-hook nil
  "Hook run when decklet edit session starts."
  :type 'hook
  :group 'decklet-edit)

(defcustom decklet-edit-quit-hook nil
  "Hook run when decklet edit session quits."
  :type 'hook
  :group 'decklet-edit)

;; Internal

(defvar decklet-edit-buffer-name "*Decklet Edit*"
  "Name of the buffer used for card editing.")

(defvar decklet-edit--marked (make-hash-table :test 'equal)
  "Hash table of marked words in the edit view.")

(defvar decklet-edit--mark-overlays (make-hash-table :test 'equal)
  "Hash table of word -> overlay for marked rows.")

(defvar decklet-edit--filter 'all
  "Current filter for the edit table.
One of: all, review, learning, archived.")

(defconst decklet-edit--columns
  '("Word" "Hint" "Added" "Last Review" "Due" "State" "Stability" "Difficulty")
  "Column names for the edit table.")

(defconst decklet-edit--numeric-columns
  '("Stability" "Difficulty")
  "Columns that should be sorted numerically.")

(defconst decklet-edit--time-sort-columns
  '("Added" "Last Review" "Due")
  "Columns that default to descending order when sorting.")

(defconst decklet-edit--column-indices
  (let ((index 0)
        (table nil))
    (dolist (name decklet-edit--columns (nreverse table))
      (push (cons name index) table)
      (setq index (1+ index))))
  "Alist mapping edit table column names to indices.")

;; Edit table formatting and sorting

(defun decklet-edit--clean-up ()
  "Clear edit session state."
  (setq decklet-edit--marked (make-hash-table :test 'equal))
  (setq decklet-edit--mark-overlays (make-hash-table :test 'equal))
  (setq decklet-edit--filter 'all))

(defun decklet--parse-iso-date (date-string)
  "Parse DATE-STRING as ISO 8601 date to internal time format."
  (when date-string
    (if (fboundp 'parse-iso8601-time-string)
        (parse-iso8601-time-string date-string)
      (encode-time (parse-time-string date-string)))))

(defun decklet-edit--format-timestamp (timestamp)
  "Format TIMESTAMP for display in the edit table."
  (if (string-empty-p (or timestamp ""))
      ""
    (format-time-string "%Y-%m-%d %H:%M"
                        (decklet--parse-iso-date timestamp))))

(defun decklet-edit--entry-sort-string (entry column)
  "Return sortable string for ENTRY at COLUMN."
  (let* ((cell (aref (cadr entry) column))
         (value (or (get-text-property 0 'decklet-sort-key cell)
                    (and (stringp cell) (substring-no-properties cell))
                    "")))
    (if (stringp value) value (format "%s" value))))

(defun decklet-edit--entry-sort-number (entry column)
  "Return sortable number for ENTRY at COLUMN."
  (let* ((cell (aref (cadr entry) column))
         (value (or (get-text-property 0 'decklet-sort-number cell)
                    (and (stringp cell) (substring-no-properties cell))
                    "")))
    (if (numberp value) value (string-to-number value))))

(defun decklet-edit--restore-position (line win-line)
  "Restore edit-buffer position using LINE and WIN-LINE.
LINE is the 1-based buffer line number to move point to.
WIN-LINE is the point's screen-line offset from window start, used by
`recenter' to keep a stable on-screen position after refresh."
  (let ((max-line (line-number-at-pos (point-max))))
    (goto-char (point-min))
    (forward-line (1- (min line max-line))))
  (when (and win-line (numberp win-line))
    (recenter win-line)))

(defun decklet-edit--nearest-surviving-word (deleted-words)
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

(defun decklet-edit--line-of-word (word)
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

(defmacro decklet-edit--column-sorter (column)
  "Return a sorter lambda for COLUMN."
  `(lambda (a b)
     (let ((index (alist-get ,column decklet-edit--column-indices nil nil #'string=)))
       (if (member ,column decklet-edit--numeric-columns)
           (< (decklet-edit--entry-sort-number a index)
              (decklet-edit--entry-sort-number b index))
         (string< (decklet-edit--entry-sort-string a index)
                  (decklet-edit--entry-sort-string b index))))))

(defmacro decklet-edit--column-sort-command (column)
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
                          (not (null (member ,column decklet-edit--time-sort-columns))))))
       ;; Update the global sort key and immediately redraw the table.
       (setq tabulated-list-sort-key
             (cons ,column
                   descending))
       (decklet-edit-refresh)
       ;; Report the selected column and direction for quick feedback.
       (message "Sort: %s (%s)"
                ,column
                (if descending "descending" "ascending")))))

;; Lightweight ratings from the edit table

(defun decklet-edit--ensure-not-current (words)
  "Signal an error if WORDS include the current review word.
WORDS can be a single word string or a list of words."
  (let ((current decklet-current-word))
    (when (and current
               (if (listp words)
                   (seq-find (lambda (word)
                               (string-equal word current))
                             words)
                 (string-equal words current)))
      (user-error "Current review word \"%s\" can only be modified in review mode" current))))

(defun decklet-edit-rate-card ()
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
    (decklet-edit--ensure-not-current word)
    (when (eq decklet-edit--filter 'archived)
      (decklet-unarchive-card word))
    (decklet-rate-card word grade)
    (decklet-edit-refresh)
    (decklet-edit--restore-position line win-line)
    (message "Rated \"%s\" as %s" word label)))

;; Edit table mode and commands

(defun decklet-edit--entries ()
  "Return tabulated list entries for the edit buffer."
  (mapcar
   (lambda (row)
      (pcase-let ((`(,word ,added ,last-review ,due ,state ,_step ,stability ,difficulty ,hint) row))
        (let* ((state (decklet--normalize-fsrs-state state))
               (word-face (if (eq decklet-edit--filter 'archived)
                              'decklet-edit-word-archived-face
                            'decklet-edit-word-face))
               (state-face (cond
                            ((string-empty-p (or last-review "")) 'decklet-state-new-face)
                            ((memq state '(:learning :relearning)) 'decklet-state-learning-face)
                            ((eq state :review) 'decklet-state-review-face)
                            (t 'decklet-edit-state-face)))
               (hint (if hint
                         (replace-regexp-in-string "[\r\n]+" "↵" hint nil 'literal)
                       ""))
               (added (or added ""))
               (last-review (or last-review ""))
              (due (or due "")))
         (list word
               (vector
                (propertize word 'face word-face)
                (propertize hint 'face 'decklet-edit-hint-face)
                (propertize (decklet-edit--format-timestamp added)
                            'face 'decklet-edit-added-face
                            'decklet-sort-key added)
                (propertize (decklet-edit--format-timestamp last-review)
                            'face 'decklet-edit-last-review-face
                            'decklet-sort-key last-review)
                (propertize (decklet-edit--format-timestamp due)
                            'face 'decklet-edit-due-face
                            'decklet-sort-key due)
                (propertize (or (decklet--fsrs-state-string state) "")
                            'face state-face)
                (propertize (if stability (format "%.3f" stability) "")
                            'face 'decklet-edit-stability-face
                            'decklet-sort-number (or stability 0))
                (propertize (if difficulty (format "%.3f" difficulty) "")
                            'face 'decklet-edit-difficulty-face
                            'decklet-sort-number (or difficulty 0)))))))
   (decklet-db--select-cards decklet-edit--filter tabulated-list-sort-key)))

(defun decklet-edit-refresh ()
  "Refresh the card list buffer."
  (interactive)
  (setq tabulated-list-entries (delq nil (decklet-edit--entries)))
  (tabulated-list-print t)
  (decklet-edit--apply-marks))

(defun decklet-edit--apply-marks ()
  "Apply marked-row faces to the edit buffer."
  (decklet-edit--clear-mark-overlays)
  (save-excursion
    (goto-char (point-min))
    (forward-line 1)
    (while (not (eobp))
      (let ((word (tabulated-list-get-id)))
        (when (and word (gethash word decklet-edit--marked))
          (decklet-edit--add-mark-overlay word)))
      (forward-line 1))))

(defun decklet-edit--marked-words ()
  "Return a list of marked words."
  (let (words)
    (maphash (lambda (word _value) (push word words)) decklet-edit--marked)
    (nreverse words)))

(defun decklet-edit--clear-marks ()
  "Clear all mark in the edit view."
  (clrhash decklet-edit--marked))

(defun decklet-edit--clear-mark-overlays ()
  "Remove all mark overlays in the edit view."
  (maphash (lambda (_word ov)
             (when (overlayp ov)
               (delete-overlay ov)))
           decklet-edit--mark-overlays)
  (clrhash decklet-edit--mark-overlays))

(defun decklet-edit--add-mark-overlay (word)
  "Add a mark overlay for WORD on the current line."
  (when-let ((existing (gethash word decklet-edit--mark-overlays)))
    (when (overlayp existing)
      (delete-overlay existing)))
  (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
    (overlay-put ov 'face 'decklet-edit-mark-face)
    (overlay-put ov 'decklet-edit-mark t)
    (puthash word ov decklet-edit--mark-overlays)))

(defun decklet-edit--mark-region (beg end)
  "Mark all cards between BEG and END lines in the current edit table."
  (let* ((start (min beg end))
         (finish (max beg end))
         ;; If region end is exactly at BOL of the next line, exclude it.
         (finish (if (and (> finish start)
                          (save-excursion
                            (goto-char finish)
                            (bolp)))
                     (1- finish)
                   finish)))
    (save-excursion
      (goto-char start)
      (beginning-of-line)
      (while (<= (line-beginning-position) finish)
        (when-let ((word (tabulated-list-get-id)))
          (puthash word t decklet-edit--marked)
          (decklet-edit--add-mark-overlay word))
        (forward-line 1)))))

(defun decklet-edit-mark ()
  "Mark card(s) at point.
If a region is active, mark all selected rows and move to the line after the
selection.  Otherwise, mark the card at point and move to the next line."
  (interactive)
  (if (use-region-p)
      (let ((beg (region-beginning))
            (end (region-end)))
        (decklet-edit--mark-region beg end)
        (deactivate-mark)
        (goto-char (max beg end))
        (beginning-of-line)
        (forward-line 1))
    (let ((word (tabulated-list-get-id)))
      (unless word
        (user-error "No card on this line"))
      (puthash word t decklet-edit--marked)
      (decklet-edit--add-mark-overlay word)
      (forward-line 1))))

(defun decklet-edit-unmark ()
  "Unmark the card at point and move to the next line."
  (interactive)
  (let ((word (tabulated-list-get-id)))
    (unless word
      (user-error "No card on this line"))
    (remhash word decklet-edit--marked)
    (when-let ((ov (gethash word decklet-edit--mark-overlays)))
      (delete-overlay ov)
      (remhash word decklet-edit--mark-overlays))
    (forward-line 1)))

(defun decklet-edit-unmark-all ()
  "Clear all mark in the edit view."
  (interactive)
  (decklet-edit--clear-marks)
  (decklet-edit--clear-mark-overlays)
  (message "Cleared all marks"))

(defun decklet-edit-filter-review ()
  "Show only review cards in the edit table."
  (interactive)
  (setq decklet-edit--filter 'review)
  (decklet-edit-refresh)
  (message "Filter: review"))

(defun decklet-edit-filter-learning ()
  "Show only learning cards in the edit table."
  (interactive)
  (setq decklet-edit--filter 'learning)
  (decklet-edit-refresh)
  (message "Filter: learning"))

(defun decklet-edit-filter-toggle-archive ()
  "Toggle between archived cards and all cards in the edit table."
  (interactive)
  (setq decklet-edit--filter
        (cond
         ((eq decklet-edit--filter 'archived) 'all)
         ((eq decklet-edit--filter 'all) 'archived)
         (t 'all)))
  (decklet-edit-refresh)
  (message "Filter: %s" decklet-edit--filter))

(defun decklet-edit--edit-card-at-point (edit-word edit-hint)
  "Edit the card at point using EDIT-WORD and EDIT-HINT flags."
  (let ((word (tabulated-list-get-id))
        (line (line-number-at-pos))
        (win-line (count-screen-lines (window-start) (point))))
    (unless word
      (user-error "No card on this line"))
    (decklet-edit--ensure-not-current word)
    (setq word (decklet-prompt-edit-card-fields word edit-word edit-hint))
    (decklet-edit-refresh)
    (decklet-edit--restore-position line win-line)
    (message "Updated \"%s\"" word)))

(defun decklet-edit-word ()
  "Edit the word at point."
  (interactive)
  (decklet-edit--edit-card-at-point t nil))

(defun decklet-edit-hint ()
  "Edit the hint at point."
  (interactive)
  (decklet-edit--edit-card-at-point nil t))

(defun decklet-edit-delete-card ()
  "Delete the card at point from the deck."
  (interactive)
  (let ((word (tabulated-list-get-id))
        (line (line-number-at-pos))
        (win-line (count-screen-lines (window-start) (point))))
    (unless word
      (user-error "No card on this line"))
    (decklet-edit--ensure-not-current word)
    (when (yes-or-no-p (format "Delete \"%s\" from the deck? " word))
      (decklet-delete-card word)
      (decklet-edit-refresh)
      (decklet-edit--restore-position line win-line)
      (message "Deleted \"%s\"" word))))

(defun decklet-edit-delete ()
  "Delete marked cards, or the card at point."
  (interactive)
  (let ((marked (decklet-edit--marked-words)))
    (if marked
        (let* ((win-line (count-screen-lines (window-start) (point)))
               (target-word (decklet-edit--nearest-surviving-word marked)))
          (decklet-edit--ensure-not-current marked)
          (when (yes-or-no-p (format "Delete %d marked cards? " (length marked)))
            (dolist (word marked)
              (decklet-delete-card word))
            (decklet-edit--clear-marks)
            (decklet-edit-refresh)
            (when-let ((target-line (decklet-edit--line-of-word target-word)))
              (decklet-edit--restore-position target-line win-line))
            (message "Deleted %d cards" (length marked))))
      (decklet-edit-delete-card))))

(defun decklet-edit-archive-card ()
  "Archive the card at point."
  (interactive)
  (let ((word (tabulated-list-get-id))
        (line (line-number-at-pos))
        (win-line (count-screen-lines (window-start) (point))))
    (unless word
      (user-error "No card on this line"))
    (decklet-edit--ensure-not-current word)
    (when (yes-or-no-p (format "Archive \"%s\" from review? " word))
      (decklet-archive-card word)
      (decklet-edit-refresh)
      (decklet-edit--restore-position line win-line)
      (message "Archived \"%s\"" word))))

(defun decklet-edit-unarchive-card ()
  "Unarchive the card at point."
  (interactive)
  (let ((word (tabulated-list-get-id))
        (line (line-number-at-pos))
        (win-line (count-screen-lines (window-start) (point))))
    (unless word
      (user-error "No card on this line"))
    (decklet-edit--ensure-not-current word)
    (decklet-unarchive-card word)
    (decklet-edit-refresh)
    (decklet-edit--restore-position line win-line)
    (message "Unarchived \"%s\"" word)))

(defun decklet-edit-archive ()
  "Archive or unarchive marked cards, or the card at point."
  (interactive)
  (let ((marked (decklet-edit--marked-words)))
    (if marked
        (let* ((unarchive-p (eq decklet-edit--filter 'archived))
               (verb (if unarchive-p "Unarchive" "Archive"))
               (done-verb (if unarchive-p "Unarchived" "Archived"))
               (action (if unarchive-p #'decklet-unarchive-card #'decklet-archive-card))
               (win-line (count-screen-lines (window-start) (point)))
               (target-word (decklet-edit--nearest-surviving-word marked)))
          (decklet-edit--ensure-not-current marked)
          (when (yes-or-no-p (format "%s %d marked cards? " verb (length marked)))
            (dolist (word marked)
              (funcall action word))
            (decklet-edit--clear-marks)
            (decklet-edit-refresh)
            (when-let ((target-line (decklet-edit--line-of-word target-word)))
              (decklet-edit--restore-position target-line win-line))
            (message "%s %d cards" done-verb (length marked))))
      (if (eq decklet-edit--filter 'archived)
          (decklet-edit-unarchive-card)
        (decklet-edit-archive-card)))))

;; Edit mode setup

;;;###autoload
(defun decklet-edit ()
  "Open the card list for editing."
  (interactive)
  (run-hooks 'decklet-edit-start-hook)
  (let ((buffer (get-buffer-create decklet-edit-buffer-name)))
    (with-current-buffer buffer
      (decklet-edit-mode)
      (decklet-edit-refresh))
    (switch-to-buffer buffer)))

(defun decklet-edit-quit ()
  "Quit the edit buffer."
  (interactive)
  (decklet-edit--clean-up)
  (when-let ((buffer (get-buffer decklet-edit-buffer-name)))
    (kill-buffer buffer))
  (run-hooks 'decklet-edit-quit-hook)
  (decklet-db--disconnect-if-idle))

;; Backup
(add-hook 'decklet-edit-start-hook #'decklet-db-backup)
(add-hook 'decklet-edit-quit-hook #'decklet-db-backup)

(defvar decklet-edit-mode-map
  (define-keymap
    :parent tabulated-list-mode-map
    "e" #'decklet-edit-word
    "t" #'decklet-edit-hint
    "D" #'decklet-edit-delete
    "/ r" #'decklet-edit-filter-review
    "/ l" #'decklet-edit-filter-learning
    "/ a" #'decklet-edit-filter-toggle-archive
    "; w" (decklet-edit--column-sort-command "Word")
    "; a" (decklet-edit--column-sort-command "Added")
    "; l" (decklet-edit--column-sort-command "Last Review")
    "; d" (decklet-edit--column-sort-command "Due")
    "; s" (decklet-edit--column-sort-command "Stability")
    "; f" (decklet-edit--column-sort-command "Difficulty")
    "R" #'decklet-edit-rate-card
    "A" #'decklet-edit-archive
    "m" #'decklet-edit-mark
    "u" #'decklet-edit-unmark
    "U" #'decklet-edit-unmark-all
    "<remap> <tabulated-list-sort>" #'decklet-edit-refresh
    "g" #'decklet-edit-refresh
    "+" #'decklet-add-card
    "q" #'decklet-edit-quit)
  "Keymap for `decklet-edit-mode'.")

(define-derived-mode decklet-edit-mode tabulated-list-mode "Decklet-Edit"
  "Major mode for listing and editing Decklet cards."
  (setq tabulated-list-format
        (vector
         (list "Word" 24 (decklet-edit--column-sorter "Word"))
         (list "Hint" 40 t)
         (list "Added" 20 (decklet-edit--column-sorter "Added"))
         (list "Last Review" 20 (decklet-edit--column-sorter "Last Review"))
         (list "Due" 20 (decklet-edit--column-sorter "Due"))
         (list "State" 10 t)
         (list "Stability" 10 (decklet-edit--column-sorter "Stability"))
         (list "Difficulty" 10 (decklet-edit--column-sorter "Difficulty"))))
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(provide 'decklet-edit)
;;; decklet-edit.el ends here

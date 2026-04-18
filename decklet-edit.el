;;; decklet-edit.el --- Edit mode for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Tabulated-list based edit UI.

;;; Code:

(require 'cl-lib)
(require 'parse-time)
(require 'seq)
(require 'tabulated-list)

(require 'decklet-core)
(require 'decklet-scheduler)
(require 'decklet-db)
(require 'decklet-deck)

(defvar decklet-review-buffer-name)

(defgroup decklet-edit nil
  "Edit mode for Decklet."
  :group 'decklet)

;; Faces

(defface decklet-edit-word-face
  `((t :foreground ,(face-attribute 'decklet-color-word :foreground)
       :weight bold))
  "Face for displaying the word in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-word-archived-face
  `((t :foreground ,(face-attribute 'ansi-color-cyan :foreground)
       :weight bold))
  "Face for displaying archived words in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-hint-face
  `((t :foreground ,(face-attribute 'decklet-color-hint :foreground)))
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

(defface decklet-edit-state-new-face
  `((t :foreground ,(face-attribute 'decklet-color-state-new :foreground)
       :weight bold))
  "Face for new-card state labels in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-state-learning-face
  `((t :foreground ,(face-attribute 'decklet-color-state-learning :foreground)
       :weight bold))
  "Face for learning-card state labels in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-state-review-face
  `((t :foreground ,(face-attribute 'decklet-color-state-review :foreground)
       :weight bold))
  "Face for review-card state labels in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-card-back-indicator-face
  `((t :foreground ,(face-attribute 'decklet-color-card-back :foreground)
       :weight bold))
  "Face for the back indicator in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-mark-face
  '((((background dark)) (:background "DarkGoldenrod4"))
    (t (:background "LightYellow1")))
  "Face for marked rows in the edit table."
  :group 'decklet-edit)

(defface decklet-edit-mark-indicator-face
  `((t :foreground ,(face-attribute 'ansi-color-yellow :foreground)))
  "Face for the mark indicator character."
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

(defvar decklet-edit--inhibit-callback-refresh nil
  "When it is non-nil, inhibit refresh during bulk processing")

(defvar decklet-edit-sidecar-columns nil
  "Additional sidecar column descriptors for the edit table.
Each descriptor is a plist with keys:
`:name'   column header string
`:width'  tabulated-list column width
`:value'  function of one ROW plist returning a display cell or nil.

Sidecar columns are inserted after the built-in `Back' column.")

(defconst decklet-edit--numeric-columns
  '("Stability" "Difficulty")
  "Columns that should be sorted numerically.")

(defconst decklet-edit--time-sort-columns
  '("Added" "Last Review" "Due")
  "Columns that default to descending order when sorting.")

(defconst decklet-edit--db-sort-columns
  '(("Word" . "word")
    ("Hint" . "hint")
    ("Added" . "added_date")
    ("Due" . "due")
    ("State" . "state")
    ("Stability" . "stability")
    ("Difficulty" . "difficulty"))
  "Mapping of edit table column names to database column names.")

(defun decklet-edit--columns ()
  "Return ordered edit table column names, including sidecar columns."
  (append '("Word" "Hint" "Back")
          (mapcar (lambda (column) (plist-get column :name)) decklet-edit-sidecar-columns)
          '("State" "Added" "Last Review" "Due" "Stability" "Difficulty")))

(defun decklet-edit--column-indices ()
  "Return an alist mapping edit table column names to indices."
  (let ((index 0)
        (table nil))
    (dolist (name (decklet-edit--columns) (nreverse table))
      (push (cons name index) table)
      (setq index (1+ index)))))

;; Edit table formatting and sorting

(defun decklet-edit--db-sort-key (sort-key)
  "Translate tabulated-list SORT-KEY to a DB sort-key.
SORT-KEY is (UI-COLUMN . DESCENDING-P).  Returns (DB-COLUMN . DESCENDING-P)."
  (when sort-key
    (let ((db-col (cdr (assoc-string (car sort-key) decklet-edit--db-sort-columns))))
      (cons (or db-col "word") (cdr sort-key)))))

(defun decklet-edit--clean-up ()
  "Clear edit session state."
  (setq decklet-edit--marked (make-hash-table :test 'equal))
  (setq decklet-edit--mark-overlays (make-hash-table :test 'equal))
  (setq decklet-edit--filter 'all))

(defun decklet-edit--format-timestamp (timestamp)
  "Format TIMESTAMP for display in the edit table."
  (if (string-empty-p (or timestamp ""))
      ""
    (format-time-string "%Y-%m-%d %H:%M"
                        (parse-iso8601-time-string timestamp))))

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

(defun decklet-edit--nearest-surviving-card-id (deleted-card-ids)
  "Return the nearest table card id not listed in DELETED-CARD-IDS.
If multiple words are equally near point, prefer a following line."
  (let* ((origin-line (line-number-at-pos))
         (best-card-id nil)
         (best-distance nil)
         (best-forward nil))
    (save-excursion
      (goto-char (point-min))
      (let ((line 1))
        (while (< (point) (point-max))
          (let ((card-id (tabulated-list-get-id)))
            (when (and card-id
                       (not (member card-id deleted-card-ids)))
              (let* ((delta (abs (- line origin-line)))
                     (forward (>= line origin-line)))
                (when (or (null best-distance)
                          (< delta best-distance)
                          (and (= delta best-distance)
                               (and forward (not best-forward))))
                  (setq best-card-id card-id
                        best-distance delta
                        best-forward forward)))))
          (forward-line 1)
          (cl-incf line))))
    best-card-id))

(defun decklet-edit--line-of-card-id (card-id)
  "Return line number of CARD-ID in current edit table, or nil if not found."
  (when card-id
    (save-excursion
      (goto-char (point-min))
      (let ((line 1)
            found)
        (while (and (not found) (< (point) (point-max)))
          (when (eql (tabulated-list-get-id) card-id)
            (setq found line))
          (forward-line 1)
          (cl-incf line))
        found))))

(defun decklet-edit--sidecar-column-cells (row)
  "Return sidecar column cells for ROW."
  (mapcar (lambda (column)
            (or (funcall (plist-get column :value) row) ""))
          decklet-edit-sidecar-columns))

(defun decklet-edit--tabulated-list-format ()
  "Return the current tabulated-list format for the edit buffer."
  (vconcat
   (list
    (list "Word" 24 (decklet-edit--column-sorter "Word"))
    (list "Hint" 40 t)
    (list "Back" 5 nil))
   (mapcar (lambda (column)
             (list (plist-get column :name)
                   (or (plist-get column :width) 5)
                   nil))
           decklet-edit-sidecar-columns)
   (list
    (list "State" 10 t)
    (list "Added" 20 (decklet-edit--column-sorter "Added"))
    (list "Last Review" 20 (decklet-edit--column-sorter "Last Review"))
    (list "Due" 20 (decklet-edit--column-sorter "Due"))
    (list "Stability" 10 (decklet-edit--column-sorter "Stability"))
    (list "Difficulty" 10 (decklet-edit--column-sorter "Difficulty")))))

(defmacro decklet-edit--column-sorter (column)
  "Return a sorter lambda for COLUMN.
Column index and numeric-ness are captured once when the lambda is
constructed, not per comparison — a fresh closure is built on each
`decklet-edit--tabulated-list-format' refresh, so sidecar column
changes propagate through the next format rebuild."
  `(let ((index (alist-get ,column (decklet-edit--column-indices) nil nil #'string=))
         (numeric-p (member ,column decklet-edit--numeric-columns)))
     (lambda (a b)
       (if numeric-p
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

(defun decklet-edit--card-id-at-point ()
  "Return the card id for the card on the current line.
Signal a `user-error' if point is not on a card row."
  (or (tabulated-list-get-id)
      (user-error "No card on this line")))

(defun decklet-edit--ensure-not-current (card-ids)
  "Signal an error if CARD-IDS include the current review card.
CARD-IDS can be a single card id or a list of card ids."
  (let ((current decklet-current-card-id))
    (when (and current
               (if (listp card-ids)
                   (memq current card-ids)
                 (eql card-ids current)))
      (user-error "Current review word \"%s\" can only be modified in review mode"
                  (decklet-card-word-by-id current)))))

(defun decklet-edit--card-at-point (&optional ensure-not-current)
  "Return the current edit-row card as a plist with `:card-id' and `:word'.
When ENSURE-NOT-CURRENT is non-nil, reject the current review card first."
  (let ((card-id (decklet-edit--card-id-at-point)))
    (when ensure-not-current
      (decklet-edit--ensure-not-current card-id))
    (list :card-id card-id
          :word (decklet-card-word-by-id card-id))))

(defun decklet-edit-rate-card ()
  "Rate the card at point, regardless of its current state.
When the current filter is `archived', the card is unarchived
first and then rated, so rating from the archived view brings the
card back into the active deck as a side effect."
  (interactive)
  (when decklet-current-card-id
    (user-error "Rating is disabled while a review session is active"))
  (let* ((card (decklet-edit--card-at-point t))
         (card-id (plist-get card :card-id))
         (word (plist-get card :word))
         (grade-options '((1 . "Again") (2 . "Hard") (3 . "Good") (4 . "Easy")))
         (prompt (concat (format "Rate \"%s\" " word)
                         (mapconcat (lambda (g)
                                      (format "[%d] %s" (car g) (cdr g)))
                                    grade-options " ")
                         ": "))
         (grade (- (read-char-choice prompt '(?1 ?2 ?3 ?4)) ?0))
         (label (alist-get grade grade-options "" nil #'=)))
    (if (eq decklet-edit--filter 'archived)
        (decklet-edit--with-deferred-refresh
         (decklet-unarchive-card card-id)
         (decklet-rate-card card-id grade))
      (decklet-rate-card card-id grade))
    (message "Rated \"%s\" as %s" word label)))

;; Edit table mode and commands

(defun decklet-edit--entries ()
  "Return tabulated list entries for the edit buffer."
  (mapcar
   (lambda (row)
     (let* ((word (plist-get row :word))
            (card-id (plist-get row :card-id))
            (added (or (plist-get row :added) ""))
            (last-review (or (plist-get row :last-review) ""))
            (due (or (plist-get row :due) ""))
            (state (decklet--normalize-fsrs-state (plist-get row :state)))
            (stability (plist-get row :stability))
            (difficulty (plist-get row :difficulty))
            (hint (plist-get row :hint))
            (back (plist-get row :back))
            (display-state (decklet-card-display-state state last-review))
            (word-face (if (eq decklet-edit--filter 'archived)
                           'decklet-edit-word-archived-face
                         'decklet-edit-word-face))
            (state-face (pcase display-state
                          (:new 'decklet-edit-state-new-face)
                          ((or :learning :relearning) 'decklet-edit-state-learning-face)
                          (:review 'decklet-edit-state-review-face)
                          (_ 'decklet-edit-state-face)))
            (state-text (or (decklet--fsrs-state-string display-state) ""))
            (display-word (replace-regexp-in-string "[\r\n]+" "↵" word nil 'literal))
            (hint (if hint
                      (replace-regexp-in-string "[\r\n]+" "↵" hint nil 'literal)
                    "")))
       (list card-id
             (vconcat
              (vector
               (propertize display-word 'face word-face)
               (propertize hint 'face 'decklet-edit-hint-face)
               (if back (propertize "♦" 'face 'decklet-edit-card-back-indicator-face) ""))
              (apply #'vector (decklet-edit--sidecar-column-cells row))
              (vector
               (propertize state-text 'face state-face)
               (propertize (decklet-edit--format-timestamp added)
                           'face 'decklet-edit-added-face
                           'decklet-sort-key added)
               (propertize (decklet-edit--format-timestamp last-review)
                           'face 'decklet-edit-last-review-face
                           'decklet-sort-key last-review)
               (propertize (decklet-edit--format-timestamp due)
                           'face 'decklet-edit-due-face
                           'decklet-sort-key due)
               (propertize (if stability (format "%.3f" stability) "")
                           'face 'decklet-edit-stability-face
                           'decklet-sort-number (or stability 0))
               (propertize (if difficulty (format "%.3f" difficulty) "")
                           'face 'decklet-edit-difficulty-face
                           'decklet-sort-number (or difficulty 0)))))))
   (decklet-db--select-cards decklet-edit--filter
                             (decklet-edit--db-sort-key tabulated-list-sort-key))))

(defun decklet-edit-refresh ()
  "Refresh the card list buffer."
  (interactive)
  (setq tabulated-list-format (decklet-edit--tabulated-list-format))
  (tabulated-list-init-header)
  (setq tabulated-list-entries (delq nil (decklet-edit--entries)))
  (tabulated-list-print t)
  (decklet-edit--apply-marks))

(defmacro decklet-edit--with-deferred-refresh (&rest body)
  "Run BODY as one bulk edit operation with callback refreshes suppressed.
Card-change callbacks triggered inside BODY do not refresh the edit
buffer immediately.  Instead, the edit buffer is refreshed once on exit."
  `(let ((decklet-edit--inhibit-callback-refresh t))
     (unwind-protect
         (progn ,@body)
       (decklet-edit-refresh))))

(defun decklet-edit--apply-marks ()
  "Apply marked-row faces to the edit buffer."
  (decklet-edit--clear-mark-overlays)
  (save-excursion
    (goto-char (point-min))
    (forward-line 1)
    (while (not (eobp))
      (let ((card-id (tabulated-list-get-id)))
        (when (gethash card-id decklet-edit--marked)
          (decklet-edit--add-mark-overlay card-id)))
      (forward-line 1))))

(defun decklet-edit--marked-card-ids ()
  "Return a list of marked card ids."
  (let (card-ids)
    (maphash (lambda (card-id _value) (push card-id card-ids)) decklet-edit--marked)
    (nreverse card-ids)))

(defun decklet-edit--delete-overlay-cons (overlay-cons)
  "Delete overlays in OVERLAY-CONS."
  (delete-overlay (car overlay-cons))
  (delete-overlay (cdr overlay-cons)))

(defun decklet-edit--clear-mark-overlays ()
  "Remove all mark overlays in the edit view."
  (maphash (lambda (_word ovs)
             (decklet-edit--delete-overlay-cons ovs))
           decklet-edit--mark-overlays)
  (clrhash decklet-edit--mark-overlays))

(defun decklet-edit--add-mark-overlay (card-id)
  "Add a mark overlay for CARD-ID on the current line."
  (when-let* ((ovs (gethash card-id decklet-edit--mark-overlays)))
    ;; remove overlays to avoid duplication
    (decklet-edit--delete-overlay-cons ovs))
  (let ((ov (make-overlay (line-beginning-position) (line-end-position)))
        (mark-ov (make-overlay (line-beginning-position)
                               (1+ (line-beginning-position)))))
    (overlay-put ov 'face 'decklet-edit-mark-face)
    (overlay-put mark-ov 'display (propertize "*" 'face 'decklet-edit-mark-indicator-face))
    (puthash card-id (cons ov mark-ov) decklet-edit--mark-overlays)))

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
        (when-let* ((card-id (tabulated-list-get-id)))
          (puthash card-id t decklet-edit--marked)
          (decklet-edit--add-mark-overlay card-id))
        (forward-line 1)))))

(defun decklet-edit-mark-at-point ()
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
    (let ((card-id (decklet-edit--card-id-at-point)))
      (puthash card-id t decklet-edit--marked)
      (decklet-edit--add-mark-overlay card-id)
      (forward-line 1))))

(defun decklet-edit-unmark-at-point ()
  "Unmark the card at point and move to the next line."
  (interactive)
  (let ((card-id (decklet-edit--card-id-at-point)))
    (remhash card-id decklet-edit--marked)
    (when-let* ((ovs (gethash card-id decklet-edit--mark-overlays)))
      (decklet-edit--delete-overlay-cons ovs)
      (remhash card-id decklet-edit--mark-overlays))
    (forward-line 1)))

(defun decklet-edit--unmark-all ()
  "Clear all mark in the edit view."
  (clrhash decklet-edit--marked)
  (decklet-edit--clear-mark-overlays))

(defun decklet-edit-unmark-all ()
  "Clear all mark in the edit view."
  (interactive)
  (decklet-edit--unmark-all)
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
  "Edit the card at point using EDIT-WORD and EDIT-HINT flags.
Field edits (word, hint) are allowed on the current review card:
`decklet-cards-field-updated-functions' and
`decklet-cards-renamed-functions' carry the change to the review
buffer, which refreshes if the edited card is on screen."
  (let* ((card (decklet-edit--card-at-point))
         (card-id (plist-get card :card-id)))
    (message "Updated \"%s\""
             (decklet-prompt-edit-card-fields card-id edit-word edit-hint))))

(defun decklet-edit-word ()
  "Edit the word at point."
  (interactive)
  (decklet-edit--edit-card-at-point t nil))

(defun decklet-edit-hint ()
  "Edit the hint at point."
  (interactive)
  (decklet-edit--edit-card-at-point nil t))

(defun decklet-edit-show-card-back ()
  "Show the card back for the card at point in a read-only popup."
  (interactive)
  (decklet-card-back-show (plist-get (decklet-edit--card-at-point) :word)))

(defun decklet-edit-delete-card ()
  "Delete the card at point from the deck."
  (interactive)
  (let* ((card (decklet-edit--card-at-point t))
         (card-id (plist-get card :card-id))
         (word (plist-get card :word)))
    (when (yes-or-no-p (format "Delete \"%s\" from the deck? " word))
      (decklet-delete-card card-id)
      (message "Deleted \"%s\"" word))))

(defun decklet-edit-delete ()
  "Delete marked cards, or the card at point."
  (interactive)
  (let ((marked (decklet-edit--marked-card-ids)))
    (if marked
        ;; bulk processing
        (let* ((win-line (count-screen-lines (window-start) (point)))
               (target-card-id (decklet-edit--nearest-surviving-card-id marked)))
          (decklet-edit--ensure-not-current marked)
          (when (yes-or-no-p (format "Delete %d marked cards? " (length marked)))
            (decklet-edit--with-deferred-refresh
             (decklet-edit--unmark-all)
             (mapc #'decklet-delete-card marked))
            (when-let* ((target-line (decklet-edit--line-of-card-id target-card-id)))
              (decklet-edit--restore-position target-line win-line))
            (message "Deleted %d cards" (length marked))))
      (decklet-edit-delete-card))))

(defun decklet-edit-archive-card ()
  "Archive the card at point."
  (interactive)
  (let* ((card (decklet-edit--card-at-point t))
         (card-id (plist-get card :card-id))
         (word (plist-get card :word)))
    (when (yes-or-no-p (format "Archive \"%s\" from review? " word))
      (decklet-archive-card card-id)
      (message "Archived \"%s\"" word))))

(defun decklet-edit-unarchive-card ()
  "Unarchive the card at point."
  (interactive)
  (let* ((card (decklet-edit--card-at-point t))
         (card-id (plist-get card :card-id)))
    (decklet-unarchive-card card-id)
    (message "Unarchived \"%s\"" (plist-get card :word))))

(defun decklet-edit-archive ()
  "Archive or unarchive marked cards, or the card at point."
  (interactive)
  (let ((marked (decklet-edit--marked-card-ids)))
    (if marked
        ;; bulk processing
        (let* ((unarchive-p (eq decklet-edit--filter 'archived))
               (verb (if unarchive-p "Unarchive" "Archive"))
               (done-verb (if unarchive-p "Unarchived" "Archived"))
               (action (if unarchive-p #'decklet-unarchive-card #'decklet-archive-card))
               (win-line (count-screen-lines (window-start) (point)))
               (target-card-id (decklet-edit--nearest-surviving-card-id marked)))
          (decklet-edit--ensure-not-current marked)
          (when (yes-or-no-p (format "%s %d marked cards? " verb (length marked)))
            (decklet-edit--with-deferred-refresh
             (decklet-edit--unmark-all)
             (mapc action marked))
            (when-let* ((target-line (decklet-edit--line-of-card-id target-card-id)))
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
  (when-let* ((buffer (get-buffer decklet-edit-buffer-name)))
    (kill-buffer buffer))
  (run-hooks 'decklet-edit-quit-hook)
  (decklet-db--disconnect-if-idle))

;; Backup
(add-hook 'decklet-edit-start-hook #'decklet-db-backup)
(add-hook 'decklet-edit-quit-hook #'decklet-db-backup)

;; Refresh the edit table whenever a card changes.  Each mutation in
;; `decklet-deck.el' fires one of these hooks, so the edit buffer stays
;; in sync without its own commands needing to call `decklet-edit-refresh'
;; directly.
(defun decklet-edit--on-card-change (&rest _)
  "Refresh the edit buffer after a card change.
Accepts any hook signature; arguments are ignored."
  (unless decklet-edit--inhibit-callback-refresh
    (when-let* ((buffer (get-buffer decklet-edit-buffer-name)))
      (with-current-buffer buffer
        (when (derived-mode-p 'decklet-edit-mode)
          (decklet-edit-refresh))))))

(dolist (hook '(decklet-cards-added-functions
                decklet-cards-deleted-functions
                decklet-cards-renamed-functions
                decklet-cards-archived-functions
                decklet-cards-unarchived-functions
                decklet-cards-field-updated-functions
                decklet-cards-rated-functions))
  (add-hook hook #'decklet-edit--on-card-change))

(defvar decklet-edit-mode-map
  (define-keymap
    :parent tabulated-list-mode-map
    "e" #'decklet-edit-word
    "t" #'decklet-edit-hint
    "b" #'decklet-edit-show-card-back
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
    "m" #'decklet-edit-mark-at-point
    "u" #'decklet-edit-unmark-at-point
    "U" #'decklet-edit-unmark-all
    "<remap> <tabulated-list-sort>" #'decklet-edit-refresh
    "g" #'decklet-edit-refresh
    "q" #'decklet-edit-quit)
  "Keymap for `decklet-edit-mode'.")

(define-derived-mode decklet-edit-mode tabulated-list-mode "Decklet-Edit"
  "Major mode for listing and editing Decklet cards."
  (setq tabulated-list-format (decklet-edit--tabulated-list-format))
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header))

(provide 'decklet-edit)
;;; decklet-edit.el ends here

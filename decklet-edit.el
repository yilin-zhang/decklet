;;; decklet-edit.el --- Edit mode for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yilin Zhang

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
(require 'decklet-backup)
(require 'decklet-deck)
(require 'decklet-card-back)
(require 'decklet-lookup)

(defgroup decklet-edit nil
  "Edit mode for Decklet."
  :group 'decklet)

;;; Faces

(defface decklet-edit-word-face
  '((t :inherit decklet-color-word :weight bold))
  "Face for displaying the word in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-word-archived-face
  '((t :inherit ansi-color-cyan :background reset :weight bold))
  "Face for displaying archived words in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-metadata-face
  '((t :inherit font-lock-comment-face))
  "Face for displaying scheduling metadata in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-state-new-face
  '((t :inherit decklet-color-state-new :weight bold))
  "Face for new-card state labels in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-state-learning-face
  '((t :inherit decklet-color-state-learning :weight bold))
  "Face for learning-card state labels in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-state-review-face
  '((t :inherit decklet-color-state-review :weight bold))
  "Face for review-card state labels in edit lists."
  :group 'decklet-edit)

(defface decklet-edit-card-back-indicator-face
  '((t :inherit decklet-color-card-back :weight bold))
  "Face for the back indicator in edit lists."
  :group 'decklet-edit)

(defcustom decklet-edit-card-back-indicator "♦"
  "Indicator string shown in the Back column for cards with a back."
  :type 'string
  :group 'decklet-edit)

(defface decklet-edit-mark-face
  '((((background dark)) (:background "DarkGoldenrod4"))
    (t (:background "LightYellow1")))
  "Face for marked rows in the edit table."
  :group 'decklet-edit)

(defface decklet-edit-mark-indicator-face
  '((t :inherit ansi-color-yellow :background reset))
  "Face for the mark indicator character."
  :group 'decklet-edit)

;;; Hooks

(defcustom decklet-edit-start-hook nil
  "Hook run when decklet edit session starts."
  :type 'hook
  :group 'decklet-edit)

(defcustom decklet-edit-quit-hook nil
  "Hook run when decklet edit session quits."
  :type 'hook
  :group 'decklet-edit)

;;; Internal

(defvar decklet-edit-buffer-name "*Decklet Edit*"
  "Name of the buffer used for card editing.")

(defvar-local decklet-edit--marked nil
  "Hash table of marked card ids in the edit view.")

(defvar-local decklet-edit--tag-filter nil
  "Tag required by the edit view, or nil to show all tags.")

(defvar-local decklet-edit--filter 'all
  "Current filter for the edit table.
One of all, review, learning or archived.")

(defvar decklet-edit--inhibit-callback-refresh nil
  "When it is non-nil, inhibit refresh during bulk processing.")

(defvar-local decklet-edit--refresh-pending nil
  "Non-nil when the edit buffer needs a refresh on next focus.
Refreshing it while unselected would move point off the user's row.")

(defvar decklet-edit-sidecar-columns nil
  "Additional sidecar column descriptors for the edit table.
Each descriptor is a plist with keys:
`:name'   column header string
`:width'  tabulated-list column width
`:value'  function of one ROW plist returning a display cell or nil.

Sidecar columns are inserted after the built-in `Back' column.")

(defconst decklet-edit--time-sort-columns
  '("Added" "Last Review" "Due")
  "Columns that default to descending order when sorting.")

;;; Table formatting, sorting and point position

(defun decklet-edit--format-timestamp (timestamp)
  "Format TIMESTAMP for display in the edit table."
  (if (null timestamp)
      ""
    (format-time-string "%Y-%m-%d %H:%M"
                        (parse-iso8601-time-string timestamp))))

(defmacro decklet-edit--preserving-window-position (&rest body)
  "Run BODY, then scroll so point is back on the same screen row.
Without a live window, BODY just runs."
  (declare (indent 0) (debug t))
  (let ((win-sym (make-symbol "win"))
        (row-sym (make-symbol "row")))
    `(let* ((,win-sym (get-buffer-window (current-buffer) 0))
            (,row-sym (and ,win-sym
                           (with-selected-window ,win-sym
                             (when-let* ((posn (posn-at-point)))
                               (cdr (posn-col-row posn)))))))
       (prog1 (progn ,@body)
         (when (and ,win-sym ,row-sym (window-live-p ,win-sym))
           (with-selected-window ,win-sym
             (recenter ,row-sym)))))))

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

(defun decklet-edit--goto-card-id (card-id)
  "Move point to the row whose tabulated-list id equals CARD-ID.
Return point on success, or nil when CARD-ID is nil or not found."
  (when card-id
    (let ((target nil))
      (save-excursion
        (goto-char (point-min))
        (while (and (not target) (< (point) (point-max)))
          (when (eql (tabulated-list-get-id) card-id)
            (setq target (point)))
          (forward-line 1)))
      (when target
        (goto-char target)))))

(defun decklet-edit--execute-mutation (action card-ids)
  "Apply ACTION to each of CARD-IDS, then refresh the table once.
Point stays on its row, or moves to the nearest surviving card."
  (let ((origin-card-id (tabulated-list-get-id))
        (target-card-id (decklet-edit--nearest-surviving-card-id card-ids)))
    (decklet-edit--preserving-window-position
      (let ((decklet-edit--inhibit-callback-refresh t))
        (unwind-protect
            (mapc action card-ids)
          (decklet-edit--refresh-table)))
      (or (decklet-edit--goto-card-id origin-card-id)
          (decklet-edit--goto-card-id target-card-id)))))

(defun decklet-edit--column-sorter (column)
  "Return a sorter for edit table COLUMN; blank cells sort first.
The sorter compares the `decklet-sort' property of the column's cells,
numerically when it is a number."
  ;; The format holding COLUMN is installed after this sorter is built,
  ;; so look up the column's position on first use.
  (let (index)
    (cl-flet ((value (entry)
                (unless index
                  (setq index (seq-position tabulated-list-format column
                                            (lambda (spec name)
                                              (equal (car spec) name)))))
                ;; A blank cell is "", which cannot carry a text property.
                (get-text-property 0 'decklet-sort (aref (cadr entry) index))))
      (lambda (a b)
        (let ((x (value a))
              (y (value b)))
          (cond ((null y) nil)
                ((null x) t)
                ((numberp x) (< x y))
                (t (string< x y))))))))

(defun decklet-edit--column-sort-command (column)
  "Return an interactive command to sort by COLUMN."
  (lambda ()
    (interactive)
    ;; `tabulated-list-sort-key' is (COLUMN . DESC), where DESC is t/nil.
    ;; The same column toggles; another starts in its default direction.
    (let* ((current (car tabulated-list-sort-key))
           (descending (if (equal current column)
                           (not (cdr tabulated-list-sort-key))
                         (and (member column decklet-edit--time-sort-columns) t))))
      (setq tabulated-list-sort-key (cons column descending))
      (decklet-edit-refresh)
      (message "Sort: %s (%s)"
               column
               (if descending "descending" "ascending")))))

(defun decklet-edit--tabulated-list-format ()
  "Return the current tabulated-list format for the edit buffer."
  (vconcat
   `(("Word" 24 ,(decklet-edit--column-sorter "Word"))
     ("Hint" 28 nil)
     ("Tags" 16 nil)
     ("Back" 5 nil))
   (mapcar (pcase-lambda ((map :name :width))
             (list name (or width 5) nil))
           decklet-edit-sidecar-columns)
   `(("State" 10 t)
     ("Added" 20 ,(decklet-edit--column-sorter "Added"))
     ("Last Review" 20 ,(decklet-edit--column-sorter "Last Review"))
     ("Due" 20 ,(decklet-edit--column-sorter "Due"))
     ("Stability" 10 ,(decklet-edit--column-sorter "Stability"))
     ("Difficulty" 10 ,(decklet-edit--column-sorter "Difficulty")))))

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
                  (decklet-get-card-word current)))))

(defun decklet-edit--entries ()
  "Return tabulated list entries for the edit buffer."
  (let ((entries
         (mapcar
          (lambda (row)
            (pcase-let* (((map :card-id :word :hint :tags :back :added :last-review :due
                               :state :stability :difficulty)
                          row)
                         (state (decklet--normalize-fsrs-state state))
                         (effective-state (decklet-card-effective-state state last-review))
                         (word-face (if (eq decklet-edit--filter 'archived)
                                        'decklet-edit-word-archived-face
                                      'decklet-edit-word-face))
                         (state-face (pcase effective-state
                                       (:new 'decklet-edit-state-new-face)
                                       (:review 'decklet-edit-state-review-face)
                                       (_ 'decklet-edit-state-learning-face))) ; :learning or :relearning
                         (state-text (decklet-fsrs-state-string effective-state))
                         (display-word (replace-regexp-in-string "[\r\n]+" "↵" word nil 'literal))
                         (hint (if hint
                                   (replace-regexp-in-string
                                    "[\r\n]+"
                                    (lambda (_line-break)
                                      (propertize "↵" 'face 'decklet-edit-metadata-face))
                                    hint)
                                 "")))
              (list card-id
                    (vconcat
                     (vector
                      (propertize display-word 'face word-face 'decklet-sort word)
                      hint
                      (propertize (string-join tags " ") 'face 'decklet-color-tags
                                  'help-echo (string-join tags " "))
                      (if back
                          (propertize decklet-edit-card-back-indicator
                                      'face 'decklet-edit-card-back-indicator-face)
                        ""))
                     (apply #'vector
                            (mapcar (lambda (column)
                                      (or (funcall (plist-get column :value) row) ""))
                                    decklet-edit-sidecar-columns))
                     (vector
                      (propertize state-text 'face state-face)
                      (propertize (decklet-edit--format-timestamp added)
                                  'face 'decklet-edit-metadata-face
                                  'decklet-sort added)
                      (propertize (decklet-edit--format-timestamp last-review)
                                  'face 'decklet-edit-metadata-face
                                  'decklet-sort last-review)
                      (propertize (decklet-edit--format-timestamp due)
                                  'face 'decklet-edit-metadata-face
                                  'decklet-sort due)
                      (propertize (if stability (format "%.3f" stability) "")
                                  'face 'decklet-edit-metadata-face
                                  'decklet-sort stability)
                      (propertize (if difficulty (format "%.3f" difficulty) "")
                                  'face 'decklet-edit-metadata-face
                                  'decklet-sort difficulty))))))
          (seq-filter
           (lambda (row) (or (null decklet-edit--tag-filter)
                             (member decklet-edit--tag-filter (plist-get row :tags))))
           (decklet-db--select-card-rows decklet-edit--filter)))))
    (decklet-edit--prune-marks entries)
    entries))

(defun decklet-edit--prune-marks (entries)
  "Drop marks whose card id is no longer present in ENTRIES."
  (when (and decklet-edit--marked (> (hash-table-count decklet-edit--marked) 0))
    (let ((visible (make-hash-table :test 'eql :size (length entries)))
          (stale nil))
      (dolist (entry entries)
        (puthash (car entry) t visible))
      (maphash (lambda (id _value)
                 (unless (gethash id visible)
                   (push id stale)))
               decklet-edit--marked)
      (dolist (id stale)
        (remhash id decklet-edit--marked)))))

(defun decklet-edit--print-entry (id cols)
  "Insert tabulated-list entry ID with COLS and draw mark overlays if marked."
  (let ((beg (point)))
    (tabulated-list-print-entry id cols)
    (when (and decklet-edit--marked (gethash id decklet-edit--marked))
      (save-excursion
        (goto-char beg)
        (decklet-edit--add-mark-overlay)))))

(defun decklet-edit--marked-card-ids ()
  "Return a list of marked card ids."
  (let (card-ids)
    (maphash (lambda (card-id _value) (push card-id card-ids)) decklet-edit--marked)
    (nreverse card-ids)))

(defun decklet-edit--add-mark-overlay ()
  "Add mark overlays on the current line."
  (let ((bol (line-beginning-position))
        (eol (line-end-position)))
    ;; Drop any mark overlays already on this line.
    (remove-overlays bol eol 'decklet-mark t)
    (let ((row-ov (make-overlay bol eol))
          (ind-ov (make-overlay bol (1+ bol))))
      (overlay-put row-ov 'decklet-mark t)
      (overlay-put row-ov 'evaporate t)
      (overlay-put row-ov 'face 'decklet-edit-mark-face)
      (overlay-put ind-ov 'decklet-mark t)
      (overlay-put ind-ov 'evaporate t)
      (overlay-put ind-ov 'display
                   (propertize "*" 'face 'decklet-edit-mark-indicator-face)))))

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
          (decklet-edit--add-mark-overlay))
        (forward-line 1)))))

(defun decklet-edit--unmark-all ()
  "Clear all mark in the edit view."
  (clrhash decklet-edit--marked)
  (remove-overlays (point-min) (point-max) 'decklet-mark t))

;;; Edit mode commands

(defun decklet-edit--require-mode ()
  "Signal a `user-error' unless the current buffer is in `decklet-edit-mode'."
  (unless (derived-mode-p 'decklet-edit-mode)
    (user-error "Not in a Decklet edit buffer")))

(defun decklet-edit--refresh-table ()
  "Rebuild and reprint the edit table without touching window position."
  (setq tabulated-list-format (decklet-edit--tabulated-list-format))
  (tabulated-list-init-header)
  (tabulated-list-print t))

(defun decklet-edit-refresh ()
  "Refresh the card list buffer, keeping point on its screen line."
  (interactive nil decklet-edit-mode)
  (decklet-edit--require-mode)
  (decklet-edit--preserving-window-position
    (decklet-edit--refresh-table)))

(defun decklet-edit-mark-at-point ()
  "Mark card(s) at point.
If a region is active, mark all selected rows and move to the line after the
selection.  Otherwise, mark the card at point and move to the next line."
  (interactive nil decklet-edit-mode)
  (decklet-edit--require-mode)
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
      (decklet-edit--add-mark-overlay)
      (forward-line 1))))

(defun decklet-edit-unmark-at-point ()
  "Unmark the card at point and move to the next line."
  (interactive nil decklet-edit-mode)
  (decklet-edit--require-mode)
  (let ((card-id (decklet-edit--card-id-at-point)))
    (remhash card-id decklet-edit--marked)
    (remove-overlays (line-beginning-position) (line-end-position)
                     'decklet-mark t)
    (forward-line 1)))

(defun decklet-edit-unmark-all ()
  "Clear all mark in the edit view."
  (interactive nil decklet-edit-mode)
  (decklet-edit--require-mode)
  (decklet-edit--unmark-all)
  (message "Cleared all marks"))

(defun decklet-edit-filter-review ()
  "Show only review cards in the edit table."
  (interactive nil decklet-edit-mode)
  (decklet-edit--require-mode)
  (setq decklet-edit--filter 'review)
  (decklet-edit--unmark-all)
  (decklet-edit-refresh)
  (message "Filter: review"))

(defun decklet-edit-filter-learning ()
  "Show only learning cards in the edit table."
  (interactive nil decklet-edit-mode)
  (decklet-edit--require-mode)
  (setq decklet-edit--filter 'learning)
  (decklet-edit--unmark-all)
  (decklet-edit-refresh)
  (message "Filter: learning"))

(defun decklet-edit-filter-toggle-archive ()
  "Toggle between archived cards and all cards in the edit table."
  (interactive nil decklet-edit-mode)
  (decklet-edit--require-mode)
  (setq decklet-edit--filter
        (if (eq decklet-edit--filter 'all) 'archived 'all))
  (decklet-edit--unmark-all)
  (decklet-edit-refresh)
  (message "Filter: %s" decklet-edit--filter))

(defun decklet-edit-set-word ()
  "Rename the card at point, which may be the current review card."
  (interactive nil decklet-edit-mode)
  (decklet-edit--require-mode)
  (message "Updated \"%s\""
           (decklet-prompt-set-word (decklet-edit--card-id-at-point))))

(defun decklet-edit-set-tags ()
  "Edit tags at point, or add/remove tags on marked cards."
  (interactive nil decklet-edit-mode)
  (decklet-edit--require-mode)
  (let ((marked (decklet-edit--marked-card-ids)))
    (if (null marked)
        (decklet-prompt-set-tags (decklet-edit--card-id-at-point))
      (let* ((action (read-char-choice "Marked tags: (a)dd or (r)emove? " '(?a ?r)))
             (tags (decklet-read-tags)))
        (decklet-edit--execute-mutation
         (lambda (id)
           (funcall (if (eq action ?a) #'decklet-add-card-tags #'decklet-remove-card-tags)
                    id tags))
         marked)))))

(defun decklet-edit-filter-tag ()
  "Filter the edit view by a tag; empty input clears the tag filter."
  (interactive nil decklet-edit-mode)
  (decklet-edit--require-mode)
  (setq decklet-edit--tag-filter
        (let ((tag (completing-read "Tag (empty for all): " (decklet-list-tags))))
          (unless (string-empty-p tag) tag)))
  (decklet-edit--unmark-all)
  (decklet-edit-refresh))

(defun decklet-edit-set-hint ()
  "Set the hint for the card at point."
  (interactive nil decklet-edit-mode)
  (decklet-edit--require-mode)
  (message "Updated \"%s\""
           (decklet-prompt-set-hint (decklet-edit--card-id-at-point))))

(defun decklet-edit-show-card-back ()
  "Show the card back for the card at point in a read-only popup."
  (interactive nil decklet-edit-mode)
  (decklet-edit--require-mode)
  (decklet-show-card-back
   (decklet-get-card-word (decklet-edit--card-id-at-point))))

(defun decklet-edit-delete-card ()
  "Delete marked cards, or the card at point."
  (interactive nil decklet-edit-mode)
  (decklet-edit--require-mode)
  (let* ((marked (decklet-edit--marked-card-ids))
         (card-ids (or marked (list (decklet-edit--card-id-at-point))))
         (word (and (not marked) (decklet-get-card-word (car card-ids)))))
    (decklet-edit--ensure-not-current card-ids)
    (when (yes-or-no-p (if marked
                           (format "Delete %d marked cards? " (length marked))
                         (format "Delete \"%s\" from the deck? " word)))
      (when marked (decklet-edit--unmark-all))
      (decklet-edit--execute-mutation #'decklet-delete-card card-ids)
      (message (if marked
                   (format "Deleted %d cards" (length card-ids))
                 (format "Deleted \"%s\"" word))))))

(defun decklet-edit-archive-card ()
  "Archive marked cards, or the card at point.
Under the `archived' filter, the action is unarchive instead."
  (interactive nil decklet-edit-mode)
  (decklet-edit--require-mode)
  (let* ((marked (decklet-edit--marked-card-ids))
         (card-ids (or marked (list (decklet-edit--card-id-at-point))))
         (word (and (not marked) (decklet-get-card-word (car card-ids))))
         (unarchive-p (eq decklet-edit--filter 'archived))
         (action (if unarchive-p #'decklet-unarchive-card #'decklet-archive-card))
         (verb (if unarchive-p "Unarchive" "Archive"))
         (done-verb (if unarchive-p "Unarchived" "Archived")))
    (decklet-edit--ensure-not-current card-ids)
    (when (yes-or-no-p (cond
                        (marked (format "%s %d marked cards? " verb (length marked)))
                        (unarchive-p (format "%s \"%s\"? " verb word))
                        (t (format "%s \"%s\" from review? " verb word))))
      (when marked (decklet-edit--unmark-all))
      (decklet-edit--execute-mutation action card-ids)
      (message (if marked
                   (format "%s %d cards" done-verb (length card-ids))
                 (format "%s \"%s\"" done-verb word))))))

(defun decklet-edit-rate-card ()
  "Rate the card at point, regardless of its current state.
Under the `archived' filter, the card is unarchived first."
  (interactive nil decklet-edit-mode)
  (decklet-edit--require-mode)
  (when decklet-current-card-id
    (user-error "Rating is disabled while a review session is active"))
  (let* ((card-id (decklet-edit--card-id-at-point))
         (word (decklet-get-card-word card-id))
         (unarchive-p (eq decklet-edit--filter 'archived))
         (grade-options '((1 . "Again") (2 . "Hard") (3 . "Good") (4 . "Easy")))
         (prompt (concat (format "Rate \"%s\" " word)
                         (mapconcat (lambda (g)
                                      (format "[%d] %s" (car g) (cdr g)))
                                    grade-options " ")
                         ": "))
         (grade (- (read-char-choice prompt '(?1 ?2 ?3 ?4)) ?0))
         (label (alist-get grade grade-options "" nil #'=)))
    (decklet-edit--execute-mutation
     (lambda (id)
       (when unarchive-p (decklet-unarchive-card id))
       (decklet-rate-card id grade))
     (list card-id))
    (message "Rated \"%s\" as %s" word label)))

;;; Edit mode setup

;;;###autoload
(defun decklet-edit ()
  "Open the card list for editing, restarting if one is already open."
  (interactive)
  (when-let* ((existing (get-buffer decklet-edit-buffer-name)))
    (kill-buffer existing))
  (decklet-with-db
    (decklet-db--ensure)
    (let ((buffer (get-buffer-create decklet-edit-buffer-name))
          (started nil))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (decklet-edit-mode))
            (run-hooks 'decklet-edit-start-hook)
            (with-current-buffer buffer
              (decklet-edit-refresh))
            (switch-to-buffer buffer)
            (setq started t))
        (when (and (not started) (buffer-live-p buffer))
          (kill-buffer buffer))))))

(defun decklet-edit--on-kill-buffer ()
  "Run edit session teardown when the edit buffer is killed.
This runs for `decklet-edit-quit' and for a plain `kill-buffer' alike."
  (remove-hook 'window-selection-change-functions
               #'decklet-edit--flush-pending-refresh)
  (decklet-card-back--close-at-session-end)
  (decklet-run-hook-isolated 'decklet-edit-quit-hook))

(defun decklet-edit-quit ()
  "Quit the edit buffer."
  (interactive)
  (when-let* ((buffer (get-buffer decklet-edit-buffer-name)))
    (kill-buffer buffer)))

;;; Backup (see `decklet-backup-automatic')
(add-hook 'decklet-edit-start-hook #'decklet-backup-session)
(add-hook 'decklet-edit-quit-hook #'decklet-backup-session)

(defun decklet-edit--on-card-change (&rest _)
  "Refresh the edit buffer after a card change, or defer if not focused.
Accepts any hook signature; arguments are ignored."
  (unless decklet-edit--inhibit-callback-refresh
    (when-let* ((buffer (get-buffer decklet-edit-buffer-name)))
      (with-current-buffer buffer
        (when (derived-mode-p 'decklet-edit-mode)
          (if (eq buffer (window-buffer (selected-window)))
              (decklet-edit-refresh)
            (setq decklet-edit--refresh-pending t)))))))

(defun decklet-edit--flush-pending-refresh (&rest _)
  "Flush a pending refresh when the edit buffer becomes selected."
  (when-let* ((buffer (get-buffer decklet-edit-buffer-name)))
    (when (and (eq buffer (window-buffer (selected-window)))
               (buffer-local-value 'decklet-edit--refresh-pending buffer))
      (with-current-buffer buffer
        (setq decklet-edit--refresh-pending nil)
        (decklet-edit-refresh)))))

(defun decklet-edit--on-cards-deleted (events)
  "Drop deleted cards in EVENTS from marks and refresh the edit buffer."
  (when-let* ((buffer (get-buffer decklet-edit-buffer-name)))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'decklet-edit-mode)
                 decklet-edit--marked)
        (dolist (event events)
          (remhash (plist-get event :card-id) decklet-edit--marked)))))
  (decklet-edit--on-card-change))

(add-hook 'decklet-cards-deleted-functions #'decklet-edit--on-cards-deleted)
(dolist (hook '(decklet-cards-added-functions
                decklet-cards-renamed-functions
                decklet-cards-archived-functions
                decklet-cards-unarchived-functions
                decklet-cards-field-updated-functions
                decklet-cards-rated-functions))
  (add-hook hook #'decklet-edit--on-card-change))

(defvar decklet-edit-mode-map
  (define-keymap
    :parent tabulated-list-mode-map
    "e" #'decklet-edit-set-word
    "H" #'decklet-edit-set-hint
    "t" #'decklet-edit-set-tags
    ". t" #'decklet-edit-filter-tag
    "b" #'decklet-edit-show-card-back
    "l" #'decklet-lookup
    "L" #'decklet-lookup-with-provider
    "D" #'decklet-edit-delete-card
    ". r" #'decklet-edit-filter-review
    ". l" #'decklet-edit-filter-learning
    ". a" #'decklet-edit-filter-toggle-archive
    "; w" (decklet-edit--column-sort-command "Word")
    "; a" (decklet-edit--column-sort-command "Added")
    "; l" (decklet-edit--column-sort-command "Last Review")
    "; d" (decklet-edit--column-sort-command "Due")
    "; s" (decklet-edit--column-sort-command "Stability")
    "; f" (decklet-edit--column-sort-command "Difficulty")
    "R" #'decklet-edit-rate-card
    "A" #'decklet-edit-archive-card
    "m" #'decklet-edit-mark-at-point
    "u" #'decklet-edit-unmark-at-point
    "U" #'decklet-edit-unmark-all
    "<remap> <tabulated-list-sort>" #'decklet-edit-refresh
    "g" #'decklet-edit-refresh
    "q" #'decklet-edit-quit)
  "Keymap for `decklet-edit-mode'.")

(define-derived-mode decklet-edit-mode tabulated-list-mode "Decklet-Edit"
  "Major mode for listing and editing Decklet cards."
  :interactive nil
  (decklet-db--acquire-session-buffer)
  (setq decklet-edit--marked (make-hash-table :test 'eql))
  (setq tabulated-list-format (decklet-edit--tabulated-list-format))
  (setq tabulated-list-entries #'decklet-edit--entries)
  (setq tabulated-list-printer #'decklet-edit--print-entry)
  (setq tabulated-list-padding 2)
  (tabulated-list-init-header)
  ;; Global, so it is installed only while an edit buffer exists and
  ;; removed by `decklet-edit--on-kill-buffer'.
  (add-hook 'window-selection-change-functions
            #'decklet-edit--flush-pending-refresh)
  (add-hook 'kill-buffer-hook #'decklet-edit--on-kill-buffer nil t))

(provide 'decklet-edit)
;;; decklet-edit.el ends here

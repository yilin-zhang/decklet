;;; decklet-review.el --- Review mode for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Review UI and FSRS grading flow.

;;; Code:

(require 'ansi-color)
(require 'cl-lib)
(require 'seq)

(require 'decklet-core)
(require 'decklet-db)
(require 'decklet-deck)
(require 'decklet-review-log)

(defgroup decklet-review nil
  "Review mode for Decklet."
  :group 'decklet)

;; Parameters

(defcustom decklet-review-daily-goal nil
  "Number of words to review per day.
When nil, disable daily goal tracking and related UI."
  :type '(choice (const :tag "Disable" nil) integer)
  :group 'decklet-review)

(defcustom decklet-review-hint-delay 1.5
  "Delay in seconds before the hint is revealed.
When nil, the hint is shown immediately alongside the word."
  :type '(choice (const :tag "No delay" nil) float)
  :group 'decklet-review)

(defcustom decklet-review-hide-cursor t
  "Whether to hide the cursor in the review buffer."
  :type 'boolean
  :group 'decklet-review)

(defcustom decklet-review-enable-interval-labels t
  "Whether to show projected intervals next to rating options.
When non-nil, review mode shows compact labels such as (10m) for
Again/Hard/Good/Easy based on the current card state and FSRS prediction."
  :type 'boolean
  :group 'decklet-review)

(defcustom decklet-review-hint-indicator "[HINT]"
  "Indicator string used by `decklet-review-component-hint'."
  :type 'string
  :group 'decklet-review)

(defcustom decklet-review-card-back-indicator "♦"
  "Indicator string used by `decklet-review-component-card-back-indicator'."
  :type 'string
  :group 'decklet-review)

;; UI components

(defcustom decklet-review-fixed-components
  '(decklet-review-component-title
    decklet-review-component-separator
    decklet-review-component-counters
    decklet-review-component-separator
    decklet-review-component-daily-goal
    decklet-review-component-separator
    decklet-review-component-rates
    decklet-review-component-separator
    decklet-review-component-linebreak
    decklet-review-component-word
    decklet-review-component-linebreak
    decklet-review-component-separator)
  "Components used for vertical centering and rendered before floating components."
  :type '(repeat function)
  :group 'decklet-review)

(defcustom decklet-review-floating-components
  '(decklet-review-component-linebreak
    decklet-review-component-hint
    decklet-review-component-linebreak
    decklet-review-component-card-back-indicator)
  "Components rendered after the fixed block and excluded from centering."
  :type '(repeat function)
  :group 'decklet-review)

(defcustom decklet-review-daily-goal-progress-steps 50
  "Number of steps used in the daily goal progress bar."
  :type 'integer
  :group 'decklet-review)

(defcustom decklet-review-fill-column 50
  "Column beyond which automatic line-wrapping should happen."
  :type 'integer
  :group 'decklet-review)

;; Faces

(defface decklet-review-word-face
  `((((type graphic))
     :foreground ,(face-attribute 'decklet-color-word :foreground)
     :weight bold
     :height 1.5)
    (((type tty))
     :foreground ,(face-attribute 'decklet-color-word :foreground)
     :weight bold
     :height 1.0))
  "Face for displaying the current word."
  :group 'decklet-review)

(defface decklet-review-state-new-face
  `((((type graphic))
     :foreground ,(face-attribute 'decklet-color-state-new :foreground)
     :weight bold
     :height 1.2)
    (((type tty))
     :foreground ,(face-attribute 'decklet-color-state-new :foreground)
     :weight bold
     :height 1.0))
  "Face for displaying the `NEW WORD' status."
  :group 'decklet-review)

(defface decklet-review-state-learning-face
  `((((type graphic))
     :foreground ,(face-attribute 'decklet-color-state-learning :foreground)
     :weight bold
     :height 1.2)
    (((type tty))
     :foreground ,(face-attribute 'decklet-color-state-learning :foreground)
     :weight bold
     :height 1.0))
  "Face for displaying the `LEARNING' status."
  :group 'decklet-review)

(defface decklet-review-state-review-face
  `((((type graphic))
     :foreground ,(face-attribute 'decklet-color-state-review :foreground)
     :weight bold
     :height 1.2)
    (((type tty))
     :foreground ,(face-attribute 'decklet-color-state-review :foreground)
     :weight bold
     :height 1.0))
  "Face for displaying the `REVIEWING' status."
  :group 'decklet-review)

(defface decklet-review-counter-new-face
  `((t :foreground ,(face-attribute 'decklet-color-state-new :foreground)
       :weight bold
       :underline t))
  "Face for displaying the number of new words."
  :group 'decklet-review)

(defface decklet-review-counter-reviewed-face
  '((t :inherit default
       :weight bold
       :underline t))
  "Face for displaying reviewed numbers."
  :group 'decklet-review)

(defface decklet-review-counter-review-face
  `((t :foreground ,(face-attribute 'decklet-color-state-review :foreground)
       :weight bold
       :underline t))
  "Face for displaying review-due numbers."
  :group 'decklet-review)

(defface decklet-review-counter-due-face
  `((t :foreground ,(face-attribute 'decklet-color-state-learning :foreground)
       :weight bold
       :underline t))
  "Face for displaying learning-due numbers."
  :group 'decklet-review)

(defface decklet-review-state-goal-face
  `((t :foreground ,(face-attribute 'decklet-color-state-review :foreground)
       :weight bold))
  "Face for displaying the `DAILY GOAL REACHED' status."
  :group 'decklet-review)

(defface decklet-review-state-progress-face
  `((t :inherit default))
  "Face for displaying the daily goal progress bar."
  :group 'decklet-review)

(defface decklet-review-rating-interval-face
  `((t :foreground ,(face-attribute 'shadow :foreground)))
  "Face for displaying rating interval hints."
  :group 'decklet-review)

(defface decklet-review-separator-face
  `((t :foreground ,(face-attribute 'shadow :foreground)
       :weight bold))
  "Face for horizontal separators."
  :group 'decklet-review)

(defface decklet-review-hint-indicator-face
  `((t :foreground ,(face-attribute 'decklet-color-hint :foreground)
       :weight bold))
  "Face for displaying the hint placeholder."
  :group 'decklet-review)

(defface decklet-review-card-back-indicator-face
  `((t :foreground ,(face-attribute 'decklet-color-card-back :foreground)
       :weight bold))
  "Face for the card back indicator in the review UI."
  :group 'decklet-review)

(defface decklet-review-undo-highlight-face
  '((t :inherit bold :box t))
  "Face for highlighting the previous rating on an undone card."
  :group 'decklet-review)

;; Hooks

(defcustom decklet-review-start-hook nil
  "Hook run when Decklet review session starts."
  :type 'hook
  :group 'decklet-review)

(defcustom decklet-review-quit-hook nil
  "Hook run when Decklet review quits/cleans up."
  :type 'hook
  :group 'decklet-review)

(defcustom decklet-review-next-card-hook nil
  "Hook run when Decklet switches to the next word."
  :type 'hook
  :group 'decklet-review)

(defcustom decklet-review-daily-goal-reached-hook nil
  "Hook run once when the daily goal is reached."
  :type 'hook
  :group 'decklet-review)

;; Internal

(defvar decklet-review-buffer-name "*Decklet Review*"
  "Name of the buffer used for reviews.")

(defvar decklet-review--separator-width 0
  "Current separator width used by `decklet-review-component-separator'.")

(defvar decklet-review--state-display-hint nil
  "UI state: display hint.")

(defvar decklet-review--hint-timer nil
  "Delay timer for hint display.")

(defvar decklet-review--render-meta nil
  "Card meta for the current word; bound for the duration of a render cycle.")

(defvar decklet-review--render-word nil
  "Word for the current render cycle.")

(defvar decklet-review--render-has-back nil
  "Non-nil when the current word has a card back; bound during a render cycle.")

(defvar decklet-review--render-hint nil
  "Hint text for the current word; bound for the duration of a render cycle.
Scoped to `decklet-review--render-buffer' so both the component and the
post-render hint-timer decision share the same value.")

(defvar decklet-review--trail-past nil
  "Completed trail entries, most-recent first.
Each entry is a plist (:card-id :grade :pre-meta :log-id).
During normal forward review every rated or skipped card pushes
onto this list.  Undo migrates entries onto
`decklet-review--trail-future' one at a time.")

(defvar decklet-review--trail-future nil
  "Entries currently being revisited, head-first.
Non-empty iff an undo is in progress; the head is the card on
screen.  Advancing (next-card or re-rating) moves the head back
onto `decklet-review--trail-past'.")

(defvar decklet-review-mode-map
  (define-keymap
    "1" #'decklet-review-rate-again
    "2" #'decklet-review-rate-hard
    "3" #'decklet-review-rate-good
    "4" #'decklet-review-rate-easy
    "q" #'decklet-review-quit
    "n" #'decklet-review-next-card
    "g" #'decklet-review-refresh
    "D" #'decklet-review-delete-card
    "e" #'decklet-review-set-word
    "t" #'decklet-review-set-hint
    "u" #'decklet-review-undo
    "b" #'decklet-review-show-card-back)
  "Keymap for `decklet-review-mode'.")

;; Format helpers

(defun decklet--string-max-line-width (text)
  "Return the maximum line width for TEXT."
  (let ((max-width 0))
    (dolist (line (split-string text "\n") max-width)
      ;; Strip left padding so separators match the real content width.
      (let ((width (string-width (string-trim-left line))))
        (setq max-width (max max-width width))))))

(defun decklet--string-pixel-size (text)
  "Return the pixel (WIDTH . HEIGHT) of TEXT in the current buffer context."
  (let ((remap face-remapping-alist)
        (buffer-face (and (boundp 'buffer-face-mode-face)
                          buffer-face-mode-face)))
    (with-temp-buffer
      (let ((face-remapping-alist remap)
            (inhibit-modification-hooks t))
        (when (boundp 'buffer-face-mode-face)
          (setq buffer-face-mode-face buffer-face))
        (insert text)
        (buffer-text-pixel-size (current-buffer))))))

(defun decklet--center-padding (lines)
  "Return a padding string to center LINES as a block in the window.
The lines in the block are left-aligned within the centered block."
  (let* ((graphic-p (display-graphic-p))
         ;; Get the available width (pixels for GUI, columns for terminal)
         (body-width (if graphic-p
                         (let ((edges (window-inside-pixel-edges)))
                           (- (nth 2 edges) (nth 0 edges)))
                       (window-body-width)))
         ;; Find the widest line (in pixels or columns)
         (max-line-width
          (apply #'max
                 (mapcar
                  (if graphic-p
                      (lambda (text)
                        (car (decklet--string-pixel-size text)))
                    #'string-width)
                  lines)))
         ;; Calculate padding needed to center the block
         (padding (max 0 (/ (- body-width max-line-width) 2))))
    ;; Return appropriate padding format
    (if graphic-p
        ;; GUI: use pixel space specification
        (propertize " " 'display `(space :width (,padding)))
      ;; Terminal: use actual spaces
      (make-string padding ?\s))))

(defun decklet-center-text (text)
  "Center TEXT in the current window width.
Multi-line text is centered as a block, not per-line."
  (let* ((lines (split-string text "\n"))
         (padding (decklet--center-padding lines)))
    (mapconcat (lambda (line)
                 (concat padding line))
               lines
               "\n")))

(defun decklet-fill-and-center-text (text width)
  "Wrap TEXT to WIDTH and center each wrapped line as a block."
  (let ((lines (string-split text "\n")))
    (string-join (mapcar (lambda (line)
                           (decklet-center-text
                            (string-fill (string-trim line) width)))
                         lines)
                 "\n")))

(defun decklet--format-interval (seconds)
  "Return a human readable string for SECONDS."
  (cond
   ((< seconds 60) "<1m")
   ((< seconds 3600) (format "%dm" (floor (/ seconds 60))))
   ((< seconds 86400) (format "%dh" (floor (/ seconds 3600))))
   ((< seconds 2592000) (format "%dd" (floor (/ seconds 86400))))
   ((< seconds 31536000) (format "%dM" (floor (/ seconds 2592000))))
   (t (format "%dy" (floor (/ seconds 31536000))))))

;; Buffer rendering

(defun decklet-review--collect-component-items (components &optional last-was-sep)
  "Return (ITEMS . LAST-WAS-SEP) for COMPONENTS.
ITEMS contains (TEXT . SEPARATOR) pairs.  Separator functions are not called;
a placeholder is stored in TEXT for later replacement.  Leading or consecutive
separators are skipped so rendering won't stack separator lines."
  (let (items)
    (dolist (fn components)
      (if (eq fn 'decklet-review-component-separator)
          (unless (or last-was-sep (null items))
            (push (cons "" t) items)
            (setq last-was-sep t))
        (when-let* ((text (funcall fn)))
          (push (cons text nil) items)
          (setq last-was-sep nil))))
    (cons (nreverse items) last-was-sep)))

(defun decklet-review--render-component-items (items)
  "Render ITEMS into a single string with trailing newlines."
  (concat (string-join (mapcar #'car items) "\n") "\n"))

(defun decklet-review--render-with-vertical-center (fixed-items floating-items)
  "Render FIXED-ITEMS and FLOATING-ITEMS with vertical centering."
  (let* ((fixed-text (decklet-review--render-component-items fixed-items))
         (floating-text (decklet-review--render-component-items floating-items)))
    (if (display-graphic-p)
        ;; In GUI, center using pixel measurements for more accurate alignment.
        (let* ((measure-text (string-trim-right fixed-text "\n+"))
               (fixed-h (cdr (decklet--string-pixel-size measure-text)))
               (half-body-h (/ (window-body-height nil t) 2))
               (padding-pixels (max 0 (- half-body-h fixed-h)))
               (padding (if (> padding-pixels 0)
                            (concat (propertize " " 'display `(space :height (,padding-pixels)))
                                    "\n")
                          "")))
          (concat padding fixed-text floating-text))
      ;; In TTY, fall back to line counts for centering.
      (let* ((line-count (length (split-string fixed-text "\n" t)))
             (half-body-h (floor (window-body-height) 2))
             (top-n-lines (max 0 (- half-body-h line-count))))
        (concat (make-string top-n-lines ?\n) fixed-text floating-text)))))

(defun decklet-review--render-components ()
  "Render fixed and floating components with vertical centering for fixed ones."
  ;; Collect items in a single pass; separators are recorded as placeholders.
  (let* ((fixed-result (decklet-review--collect-component-items decklet-review-fixed-components))
         (fixed-items (car fixed-result))
         (last-was-sep (cdr fixed-result))
         (floating-result (decklet-review--collect-component-items decklet-review-floating-components last-was-sep))
         (floating-items (car floating-result))
         (all-items (append fixed-items floating-items))
         ;; Compute separator width from non-separator content.
         (content-texts (mapcar #'car (seq-remove #'cdr all-items))))
    (if (null content-texts)
        ""
      (setq decklet-review--separator-width
            (seq-reduce
             #'max
             (mapcar #'decklet--string-max-line-width content-texts)
             0))
      ;; Replace separator placeholders with actual separator strings.
      (let ((sep-text (decklet-center-text
                       (decklet-review--separator decklet-review--separator-width))))
        (dolist (item all-items)
          (when (cdr item)
            (setcar item sep-text))))
      (decklet-review--render-with-vertical-center fixed-items floating-items))))

(defun decklet-review--setup-buffer ()
  "Set up the review buffer."
  (let ((buffer (get-buffer-create decklet-review-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (unless (derived-mode-p 'decklet-review-mode)
          (decklet-review-mode))))
    buffer))

(defun decklet-review--hint-delay-enabled-p ()
  "Return non-nil when hint delay is enabled.
Hint delay is enabled when `decklet-review-hint-delay' is a positive number."
  (and decklet-review-hint-delay (> decklet-review-hint-delay 0)))

(defun decklet-review--reset-ui-state ()
  "Reset UI state."
  (decklet-review--cancel-hint-timer)
  (setq decklet-review--state-display-hint
        (not (decklet-review--hint-delay-enabled-p))))

(defun decklet-review--clean-up ()
  "Clear transient review session state."
  (setq decklet-current-card-id nil)
  (setq decklet-last-added-word nil)
  (setq decklet-due-card-ids nil)
  (decklet-review--trail-reset)
  (decklet-review--reset-ui-state))

(defun decklet-review--refresh-visible (&rest _args)
  "Refresh the review buffer if it is visible in a window."
  (when-let* ((window (get-buffer-window decklet-review-buffer-name 'visible)))
    (with-current-buffer (window-buffer window)
      (when (eq major-mode 'decklet-review-mode)
        (decklet-review--render-buffer t)))))

(defun decklet-review--enable-resize-refresh ()
  "Enable refresh hooks for resize and text scaling."
  (add-hook 'window-size-change-functions #'decklet-review--refresh-visible)
  (unless (advice-member-p #'decklet-review--refresh-visible 'text-scale-adjust)
    (advice-add 'text-scale-adjust :after #'decklet-review--refresh-visible))
  (unless (advice-member-p #'decklet-review--refresh-visible 'text-scale-set)
    (advice-add 'text-scale-set :after #'decklet-review--refresh-visible)))

(defun decklet-review--disable-resize-refresh ()
  "Disable refresh hooks for resize and text scaling."
  (remove-hook 'window-size-change-functions #'decklet-review--refresh-visible)
  (advice-remove 'text-scale-adjust #'decklet-review--refresh-visible)
  (advice-remove 'text-scale-set #'decklet-review--refresh-visible))

(defun decklet-review--daily-goal-reached-p ()
  "Check if the daily review goal has been reached."
  (when decklet-review-daily-goal
    (or (>= (plist-get decklet--counter :reviewed)
            decklet-review-daily-goal)
        (and (<= (+ (plist-get decklet--counter :due-review)
                    (plist-get decklet--counter :due-learning))
                 0)
             (<= (plist-get decklet--counter :new) 0)))))

(defun decklet-review--cancel-hint-timer ()
  "Cancel `decklet-review--hint-timer'."
  (when decklet-review--hint-timer
    (cancel-timer decklet-review--hint-timer)
    (setq decklet-review--hint-timer nil)))

(defun decklet-review--start-hint-timer ()
  "Start `decklet-review--hint-timer'."
  (when (and (not decklet-review--hint-timer)
             (decklet-review--hint-delay-enabled-p))
    (setq decklet-review--hint-timer
          (run-at-time decklet-review-hint-delay
                       nil
                       (lambda ()
                         (setq decklet-review--state-display-hint t)
                         (decklet-review--render-buffer t))))))

(defun decklet-review--instruction-key-label (command)
  "Return a key label for COMMAND from `decklet-review-mode-map'."
  (if (where-is-internal command (list decklet-review-mode-map))
      (substitute-command-keys
       (format "\\<decklet-review-mode-map>\\[%s]" command))
    ""))

(defun decklet-review--instruction-interval-label (meta grade)
  "Return a propertized interval label for card META at GRADE.
When `decklet-review-enable-interval-labels' is nil, return an empty string.
Otherwise, simulate one FSRS review with GRADE and format the predicted
interval as a compact label, for example (10m)."
  (if (not decklet-review-enable-interval-labels)
      ""
    (propertize
     (format " (%s)"
             (decklet--format-interval
              (decklet--simulate-review-interval meta grade)))
     'face 'decklet-review-rating-interval-face)))

(defun decklet-review--separator (&optional length)
  "Return the styled separator line for instruction blocks.
When LENGTH is non-nil, use it as the separator width."
  (propertize (make-string (or length 49) ?─)
              'face 'decklet-review-separator-face))

(defun decklet-review-component-title ()
  "Return the centered title line for the review header."
  (decklet-center-text
   (pcase (decklet-card-meta-effective-state decklet-review--render-meta)
     (:new
      (propertize "NEW WORD" 'face 'decklet-review-state-new-face))
     ((or :learning :relearning)
      (propertize "LEARNING" 'face 'decklet-review-state-learning-face))
     (_
      (propertize "REVIEWING" 'face 'decklet-review-state-review-face)))))

(defun decklet-review-component-counters ()
  "Return the counter block for the instructions."
  (let* ((n-reviewed (plist-get decklet--counter :reviewed))
         (n-due-review (plist-get decklet--counter :due-review))
         (n-due-learning (plist-get decklet--counter :due-learning))
         (n-new (plist-get decklet--counter :new)))
    (decklet-center-text
     (format "%s reviewed / %s review due / %s learning due / %s new"
             (propertize (number-to-string n-reviewed)
                         'face 'decklet-review-counter-reviewed-face)
             (propertize (number-to-string n-due-review) 'face 'decklet-review-counter-review-face)
             (propertize (number-to-string n-due-learning) 'face 'decklet-review-counter-due-face)
             (propertize (number-to-string n-new) 'face 'decklet-review-counter-new-face)))))

(defun decklet-review-component-daily-goal ()
  "Insert the daily goal banner in the review buffer."
  (when (and decklet-review-daily-goal (> decklet-review-daily-goal 0))
    (if (decklet-review--daily-goal-reached-p)
        (decklet-center-text (propertize "DAILY GOAL REACHED" 'face 'decklet-review-state-goal-face))
      (let* ((n-reviewed (plist-get decklet--counter :reviewed))
             (goal-progress (/ (float n-reviewed) decklet-review-daily-goal))
             (steps (max 0 decklet-review-daily-goal-progress-steps))
             (n-clicks-completed (decklet--clamp (round (* goal-progress steps)) 0 steps))
             (percentage (format "%.2f%%" (* 100 goal-progress)))
             (progress-bar (concat
                            (make-string n-clicks-completed ?█)
                            (make-string (- steps n-clicks-completed) ?░))))
        (concat
         (decklet-center-text (propertize percentage 'face 'decklet-review-state-progress-face))
         "\n"
         (decklet-center-text (propertize progress-bar 'face 'decklet-review-state-progress-face)))))))

(defun decklet-review--make-rating-option (command label meta grade undo-grade)
  "Build a single rating option string for COMMAND with LABEL.
META and GRADE are used for interval prediction.  When UNDO-GRADE matches
GRADE, apply `decklet-review-undo-highlight-face' to the LABEL text only."
  (let* ((highlight (and undo-grade (= undo-grade grade)))
         (styled-label (if highlight
                           (propertize label 'face 'decklet-review-undo-highlight-face)
                         label)))
    (concat (decklet-review--instruction-key-label command)
            " " styled-label
            (decklet-review--instruction-interval-label meta grade))))

(defun decklet-review-component-rates ()
  "Return the options block for review ratings and commands.
Interval labels are included when
`decklet-review-enable-interval-labels' is non-nil.
When reviewing an undone card, the previous rating is highlighted."
  (let* ((meta decklet-review--render-meta)
         (undo-entry (decklet-review--trail-current-entry))
         (undo-grade (and undo-entry (plist-get undo-entry :grade)))
         (option-lines
          (list
           (decklet-review--make-rating-option
            'decklet-review-rate-again "Again" meta 1 undo-grade)
           (decklet-review--make-rating-option
            'decklet-review-rate-hard "Hard" meta 2 undo-grade)
           (decklet-review--make-rating-option
            'decklet-review-rate-good "Good" meta 3 undo-grade)
           (decklet-review--make-rating-option
            'decklet-review-rate-easy "Easy" meta 4 undo-grade))))
    (decklet-center-text (string-join option-lines "   "))))

(defun decklet-review-component-separator ()
  "Return the separator line for the review components."
  (when (> decklet-review--separator-width 0)
    (decklet-center-text
     (decklet-review--separator decklet-review--separator-width))))

(defun decklet-review-component-linebreak ()
  "Return an empty component that is kept to force a blank line."
  "")

(defun decklet-review-component-word ()
  "Insert the current word in the review buffer."
  (let ((word (propertize decklet-review--render-word 'face 'decklet-review-word-face)))
    (decklet-center-text word)))

(defun decklet-review-component-hint ()
  "Insert the current word's hint in the review buffer."
  (when decklet-review--render-hint
    (if decklet-review--state-display-hint
        (decklet-fill-and-center-text decklet-review--render-hint decklet-review-fill-column)
      (decklet-center-text
       (propertize decklet-review-hint-indicator 'face 'decklet-review-hint-indicator-face)))))

(defun decklet-review-component-card-back-indicator ()
  "Return a centered card back indicator when the current card has a back."
  (when decklet-review--render-has-back
    (decklet-center-text
     (propertize decklet-review-card-back-indicator 'face 'decklet-review-card-back-indicator-face))))

(defun decklet-review--hide-cursor ()
  "Hide the cursor and hl-line in the review buffer window."
  (when (eq major-mode 'decklet-review-mode)
    ;; Hide cursor
    (setq-local cursor-type nil)
    ;; Disable hl-line-mode for a cleaner UI
    (when (boundp 'hl-line-mode)
      (hl-line-mode -1))
    (when (boundp 'global-hl-line-mode)
      (setq-local global-hl-line-mode nil))))

(defun decklet-review--render-buffer (&optional keep-position)
  "Render the review buffer.
When KEEP-POSITION is non-nil, preserve the window scroll and point."
  (with-current-buffer (get-buffer decklet-review-buffer-name)
    (when decklet-review-hide-cursor
      (decklet-review--hide-cursor))
    (pcase-let* ((card-full (and decklet-current-card-id
                                 (decklet-get-card decklet-current-card-id)))
                 ((map (:word decklet-review--render-word)
                       (:meta decklet-review--render-meta)
                       (:back decklet-review--render-has-back)
                       (:hint decklet-review--render-hint))
                  card-full)
                 (window (get-buffer-window (current-buffer) 0))
                 (saved-point (when (and keep-position window) (window-point window)))
                 (saved-start (when (and keep-position window) (window-start window)))
                 (render (lambda ()
                           (let ((inhibit-read-only t))
                             (erase-buffer)
                             (insert (decklet-review--render-components))))))
      ;; Render using the review window so centering uses its dimensions.
      (if window
          (with-selected-window window (funcall render))
        (funcall render))
      (if decklet-review--render-hint
          (decklet-review--start-hint-timer)
        (decklet-review--cancel-hint-timer))
      (if (and keep-position window)
          (progn
            (set-window-point window (min saved-point (point-max)))
            (set-window-start window saved-start t))
        (goto-char (point-min))))))

;; Review flow and rating commands

(defun decklet-review--trail-reset ()
  "Clear both sides of the trail."
  (setq decklet-review--trail-past nil
        decklet-review--trail-future nil))

(defun decklet-review--undo-in-progress-p ()
  "Return non-nil when review is in undo state."
  (not (null decklet-review--trail-future)))

(defun decklet-review--trail-current-entry ()
  "Return the entry currently being revisited during undo, or nil."
  (car decklet-review--trail-future))

(defun decklet-review--trail-append (entry)
  "Record ENTRY as a completed forward step.
Callers must be in forward-flow state (future empty)."
  (push entry decklet-review--trail-past))

(defun decklet-review--trail-update-and-advance (grade)
  "Update the currently undone entry with GRADE and move it onto past."
  (let ((entry (car decklet-review--trail-future)))
    (plist-put entry :grade grade)
    (push (pop decklet-review--trail-future) decklet-review--trail-past)))

(defun decklet-review--trail-delete (card-id)
  "Remove entries for CARD-ID from both sides of the trail."
  (let ((keep (lambda (e) (not (eql (plist-get e :card-id) card-id)))))
    (setq decklet-review--trail-past (seq-filter keep decklet-review--trail-past)
          decklet-review--trail-future (seq-filter keep decklet-review--trail-future))))

(defun decklet-review--present-card (card-id)
  "Set CARD-ID as the current card and render the review buffer."
  (setq decklet-current-card-id card-id)
  (decklet-review--reset-ui-state)
  (run-hooks 'decklet-review-next-card-hook)
  (decklet-review--render-buffer))

(defun decklet-review--trail-skip ()
  "Append a skip entry for the current card to the trail."
  (when decklet-current-card-id
    (when-let* ((meta (decklet-get-card-meta decklet-current-card-id)))
      (decklet-review--trail-append
       (list :card-id decklet-current-card-id
             :grade nil
             :pre-meta (copy-decklet-card-meta meta))))))

(defun decklet-review--advance ()
  "Show the next card from the trail or the due queue, or quit."
  (if (decklet-review--undo-in-progress-p)
      (decklet-review--present-card
       (plist-get (decklet-review--trail-current-entry) :card-id))
    (progn
      (unless decklet-due-card-ids
        (decklet--refresh-due-card-ids))
      (if decklet-due-card-ids
          (decklet-review--present-card (pop decklet-due-card-ids))
        (decklet-review-quit)))))

(defun decklet-review-next-card ()
  "Review the next due card.
When in undo state, confirm the current undone card and advance.
When current list is empty, re-check for due cards and continue if any exist."
  (interactive)
  (cond
   ((decklet-review--undo-in-progress-p)
    ;; Confirm the undone card: move its entry back onto the past side.
    (push (pop decklet-review--trail-future) decklet-review--trail-past)
    (decklet-review--advance))
   (t
    (decklet-review--trail-skip)
    (decklet-review--advance))))

(defun decklet-review--on-kill-buffer ()
  "Cleanup handler for the review buffer's `kill-buffer-hook'.
Runs whether the session is ended via `decklet-review-quit' or by
killing the buffer directly (e.g. `C-x k'), so the two code paths
always leave the same amount of state behind."
  (decklet-review--clean-up)
  (run-hooks 'decklet-review-quit-hook)
  ;; Pass (current-buffer) so the still-alive review buffer — we are
  ;; inside its `kill-buffer-hook' — is not counted as an open session.
  (decklet-db--disconnect-if-idle (current-buffer)))

(defun decklet-review-quit ()
  "Quit Decklet review."
  (interactive)
  (when-let* ((buffer (get-buffer decklet-review-buffer-name)))
    (kill-buffer buffer))
  (message "Review session finished"))

(defun decklet-review--handle-grade (grade)
  "Handle a GRADE input and move on to the next card."
  (let* ((card-id (decklet--require-current-card-id "rate"))
         (row (decklet-db--require-card-row card-id))
         (word (plist-get row :word))
         (goal-was-reached (decklet-review--daily-goal-reached-p)))
    (if (decklet-review--undo-in-progress-p)
        ;; Re-rate: restore pre-meta so FSRS computes from the
        ;; correct base state, then rate and update the entry.  Also
        ;; void the prior review-log entry so the log cleanly reflects
        ;; the user's final intent rather than both the typo and the
        ;; correction.
        (let* ((entry (decklet-review--trail-current-entry))
               (pre-meta (plist-get entry :pre-meta))
               (prior-grade (plist-get entry :grade))
               (prior-log-id (plist-get entry :log-id)))
          (decklet-db--upsert-card word pre-meta)
          (when prior-log-id
            (decklet-review-log-append-void prior-log-id))
          (let ((new-log-id (decklet--rate-card-state
                             card-id word pre-meta grade prior-grade)))
            (plist-put entry :log-id new-log-id))
          (decklet-review--trail-update-and-advance grade))
      ;; Normal forward rating: snapshot pre-meta, rate, append.
      (let* ((old-meta (decklet-db--row->card-meta row))
             (pre-meta (copy-decklet-card-meta old-meta))
             (new-log-id (decklet--rate-card-state card-id word old-meta grade)))
        (decklet-review--trail-append
         (list :card-id card-id :grade grade :pre-meta pre-meta :log-id new-log-id))))
    (when (and (not goal-was-reached)
               (decklet-review--daily-goal-reached-p))
      (run-hooks 'decklet-review-daily-goal-reached-hook))
    (message "Rated \"%s\" as (%s)" word
             (pcase grade (1 "Again") (2 "Hard") (3 "Good") (4 "Easy")))
    ;; Advance to the next card.  Do not go through `next-card' since
    ;; that would record a spurious skip on the trail for the word we just rated.
    (decklet-review--advance)))

(defun decklet-review-undo ()
  "Go back to the previous card and redisplay it.
Does not revert DB state — the original rating remains in the
database until the user re-rates."
  (interactive)
  (if (null decklet-review--trail-past)
      (message "Nothing to undo")
    ;; When undoing from normal flow, the current card hasn't been
    ;; recorded on the trail — push it back onto the due queue so
    ;; advancing past the undo revisits it.  When already in undo
    ;; state, the current card is on the future side and reappears
    ;; on its own.
    (when (and (not (decklet-review--undo-in-progress-p))
               decklet-current-card-id)
      (push decklet-current-card-id decklet-due-card-ids))
    (push (pop decklet-review--trail-past) decklet-review--trail-future)
    (let* ((entry (decklet-review--trail-current-entry))
           (card-id (plist-get entry :card-id))
           (word (decklet-card-word card-id)))
      (if (not (decklet-card-exists-p card-id))
          (progn
            (message "Card \"%s\" no longer exists, undo skipped" word)
            (decklet-review-undo))
        (decklet-review--present-card card-id)))))

(defun decklet-review-rate-again ()
  "Rate the current word as `again'."
  (interactive)
  (decklet-review--handle-grade 1))

(defun decklet-review-rate-hard ()
  "Rate the current word as `hard'."
  (interactive)
  (decklet-review--handle-grade 2))

(defun decklet-review-rate-good ()
  "Rate the current word as `good'."
  (interactive)
  (decklet-review--handle-grade 3))

(defun decklet-review-rate-easy ()
  "Rate the current word as `easy'."
  (interactive)
  (decklet-review--handle-grade 4))

(defun decklet-review-refresh ()
  "Refresh the review window."
  (interactive)
  (when decklet-current-card-id
    (let ((buffer (decklet-review--setup-buffer)))
      (switch-to-buffer buffer)
      (decklet-review--render-buffer))))

(defun decklet-review--set-card-fields (set-word set-hint)
  "Set the current card using SET-WORD and SET-HINT flags."
  (let* ((card-id (decklet--require-current-card-id "edit"))
         (updated-word (decklet-prompt-set-card-fields card-id set-word set-hint)))
    (when (eq major-mode 'decklet-review-mode)
      (decklet-review--render-buffer))
    (message "Updated \"%s\"" updated-word)))

(defun decklet-review-set-word ()
  "Set the current word."
  (interactive)
  (decklet-review--set-card-fields t nil))

(defun decklet-review-set-hint ()
  "Set the current hint."
  (interactive)
  (decklet-review--set-card-fields nil t))

(defun decklet-review-delete-card ()
  "Delete the current card from the deck."
  (interactive)
  (let* ((card-id (decklet--require-current-card-id "delete"))
         (word (decklet-card-word card-id)))
    (when (yes-or-no-p (format "Are you sure you want to delete \"%s\" from the deck? " word))
      (decklet-delete-card card-id)
      (message "Deleted \"%s\" from the deck." word)
      (when (eq major-mode 'decklet-review-mode)
        (decklet-review--advance)))))

(defun decklet-review-show-card-back ()
  "Show the card back for the current word in a read-only popup."
  (interactive)
  (let* ((card-id (decklet--require-current-card-id "show card back for"))
         (word (decklet-card-word card-id)))
    (decklet-card-back-show word)))

;; Review mode setup

;;;###autoload
(defun decklet-review ()
  "Start a review session."
  (interactive)
  (run-hooks 'decklet-review-start-hook)
  (decklet-review--trail-reset)
  (decklet--refresh-due-card-ids)
  (if (null decklet-due-card-ids)
      (progn
        (decklet-review-quit)
        (message "No words to review"))
    (let ((buffer (decklet-review--setup-buffer)))
      (switch-to-buffer buffer)
      (decklet--refresh-counter)
      (decklet-review-next-card))))

;; Backup
(add-hook 'decklet-review-start-hook #'decklet-db-backup)
(add-hook 'decklet-review-quit-hook #'decklet-db-backup)
;; Auto-refresh
(add-hook 'decklet-review-start-hook #'decklet-review--enable-resize-refresh)
(add-hook 'decklet-review-quit-hook #'decklet-review--disable-resize-refresh)

;; Refresh the visible review buffer whenever the current card changes.
;; Used for both field updates (hint / back / extension-owned fields)
;; and word renames — in both cases the review UI needs to re-render if
;; the affected card is on screen.
(defun decklet-review--on-current-card-changed (events)
  "Refresh the visible review buffer when the current card is in EVENTS."
  (when (cl-some (lambda (ev) (eql (plist-get ev :card-id)
                                   decklet-current-card-id))
                 events)
    (decklet-review--refresh-visible)))

(add-hook 'decklet-cards-field-updated-functions
          #'decklet-review--on-current-card-changed)
(add-hook 'decklet-cards-renamed-functions
          #'decklet-review--on-current-card-changed)

(add-hook 'decklet-cards-deleted-functions
          (lambda (events)
            (dolist (event events)
              (decklet-review--trail-delete (plist-get event :card-id)))))

(define-derived-mode decklet-review-mode special-mode "Decklet-Review"
  "Major mode for reviewing vocabulary with FSRS algorithm."
  (setq buffer-read-only t)
  (buffer-disable-undo)
  (add-hook 'kill-buffer-hook #'decklet-review--on-kill-buffer nil t))

(provide 'decklet-review)
;;; decklet-review.el ends here

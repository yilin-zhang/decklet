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
  "Delay time in seconds for hint display."
  :type 'float
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
  '((((type graphic))
     :inherit decklet-word-face
     :height 1.5)
    (((type tty))
     :inherit decklet-word-face
     :height 1.0))
  "Face for displaying the current word."
  :group 'decklet-review)

(defface decklet-review-state-new-face
  '((((type graphic))
     :inherit decklet-state-new-face
     :height 1.2)
    (((type tty))
     :inherit decklet-state-new-face
     :height 1.0))
  "Face for displaying the `NEW WORD' status."
  :group 'decklet-review)

(defface decklet-review-state-learning-face
  '((((type graphic))
     :inherit decklet-state-learning-face
     :height 1.2)
    (((type tty))
     :inherit decklet-state-learning-face
     :height 1.0))
  "Face for displaying the `LEARNING' status."
  :group 'decklet-review)

(defface decklet-review-state-review-face
  '((((type graphic))
     :inherit decklet-state-review-face
     :height 1.2)
    (((type tty))
     :inherit decklet-state-review-face
     :height 1.0))
  "Face for displaying the `REVIEWING' status."
  :group 'decklet-review)

(defface decklet-review-counter-new-face
  '((t :inherit decklet-state-new-face
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
  '((t :inherit decklet-state-review-face
       :underline t))
  "Face for displaying review-due numbers."
  :group 'decklet-review)

(defface decklet-review-counter-due-face
  '((t :inherit decklet-state-learning-face
       :underline t))
  "Face for displaying learning-due numbers."
  :group 'decklet-review)

(defface decklet-review-state-goal-face
  `((t :foreground ,(face-attribute 'ansi-color-green :foreground)
       :weight bold))
  "Face for displaying the `DAILY GOAL REACHED' status."
  :group 'decklet-review)

(defface decklet-review-state-progress-face
  `((t :inherit default))
  "Face for displaying the daily goal progress bar."
  :group 'decklet-review)

(defface decklet-review-hint-placeholder-face
  `((t :inherit shadow :weight bold))
  "Face for displaying the hint placeholder."
  :group 'decklet-review)

(defface decklet-review-rating-interval-face
  `((t :inherit shadow))
  "Face for displaying rating interval hints."
  :group 'decklet-review)

(defface decklet-review-separator-face
  `((t :inherit shadow :weight bold))
  "Face for horizontal separators."
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

(defvar decklet-review--render-has-back nil
  "Non-nil when the current word has a card back; bound during a render cycle.")

(defvar decklet-review--render-hint nil
  "Hint text for the current word; bound for the duration of a render cycle.
Scoped to `decklet-review--render-buffer' so both the component and the
post-render hint-timer decision share the same value.")

(defvar decklet-review--trail nil
  "List of trail entries for the current review session.
Each entry is a plist (:word :grade :pre-meta).")

(defvar decklet-review--trail-pointer 0
  "Index into `decklet-review--trail'.
Equal to the trail length during normal forward review.
Less than the trail length when the user has undone cards.")

;; Bring the definition up because it will be used by other functions down below.
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
    "e" #'decklet-review-edit-word
    "t" #'decklet-review-edit-hint
    "u" #'decklet-review-undo
    "b" #'decklet-review-show-card-back
    "B" #'decklet-review-edit-card-back)
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
        (when-let ((text (funcall fn)))
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
  (and (numberp decklet-review-hint-delay) (> decklet-review-hint-delay 0)))

(defun decklet-review--reset-ui-state ()
  "Reset UI state."
  (decklet-review--cancel-hint-timer)
  (setq decklet-review--state-display-hint
        (not (decklet-review--hint-delay-enabled-p))))

(defun decklet-review--clean-up ()
  "Clear transient review session state."
  (setq decklet-current-word nil)
  (setq decklet-last-added-word nil)
  (setq decklet-due-words nil)
  (decklet-review--trail-reset)
  (decklet-review--reset-ui-state))

(defun decklet-review--refresh-visible (&rest _args)
  "Refresh the review buffer if it is visible in a window."
  (when-let ((window (get-buffer-window decklet-review-buffer-name 'visible)))
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

(defun decklet-review--instruction-interval-label (word meta grade)
  "Return a propertized interval label for WORD with META at GRADE.
When `decklet-review-enable-interval-labels' is nil, return an empty string.
Otherwise, simulate one FSRS review with GRADE and format the predicted
interval as a compact label, for example (10m)."
  (if (not decklet-review-enable-interval-labels)
      ""
    (propertize
     (format " (%s)"
             (decklet--format-interval
              (decklet--simulate-review-interval word meta grade)))
     'face 'decklet-review-rating-interval-face)))

(defun decklet-review--separator (&optional length)
  "Return the styled separator line for instruction blocks.
When LENGTH is non-nil, use it as the separator width."
  (propertize (make-string (or length 49) ?─)
              'face 'decklet-review-separator-face))

(defun decklet-review-component-title ()
  "Return the centered title line for the review header."
  (decklet-center-text
   (pcase (decklet-card-meta-display-state decklet-review--render-meta)
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
            (decklet-review--instruction-interval-label
             decklet-current-word meta grade))))

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
  (let ((word (propertize decklet-current-word 'face 'decklet-review-word-face)))
    (decklet-center-text word)))

(defun decklet-review-component-hint ()
  "Insert the current word's hint in the review buffer."
  (when decklet-review--render-hint
    (if decklet-review--state-display-hint
        (decklet-fill-and-center-text decklet-review--render-hint decklet-review-fill-column)
      (decklet-center-text
       (propertize "[HINT]" 'face 'decklet-review-hint-placeholder-face)))))

(defun decklet-review-component-card-back-indicator ()
  "Return a centered [BACK] indicator when the current card has a back."
  (when decklet-review--render-has-back
    (decklet-center-text
     (propertize "[BACK]" 'face 'decklet-card-back-indicator-face))))

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
    (let* ((card-full (and decklet-current-word
                          (decklet--load-card-full decklet-current-word)))
           (decklet-review--render-meta (plist-get card-full :meta))
           (decklet-review--render-has-back (plist-get card-full :back))
           (decklet-review--render-hint (plist-get card-full :hint))
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
            (set-window-point window (min (or saved-point (point-min)) (point-max)))
            (when saved-start
              (set-window-start window saved-start t)))
        (goto-char (point-min))))))

;; Review flow and rating commands

(defun decklet-review--trail-reset ()
  "Clear the trail and pointer."
  (setq decklet-review--trail nil)
  (setq decklet-review--trail-pointer 0))

(defun decklet-review--undo-in-progress-p ()
  "Return non-nil when review is in undo state."
  (and decklet-review--trail
       (< decklet-review--trail-pointer (length decklet-review--trail))))

(defun decklet-review--trail-current-entry ()
  "Return the trail entry at the current pointer, or nil."
  (when (decklet-review--undo-in-progress-p)
    (nth decklet-review--trail-pointer decklet-review--trail)))

(defun decklet-review--trail-can-retreat-p ()
  "Return non-nil when the pointer can move backward."
  (and decklet-review--trail
       (> decklet-review--trail-pointer 0)))

(defun decklet-review--trail-advance-pointer ()
  "Move the pointer forward by one position."
  (setq decklet-review--trail-pointer
        (1+ decklet-review--trail-pointer)))

(defun decklet-review--trail-retreat-pointer ()
  "Move the pointer backward by one position."
  (setq decklet-review--trail-pointer
        (1- decklet-review--trail-pointer)))

(defun decklet-review--trail-append (entry)
  "Append ENTRY to the trail."
  (setq decklet-review--trail
        (nconc decklet-review--trail (list entry)))
  (setq decklet-review--trail-pointer (length decklet-review--trail)))

(defun decklet-review--trail-update-entry (grade)
  "Update the current undone entry with GRADE, then advance."
  (let ((entry (decklet-review--trail-current-entry)))
    (plist-put entry :grade grade)
    (decklet-review--trail-advance-pointer)))

(defun decklet-review--trail-rename (old-word new-word)
  "Update `:word' entries in the trail from OLD-WORD to NEW-WORD."
  (dolist (entry decklet-review--trail)
    (when (string-equal (plist-get entry :word) old-word)
      (plist-put entry :word new-word))))

(defun decklet-review--trail-delete (word)
  "Remove entries for WORD from the trail and adjust the pointer."
  (when decklet-review--trail
    (let ((removed-before-pointer 0)
          (i 0))
      (dolist (entry decklet-review--trail)
        (when (and (string-equal (plist-get entry :word) word)
                   (< i decklet-review--trail-pointer))
          (setq removed-before-pointer (1+ removed-before-pointer)))
        (setq i (1+ i)))
      (setq decklet-review--trail
            (seq-remove (lambda (e) (string-equal (plist-get e :word) word))
                        decklet-review--trail))
      (setq decklet-review--trail-pointer
            (min (- decklet-review--trail-pointer removed-before-pointer)
                 (length decklet-review--trail))))))

(defun decklet-review--present-card (word)
  "Set WORD as the current card and render the review buffer."
  (setq decklet-current-word word)
  (decklet-review--reset-ui-state)
  (run-hooks 'decklet-review-next-card-hook)
  (decklet-review--render-buffer))

(defun decklet-review--trail-skip ()
  "Append a skip entry for the current word to the trail."
  (when decklet-current-word
    (let ((meta (decklet-get-card-meta decklet-current-word)))
      (when meta
        (decklet-review--trail-append
         (list :word decklet-current-word
               :grade nil
               :pre-meta (copy-decklet-card-meta meta)))))))

(defun decklet-review--advance ()
  "Show the next card from the trail or the due queue, or quit."
  (if (decklet-review--undo-in-progress-p)
      (decklet-review--present-card
       (plist-get (decklet-review--trail-current-entry) :word))
    (if (or decklet-due-words (decklet--refresh-due-words))
        (decklet-review--present-card (pop decklet-due-words))
      (decklet-review-quit))))

(defun decklet-review-next-card ()
  "Review the next due card.
When in undo state, confirm the current undone card and advance.
When current list is empty, re-check for due cards and continue if any exist."
  (interactive)
  (if (decklet-review--undo-in-progress-p)
      (progn
        (decklet-review--trail-advance-pointer)
        (decklet-review--advance))
    ;; Normal forward flow: record skip on the trail, then pop next card.
    (decklet-review--trail-skip)
    (decklet-review--advance)))

(defun decklet-review-quit ()
  "Quit Decklet review."
  (interactive)
  (decklet-review--clean-up)
  (when-let ((buffer (get-buffer decklet-review-buffer-name)))
    (kill-buffer buffer))
  (run-hooks 'decklet-review-quit-hook)
  (decklet-db--disconnect-if-idle)
  (message "Review session finished"))

(defun decklet-review--handle-grade (grade)
  "Handle a GRADE input and move on to the next word."
  (let ((word (decklet--require-current-word "rate"))
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
          (let ((new-log-id (decklet-rate-card word grade prior-grade)))
            (plist-put entry :log-id new-log-id))
          (decklet-review--trail-update-entry grade))
      ;; Normal forward rating: snapshot pre-meta, rate, append.
      (let* ((pre-meta (let ((m (decklet-get-card-meta word)))
                         (when m (copy-decklet-card-meta m))))
             (new-log-id (decklet-rate-card word grade)))
        (decklet-review--trail-append
         (list :word word :grade grade :pre-meta pre-meta :log-id new-log-id))))
    (when (and (not goal-was-reached)
               (decklet-review--daily-goal-reached-p))
      (run-hooks 'decklet-review-daily-goal-reached-hook))
    (message "Rated \"%s\" as (%s)" word
             (pcase grade (1 "Again") (2 "Hard") (3 "Good") (4 "Easy") (_ "Unknown")))
    ;; Advance to the next card.  Do not go through `next-card' since
    ;; that would record a spurious skip on the trail for the word we just rated.
    (decklet-review--advance)))

(defun decklet-review-undo ()
  "Go back to the previous card and redisplay it.
Moves the undo pointer backward.  Does not revert DB state — the
original rating remains in the database until the user re-rates."
  (interactive)
  (if (not (decklet-review--trail-can-retreat-p))
      (message "Nothing to undo")
    ;; When undoing from normal flow, the current card hasn't been
    ;; appended to the trail yet — push it back to the front of the
    ;; due queue so it isn't lost.  When already in undo state, the
    ;; current card is on the trail and will be revisited when the
    ;; pointer advances.
    (when (and (not (decklet-review--undo-in-progress-p))
               decklet-current-word)
      (push decklet-current-word decklet-due-words))
    (decklet-review--trail-retreat-pointer)
    (let* ((entry (decklet-review--trail-current-entry))
           (word (plist-get entry :word)))
      (if (not (decklet-card-exists-p word))
          (progn
            (message "Card \"%s\" no longer exists, undo skipped" word)
            (decklet-review-undo))
        (decklet-review--present-card word)))))

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
  (when decklet-current-word
    (let ((buffer (decklet-review--setup-buffer)))
      (switch-to-buffer buffer)
      (decklet-review--render-buffer))))

(defun decklet-review--edit-card-fields (edit-word edit-hint)
  "Edit the current card using EDIT-WORD and EDIT-HINT flags."
  (unless decklet-current-word
    (user-error "No current word to edit"))
  (setq decklet-current-word
        (decklet-prompt-edit-card-fields decklet-current-word edit-word edit-hint))
  (when (eq major-mode 'decklet-review-mode)
    (decklet-review--render-buffer))
  (message "Updated \"%s\"" decklet-current-word))

(defun decklet-review-edit-word ()
  "Edit the current word."
  (interactive)
  (decklet-review--edit-card-fields t nil))

(defun decklet-review-edit-hint ()
  "Edit the current hint."
  (interactive)
  (decklet-review--edit-card-fields nil t))

(defun decklet-review-delete-card ()
  "Delete the current card from the deck."
  (interactive)
  (let ((word (decklet--require-current-word "delete")))
    (when (yes-or-no-p (format "Are you sure you want to delete \"%s\" from the deck? " word))
      (decklet-delete-card word)
      (message "Deleted \"%s\" from the deck." word)
      (setq decklet-current-word nil)
      (when (eq major-mode 'decklet-review-mode)
        (decklet-review--advance)))))

(defun decklet-review-show-card-back ()
  "Show the card back for the current word in a read-only popup."
  (interactive)
  (let ((word (decklet--require-current-word "show card back for")))
    (decklet-card-back-show word
                            (lambda () (decklet-review--render-buffer t)))))

(defun decklet-review-edit-card-back ()
  "Open the card back for the current word in an editable popup."
  (interactive)
  (let ((word (decklet--require-current-word "edit card back for")))
    (decklet-card-back-edit word
                            (lambda () (decklet-review--render-buffer t)))))

;; Review mode setup

;;;###autoload
(defun decklet-review ()
  "Start a review session."
  (interactive)
  (run-hooks 'decklet-review-start-hook)
  (decklet-review--trail-reset)
  (decklet--refresh-due-words)
  (if (null decklet-due-words)
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

;; Refresh the visible review buffer whenever any card field is updated.
;; This removes the need for callers of `decklet-set-card-hint' or
;; `decklet-set-card-back' to manage UI refreshes themselves.
(defun decklet-review--on-field-updated (_word _field)
  "Refresh the visible review buffer after a card field update."
  (decklet-review--refresh-visible))

(add-hook 'decklet-card-field-updated-functions
          #'decklet-review--on-field-updated)

(add-hook 'decklet-card-renamed-functions #'decklet-review--trail-rename)
(add-hook 'decklet-card-deleted-functions #'decklet-review--trail-delete)

(define-derived-mode decklet-review-mode special-mode "Decklet-Review"
  "Major mode for reviewing vocabulary with FSRS algorithm."
  (setq buffer-read-only t)
  (buffer-disable-undo))

(provide 'decklet-review)
;;; decklet-review.el ends here

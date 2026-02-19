;;; mnemodeck-review.el --- Review mode for MnemoDeck -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Review UI and FSRS grading flow.

;;; Code:

(require 'ansi-color)
(require 'cl-lib)
(require 'seq)

(require 'mnemodeck-db)
(require 'mnemodeck-deck)

(defgroup mnemodeck-review nil
  "Review mode for MnemoDeck."
  :group 'mnemodeck)

;; Parameters

(defcustom mnemodeck-review-daily-goal nil
  "Number of words to review per day.
When nil, disable daily goal tracking and related UI."
  :type '(choice (const :tag "Disable" nil) integer)
  :group 'mnemodeck-review)

(defcustom mnemodeck-review-hint-delay 1.5
  "Delay time in seconds for hint display."
  :type 'float
  :group 'mnemodeck-review)

(defcustom mnemodeck-review-hide-cursor t
  "Whether to hide the cursor in the review buffer."
  :type 'boolean
  :group 'mnemodeck-review)

(defcustom mnemodeck-review-enable-interval-labels t
  "Whether to show projected intervals next to rating options.
When non-nil, review mode shows compact labels such as (10m) for
Again/Hard/Good/Easy based on the current card state and FSRS prediction."
  :type 'boolean
  :group 'mnemodeck-review)

;; UI components

(defcustom mnemodeck-review-fixed-components
  '(mnemodeck-review-component-title
    mnemodeck-review-component-separator
    mnemodeck-review-component-counters
    mnemodeck-review-component-separator
    mnemodeck-review-component-daily-goal
    mnemodeck-review-component-separator
    mnemodeck-review-component-rates
    mnemodeck-review-component-separator
    mnemodeck-review-component-linebreak
    mnemodeck-review-component-word
    mnemodeck-review-component-linebreak
    mnemodeck-review-component-separator)
  "Components used for vertical centering and rendered before floating components."
  :type '(repeat function)
  :group 'mnemodeck-review)

(defcustom mnemodeck-review-floating-components
  '(mnemodeck-review-component-linebreak
    mnemodeck-review-component-hint)
  "Components rendered after the fixed block and excluded from centering."
  :type '(repeat function)
  :group 'mnemodeck-review)

(defcustom mnemodeck-review-daily-goal-progress-steps 50
  "Number of steps used in the daily goal progress bar."
  :type 'integer
  :group 'mnemodeck-review)

(defcustom mnemodeck-review-fill-column 50
  "Column beyond which automatic line-wrapping should happen."
  :type 'integer
  :group 'mnemodeck-review)

;; Faces

(defface mnemodeck-review-word-face
  `((((type graphic))
     :foreground ,(face-attribute 'ansi-color-red :foreground)
     :weight bold
     :height 1.5)
    (((type tty))
     :inherit default
     :foreground ,(face-attribute 'ansi-color-red :foreground)
     :weight bold
     :height 1.0))
  "Face for displaying the current word."
  :group 'mnemodeck-review)

(defface mnemodeck-review-status-new-face
  `((((type graphic))
     :foreground ,(face-attribute 'ansi-color-magenta :foreground)
     :weight bold
     :height 1.2)
    (((type tty))
     :inherit default
     :foreground ,(face-attribute 'ansi-color-magenta :foreground)
     :weight bold
     :height 1.0))
  "Face for displaying the `NEW WORD' status."
  :group 'mnemodeck-review)

(defface mnemodeck-review-status-review-face
  `((((type graphic))
     :foreground ,(face-attribute 'ansi-color-yellow :foreground)
     :weight bold
     :height 1.2)
    (((type tty))
     :inherit default
     :foreground ,(face-attribute 'ansi-color-yellow :foreground)
     :weight bold
     :height 1.0))
  "Face for displaying the `REVIEWING' status."
  :group 'mnemodeck-review)

(defface mnemodeck-review-counter-new-face
  `((t :foreground ,(face-attribute 'ansi-color-magenta :foreground)
       :weight bold :underline t))
  "Face for displaying the number of new words."
  :group 'mnemodeck-review)

(defface mnemodeck-review-counter-review-face
  `((t :foreground ,(face-attribute 'ansi-color-green :foreground)
       :weight bold :underline t))
  "Face for displaying the number of due words."
  :group 'mnemodeck-review)

(defface mnemodeck-review-counter-due-face
  `((t :foreground ,(face-attribute 'ansi-color-yellow :foreground)
       :weight bold :underline t))
  "Face for displaying the number of reviewed words today."
  :group 'mnemodeck-review)

(defface mnemodeck-review-status-goal-face
  `((t :foreground ,(face-attribute 'ansi-color-green :foreground)
       :weight bold))
  "Face for displaying the `DAILY GOAL REACHED' status."
  :group 'mnemodeck-review)

(defface mnemodeck-review-status-progress-face
  `((t :inherit default))
  "Face for displaying the daily goal progress bar."
  :group 'mnemodeck-review)

(defface mnemodeck-review-hint-placeholder-face
  `((t :inherit shadow :weight bold))
  "Face for displaying the hint placeholder."
  :group 'mnemodeck-review)

(defface mnemodeck-review-rating-interval-face
  `((t :inherit shadow))
  "Face for displaying rating interval hints."
  :group 'mnemodeck-review)

(defface mnemodeck-review-separator-face
  `((t :inherit shadow :weight bold))
  "Face for horizontal separators."
  :group 'mnemodeck-review)

;; Hooks

(defcustom mnemodeck-review-start-hook nil
  "Hook run when MnemoDeck review session starts."
  :type 'hook
  :group 'mnemodeck-review)

(defcustom mnemodeck-review-quit-hook nil
  "Hook run when MnemoDeck review quits/cleans up."
  :type 'hook
  :group 'mnemodeck-review)

(defcustom mnemodeck-review-next-card-hook nil
  "Hook run when MnemoDeck switches to the next word."
  :type 'hook
  :group 'mnemodeck-review)

(defcustom mnemodeck-review-daily-goal-reached-hook nil
  "Hook run once when the daily goal is reached."
  :type 'hook
  :group 'mnemodeck-review)

;; Internal

(defvar mnemodeck-review-buffer-name "*MnemoDeck Review*"
  "Name of the buffer used for reviews.")

(defvar mnemodeck-review--separator-width 0
  "Current separator width used by `mnemodeck-review-component-separator'.")

(defvar mnemodeck-review--state-display-hint nil
  "UI state: display hint.")

(defvar mnemodeck-review--hint-timer nil
  "Delay timer for hint display.")

;; Bring the definition up because it will be used by other functions down below.
(defvar mnemodeck-review-mode-map
  (define-keymap
    "1" #'mnemodeck-review-rate-again
    "2" #'mnemodeck-review-rate-hard
    "3" #'mnemodeck-review-rate-good
    "4" #'mnemodeck-review-rate-easy
    "q" #'mnemodeck-review-quit
    "n" #'mnemodeck-review-next-card
    "g" #'mnemodeck-review-refresh
    "D" #'mnemodeck-review-delete-card
    "e" #'mnemodeck-review-edit-word
    "t" #'mnemodeck-review-edit-hint)
  "Keymap for `mnemodeck-review-mode'.")

;; Format helpers

(defun mnemodeck--string-max-line-width (text)
  "Return the maximum line width for TEXT."
  (let ((max-width 0))
    (dolist (line (split-string text "\n") max-width)
      ;; Strip left padding so separators match the real content width.
      (let ((width (string-width (string-trim-left line))))
        (setq max-width (max max-width width))))))

(defun mnemodeck--string-pixel-size (text)
  "Return the pixel (WIDTH . HEIGHT) of TEXT in the current buffer context."
  (let ((fallback-height (* (length (split-string text "\n" t))
                            (frame-char-height))))
    (if (fboundp 'buffer-text-pixel-size)
        (let ((remap face-remapping-alist)
              (buffer-face (and (boundp 'buffer-face-mode-face)
                                buffer-face-mode-face)))
          (with-temp-buffer
            (let ((face-remapping-alist remap)
                  (inhibit-modification-hooks t))
              (when (boundp 'buffer-face-mode-face)
                (setq buffer-face-mode-face buffer-face))
              (insert text)
              (let ((size (buffer-text-pixel-size (current-buffer))))
                (cond
                 ((consp size) size)
                 ((numberp size) (cons size fallback-height))
                 (t (cons (string-pixel-width text) fallback-height)))))))
      (cons (string-pixel-width text) fallback-height))))

(defun mnemodeck--center-padding (lines)
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
                        (car (mnemodeck--string-pixel-size text)))
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

(defun mnemodeck-center-text (text)
  "Center TEXT in the current window width.
Multi-line text is centered as a block, not per-line."
  (let* ((lines (split-string text "\n"))
         (padding (mnemodeck--center-padding lines)))
    (mapconcat (lambda (line)
                 (concat padding line))
               lines
               "\n")))

(defun mnemodeck-fill-and-center-text (text width)
  "Wrap TEXT to WIDTH and center each wrapped line as a block."
  (let ((lines (string-split text "\n")))
    (string-join (mapcar (lambda (line)
                           (mnemodeck-center-text
                            (string-fill (string-trim line) width)))
                         lines)
                 "\n")))

(defun mnemodeck--format-interval (seconds)
  "Return a human readable string for SECONDS."
  (cond
   ((< seconds 60) "<1m")
   ((< seconds 3600) (format "%dm" (floor (/ seconds 60))))
   ((< seconds 86400) (format "%dh" (floor (/ seconds 3600))))
   ((< seconds 2592000) (format "%dd" (floor (/ seconds 86400))))
   ((< seconds 31536000) (format "%dM" (floor (/ seconds 2592000))))
   (t (format "%dy" (floor (/ seconds 31536000))))))

;; Buffer rendering

(defun mnemodeck-review--collect-component-items (components &optional last-was-sep)
  "Return (ITEMS . LAST-WAS-SEP) for COMPONENTS.
ITEMS contains (TEXT . SEPARATOR) pairs.  Leading or consecutive separators
are skipped so rendering won't stack separator lines."
  (let (items)
    (dolist (fn components)
      (let ((text (funcall fn))
            (separator (eq fn 'mnemodeck-review-component-separator)))
        (when text
          (unless (and separator (or last-was-sep (null items)))
            (push (cons text separator) items)
            (setq last-was-sep separator)))))
    (cons (nreverse items) last-was-sep)))

(defun mnemodeck-review--render-component-items (items)
  "Render ITEMS into a single string with trailing newlines."
  (concat (string-join (mapcar #'car items) "\n") "\n"))

(defun mnemodeck-review--render-with-vertical-center (fixed-items floating-items)
  "Render FIXED-ITEMS and FLOATING-ITEMS with vertical centering."
  (let* ((fixed-text (mnemodeck-review--render-component-items fixed-items))
         (floating-text (mnemodeck-review--render-component-items floating-items)))
    (if (display-graphic-p)
        ;; In GUI, center using pixel measurements for more accurate alignment.
        (let* ((measure-text (string-trim-right fixed-text "\n+"))
               (fixed-h (cdr (mnemodeck--string-pixel-size measure-text)))
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
             (top-n-lines (max 0 (- half-body-h line-count 0))))
        (concat (make-string top-n-lines ?\n) fixed-text floating-text)))))

(defun mnemodeck-review--render-components ()
  "Render fixed and floating components with vertical centering for fixed ones."
  (let* ((content-components (seq-remove (lambda (fn)
                                           (eq fn 'mnemodeck-review-component-separator))
                                         (append mnemodeck-review-fixed-components
                                                 mnemodeck-review-floating-components)))
         (content-texts (delq nil (mapcar #'funcall content-components))))
    (if (null content-texts)
        ""
      ;; Update separator width.
      ;; Width is based on content only so separators match visible text.
      (setq mnemodeck-review--separator-width
            (seq-reduce
             #'max
             (mapcar #'mnemodeck--string-max-line-width content-texts)
             0))
      (let* ((fixed-result (mnemodeck-review--collect-component-items mnemodeck-review-fixed-components))
             (fixed-items (car fixed-result))
             ;; Track if the fixed block ended with a separator so we
             ;; do not stack separators between fixed and floating blocks.
             (last-was-sep (cdr fixed-result))
             (floating-result (mnemodeck-review--collect-component-items mnemodeck-review-floating-components last-was-sep))
             (floating-items (car floating-result)))
        (mnemodeck-review--render-with-vertical-center fixed-items floating-items)))))

(defun mnemodeck-review--setup-buffer ()
  "Set up the review buffer."
  (let ((buffer (get-buffer-create mnemodeck-review-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (unless (derived-mode-p 'mnemodeck-review-mode)
          (mnemodeck-review-mode))))
    buffer))

(defun mnemodeck-review--hint-delay-enabled-p ()
  "Return non-nil when hint delay is enabled.
Hint delay is enabled when `mnemodeck-review-hint-delay' is a positive number."
  (and (numberp mnemodeck-review-hint-delay) (> mnemodeck-review-hint-delay 0)))

(defun mnemodeck-review--reset-ui-state ()
  "Reset UI state."
  (mnemodeck-review--cancel-hint-timer)
  (setq mnemodeck-review--state-display-hint
        (not (mnemodeck-review--hint-delay-enabled-p))))

(defun mnemodeck-review--clean-up ()
  "Clear transient review session state."
  (setq mnemodeck-current-word nil)
  (setq mnemodeck-last-added-word nil)
  (setq mnemodeck-due-words nil)
  (mnemodeck-review--reset-ui-state))

(defun mnemodeck-review--refresh-visible (&rest _args)
  "Refresh the review buffer if it is visible in a window."
  (when-let ((window (get-buffer-window mnemodeck-review-buffer-name 'visible)))
    (with-current-buffer (window-buffer window)
      (when (eq major-mode 'mnemodeck-review-mode)
        (mnemodeck-review--render-buffer t)))))

(defun mnemodeck-review--enable-resize-refresh ()
  "Enable refresh hooks for resize and text scaling."
  (add-hook 'window-size-change-functions #'mnemodeck-review--refresh-visible)
  (unless (advice-member-p #'mnemodeck-review--refresh-visible 'text-scale-adjust)
    (advice-add 'text-scale-adjust :after #'mnemodeck-review--refresh-visible))
  (unless (advice-member-p #'mnemodeck-review--refresh-visible 'text-scale-set)
    (advice-add 'text-scale-set :after #'mnemodeck-review--refresh-visible)))

(defun mnemodeck-review--disable-resize-refresh ()
  "Disable refresh hooks for resize and text scaling."
  (remove-hook 'window-size-change-functions #'mnemodeck-review--refresh-visible)
  (advice-remove 'text-scale-adjust #'mnemodeck-review--refresh-visible)
  (advice-remove 'text-scale-set #'mnemodeck-review--refresh-visible))

(defun mnemodeck-review--daily-goal-reached-p ()
  "Check if the daily review goal has been reached."
  (when mnemodeck-review-daily-goal
    (or (>= (plist-get mnemodeck--counter :reviewed)
            mnemodeck-review-daily-goal)
        (and (<= (+ (plist-get mnemodeck--counter :due-review)
                    (plist-get mnemodeck--counter :due-learning))
                 0)
             (<= (plist-get mnemodeck--counter :new) 0)))))

(defun mnemodeck-review--cancel-hint-timer ()
  "Cancel `mnemodeck-review--hint-timer'."
  (when mnemodeck-review--hint-timer
    (cancel-timer mnemodeck-review--hint-timer)
    (setq mnemodeck-review--hint-timer nil)))

(defun mnemodeck-review--start-hint-timer ()
  "Start `mnemodeck-review--hint-timer'."
  (when (and (not mnemodeck-review--hint-timer)
             (mnemodeck-review--hint-delay-enabled-p))
    (setq mnemodeck-review--hint-timer
          (run-at-time mnemodeck-review-hint-delay
                       nil
                       (lambda ()
                         (setq mnemodeck-review--state-display-hint t)
                         (mnemodeck-review--render-buffer t))))))

(defun mnemodeck-review--instruction-key-label (command)
  "Return a key label for COMMAND from `mnemodeck-review-mode-map'."
  (if (where-is-internal command (list mnemodeck-review-mode-map))
      (substitute-command-keys
       (format "\\<mnemodeck-review-mode-map>\\[%s]" command))
    ""))

(defun mnemodeck-review--instruction-interval-label (word meta grade)
  "Return a propertized interval label for WORD with META at GRADE.
When `mnemodeck-review-enable-interval-labels' is nil, return an empty string.
Otherwise, simulate one FSRS review with GRADE and format the predicted
interval as a compact label, for example (10m)."
  (if (not mnemodeck-review-enable-interval-labels)
      ""
    (let* ((scheduler (mnemodeck--get-fsrs-scheduler))
           (rating (mnemodeck--fsrs-rating-from-grade grade))
           (review-time (fsrs-now))
           (card (mnemodeck--card-meta->fsrs-card word meta))
           ;; Simulate the rating to show the interval before the user commits.
           (new-card (cl-nth-value 0
                                   (fsrs-scheduler-review-card
                                    scheduler card rating review-time))))
      (propertize
       (format " (%s)"
               (mnemodeck--format-interval
                (fsrs-timestamp-difference (fsrs-card-due new-card) review-time)))
       'face 'mnemodeck-review-rating-interval-face))))

(defun mnemodeck-review--separator (&optional length)
  "Return the styled separator line for instruction blocks.
When LENGTH is non-nil, use it as the separator width."
  (propertize (make-string (or length 49) ?─)
              'face 'mnemodeck-review-separator-face))

(defun mnemodeck-review-component-title ()
  "Return the centered title line for the review header."
  (mnemodeck-center-text
   (let ((meta (mnemodeck--load-card-meta mnemodeck-current-word)))
     (cond
      ((mnemodeck-card-meta-is-new meta)
       (propertize "NEW WORD" 'face 'mnemodeck-review-status-new-face))
      ((memq (mnemodeck-card-meta-state meta) '(:learning :relearning))
       (propertize "LEARNING" 'face 'mnemodeck-review-status-review-face))
      (t
       (propertize "REVIEWING" 'face 'mnemodeck-review-status-review-face))))))

(defun mnemodeck-review-component-counters ()
  "Return the counter block for the instructions."
  (let* ((n-reviewed (plist-get mnemodeck--counter :reviewed))
         (n-due-review (plist-get mnemodeck--counter :due-review))
         (n-due-learning (plist-get mnemodeck--counter :due-learning))
         (n-new (plist-get mnemodeck--counter :new)))
    (mnemodeck-center-text
     (format "%s reviewed / %s review due / %s learning due / %s new"
             (propertize (number-to-string n-reviewed) 'face 'mnemodeck-review-counter-review-face)
             (propertize (number-to-string n-due-review) 'face 'mnemodeck-review-counter-due-face)
             (propertize (number-to-string n-due-learning) 'face 'mnemodeck-review-counter-due-face)
             (propertize (number-to-string n-new) 'face 'mnemodeck-review-counter-new-face)))))

(defun mnemodeck-review-component-daily-goal ()
  "Insert the daily goal banner in the review buffer."
  (when (and mnemodeck-review-daily-goal (> mnemodeck-review-daily-goal 0))
    (if (mnemodeck-review--daily-goal-reached-p)
        (mnemodeck-center-text (propertize "DAILY GOAL REACHED" 'face 'mnemodeck-review-status-goal-face))
      (let* ((n-reviewed (plist-get mnemodeck--counter :reviewed))
             (goal-progress (/ (float n-reviewed) mnemodeck-review-daily-goal))
             (steps (max 0 mnemodeck-review-daily-goal-progress-steps))
             (n-clicks-completed (mnemodeck--clamp (round (* goal-progress steps)) 0 steps))
             (percentage (format "%.2f%%" (* 100 goal-progress)))
             (progress-bar (concat
                            (make-string n-clicks-completed ?█)
                            (make-string (- steps n-clicks-completed) ?░))))
        (concat
         (mnemodeck-center-text (propertize percentage 'face 'mnemodeck-review-status-progress-face))
         "\n"
         (mnemodeck-center-text (propertize progress-bar 'face 'mnemodeck-review-status-progress-face)))))))

(defun mnemodeck-review-component-rates ()
  "Return the options block for review ratings and commands.
Interval labels are included when
`mnemodeck-review-enable-interval-labels' is non-nil."
  (let* ((meta (mnemodeck--load-card-meta mnemodeck-current-word))
         (option-lines
          (list
           (concat (mnemodeck-review--instruction-key-label 'mnemodeck-review-rate-again)
                   " Again"
                   (mnemodeck-review--instruction-interval-label mnemodeck-current-word meta 1))
           ;; Add one extra space after "Hard", "Good", and "Easy" to make interval labels vertically aligned
           (concat (mnemodeck-review--instruction-key-label 'mnemodeck-review-rate-hard)
                   " Hard "
                   (mnemodeck-review--instruction-interval-label mnemodeck-current-word meta 2))
           (concat (mnemodeck-review--instruction-key-label 'mnemodeck-review-rate-good)
                   " Good "
                   (mnemodeck-review--instruction-interval-label mnemodeck-current-word meta 3))
           (concat (mnemodeck-review--instruction-key-label 'mnemodeck-review-rate-easy)
                   " Easy "
                   (mnemodeck-review--instruction-interval-label mnemodeck-current-word meta 4)))))
    (mnemodeck-center-text (string-join option-lines "\n"))))

(defun mnemodeck-review-component-separator ()
  "Return the separator line for the review components."
  (when (> mnemodeck-review--separator-width 0)
    (mnemodeck-center-text
     (mnemodeck-review--separator mnemodeck-review--separator-width))))

(defun mnemodeck-review-component-linebreak ()
  "Return an empty component that is kept to force a blank line."
  "")

(defun mnemodeck-review-component-word ()
  "Insert the current word in the review buffer."
  (let ((word (propertize mnemodeck-current-word 'face 'mnemodeck-review-word-face)))
    (mnemodeck-center-text word)))

(defun mnemodeck-review-component-hint ()
  "Insert the current word's hint in the review buffer."
  (let ((hint (mnemodeck--current-card-hint)))
    (when hint
      (if mnemodeck-review--state-display-hint
          (mnemodeck-fill-and-center-text hint mnemodeck-review-fill-column)
        (let ((hint-placeholder (propertize "[HINT]" 'face 'mnemodeck-review-hint-placeholder-face)))
          (mnemodeck-center-text hint-placeholder))))))

(defun mnemodeck-review--hide-cursor ()
  "Hide the cursor and hl-line in the review buffer window."
  (when (eq major-mode 'mnemodeck-review-mode)
    ;; Hide cursor
    (setq-local cursor-type nil)
    ;; Disable hl-line-mode for a cleaner UI
    (when (boundp 'hl-line-mode)
      (hl-line-mode -1))
    (when (boundp 'global-hl-line-mode)
      (setq-local global-hl-line-mode nil))))

(defun mnemodeck-review--render-buffer (&optional keep-position)
  "Render the review buffer.
When KEEP-POSITION is non-nil, preserve the window scroll and point."
  (with-current-buffer (get-buffer mnemodeck-review-buffer-name)
    (when mnemodeck-review-hide-cursor
      (mnemodeck-review--hide-cursor))
    (let* ((window (get-buffer-window (current-buffer) 0))
           (saved-point (when (and keep-position window) (window-point window)))
           (saved-start (when (and keep-position window) (window-start window)))
           (render (lambda ()
                     (let ((inhibit-read-only t))
                       (erase-buffer)
                       (insert (mnemodeck-review--render-components))))))
      ;; Render using the review window so centering uses its dimensions.
      (if window
          (with-selected-window window (funcall render))
        (funcall render))
      (if (mnemodeck--current-card-hint)
          (mnemodeck-review--start-hint-timer)
        (mnemodeck-review--cancel-hint-timer))
      (if (and keep-position window)
          (progn
            (set-window-point window (min (or saved-point (point-min)) (point-max)))
            (when saved-start
              (set-window-start window saved-start t)))
        (goto-char (point-min))))))

;; Review flow and rating commands

(defun mnemodeck-review-next-card ()
  "Review the next due card.
When current list is empty, re-check for due cards and continue if any exist."
  (interactive)
  (if (or mnemodeck-due-words (mnemodeck--refresh-due-words))
      (let ((word (pop mnemodeck-due-words)))
        (setq mnemodeck-current-word word)
        (mnemodeck-review--reset-ui-state)
        (run-hooks 'mnemodeck-review-next-card-hook)
        (mnemodeck-review--render-buffer))
    (mnemodeck-review-quit)))

(defun mnemodeck-review-quit ()
  "Quit MnemoDeck review."
  (interactive)
  (mnemodeck-review--clean-up)
  (when-let ((buffer (get-buffer mnemodeck-review-buffer-name)))
    (kill-buffer buffer))
  (run-hooks 'mnemodeck-review-quit-hook)
  (mnemodeck-db--disconnect-if-idle)
  (message "Review session finished"))

(defun mnemodeck-review--handle-grade (grade)
  "Handle a GRADE input and move on to the next word."
  (let ((word (mnemodeck--require-current-word "rate")))
    (let ((goal-was-reached (mnemodeck-review--daily-goal-reached-p)))
      (mnemodeck-rate-card word grade)
      (when (and (not goal-was-reached)
                 (mnemodeck-review--daily-goal-reached-p))
        (run-hooks 'mnemodeck-review-daily-goal-reached-hook)))
    (let ((rating-text (pcase grade
                         (1 "Again")
                         (2 "Hard")
                         (3 "Good")
                         (4 "Easy")
                         (_ "Unknown"))))
      (message "Rated \"%s\" as (%s)" word rating-text))
    (mnemodeck-review-next-card)))

(defun mnemodeck-review-rate-again ()
  "Rate the current word as `again'."
  (interactive)
  (mnemodeck-review--handle-grade 1))

(defun mnemodeck-review-rate-hard ()
  "Rate the current word as `hard'."
  (interactive)
  (mnemodeck-review--handle-grade 2))

(defun mnemodeck-review-rate-good ()
  "Rate the current word as `good'."
  (interactive)
  (mnemodeck-review--handle-grade 3))

(defun mnemodeck-review-rate-easy ()
  "Rate the current word as `easy'."
  (interactive)
  (mnemodeck-review--handle-grade 4))

(defun mnemodeck-review-refresh ()
  "Refresh the review window."
  (interactive)
  (when mnemodeck-current-word
    (let ((buffer (mnemodeck-review--setup-buffer)))
      (switch-to-buffer buffer)
      (mnemodeck-review--render-buffer))))

(defun mnemodeck-review--edit-card-fields (edit-word edit-hint)
  "Edit the current card using EDIT-WORD and EDIT-HINT flags."
  (unless mnemodeck-current-word
    (user-error "No current word to edit"))
  (setq mnemodeck-current-word
        (mnemodeck-prompt-edit-card-fields mnemodeck-current-word edit-word edit-hint))
  (when (eq major-mode 'mnemodeck-review-mode)
    (mnemodeck-review--render-buffer))
  (message "Updated \"%s\"" mnemodeck-current-word))

(defun mnemodeck-review-edit-word ()
  "Edit the current word."
  (interactive)
  (mnemodeck-review--edit-card-fields t nil))

(defun mnemodeck-review-edit-hint ()
  "Edit the current hint."
  (interactive)
  (mnemodeck-review--edit-card-fields nil t))

(defun mnemodeck-review-delete-card ()
  "Delete the current card from the deck."
  (interactive)
  (if (null mnemodeck-current-word)
      (message "No current word to delete")
    (when (yes-or-no-p (format "Are you sure you want to delete \"%s\" from the deck? " mnemodeck-current-word))
      (mnemodeck-delete-card mnemodeck-current-word)
      (message "Deleted \"%s\" from the deck." mnemodeck-current-word)
      (setq mnemodeck-current-word nil)
      (when (eq major-mode 'mnemodeck-review-mode)
        (mnemodeck-review-next-card)))))

;; Review mode setup

;;;###autoload
(defun mnemodeck-review ()
  "Start a review session."
  (interactive)
  (run-hooks 'mnemodeck-review-start-hook)
  (mnemodeck--refresh-due-words)
  (if (null mnemodeck-due-words)
      (message "No words to review")
    (let ((buffer (mnemodeck-review--setup-buffer)))
      (switch-to-buffer buffer)
      (mnemodeck--refresh-counter)
      (mnemodeck-review-next-card))))

;; Keep review UI in sync when a hint is added via the quick add flow.
;; This runs only in review buffers and only when the last-added word is
;; the current review word, so other contexts stay unaffected.
(defun mnemodeck-review--maybe-refresh-after-add-hint (&rest _)
  "Refresh the review buffer after adding a hint for the current word."
  (when (and (eq major-mode 'mnemodeck-review-mode)
             mnemodeck-current-word
             mnemodeck-last-added-word
             (string-equal mnemodeck-current-word mnemodeck-last-added-word))
    (mnemodeck-review--render-buffer t)))

;; Use advice to make the logic less entangled.
;; This refresh logic is solely for the review mode.
(advice-add 'mnemodeck-add-hint :after #'mnemodeck-review--maybe-refresh-after-add-hint)

;; Backup
(add-hook 'mnemodeck-review-start-hook #'mnemodeck-db-backup)
(add-hook 'mnemodeck-review-quit-hook #'mnemodeck-db-backup)
;; Auto-refresh
(add-hook 'mnemodeck-review-start-hook #'mnemodeck-review--enable-resize-refresh)
(add-hook 'mnemodeck-review-quit-hook #'mnemodeck-review--disable-resize-refresh)

(define-derived-mode mnemodeck-review-mode special-mode "MnemoDeck-Review"
  "Major mode for reviewing vocabulary with FSRS algorithm."
  (setq buffer-read-only t)
  (buffer-disable-undo))

(provide 'mnemodeck-review)
;;; mnemodeck-review.el ends here

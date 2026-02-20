;;; decklite-review.el --- Review mode for DeckLite -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Review UI and FSRS grading flow.

;;; Code:

(require 'ansi-color)
(require 'cl-lib)
(require 'seq)

(require 'decklite-db)
(require 'decklite-deck)

(defgroup decklite-review nil
  "Review mode for DeckLite."
  :group 'decklite)

;; Parameters

(defcustom decklite-review-daily-goal nil
  "Number of words to review per day.
When nil, disable daily goal tracking and related UI."
  :type '(choice (const :tag "Disable" nil) integer)
  :group 'decklite-review)

(defcustom decklite-review-hint-delay 1.5
  "Delay time in seconds for hint display."
  :type 'float
  :group 'decklite-review)

(defcustom decklite-review-hide-cursor t
  "Whether to hide the cursor in the review buffer."
  :type 'boolean
  :group 'decklite-review)

(defcustom decklite-review-enable-interval-labels t
  "Whether to show projected intervals next to rating options.
When non-nil, review mode shows compact labels such as (10m) for
Again/Hard/Good/Easy based on the current card state and FSRS prediction."
  :type 'boolean
  :group 'decklite-review)

;; UI components

(defcustom decklite-review-fixed-components
  '(decklite-review-component-title
    decklite-review-component-separator
    decklite-review-component-counters
    decklite-review-component-separator
    decklite-review-component-daily-goal
    decklite-review-component-separator
    decklite-review-component-rates
    decklite-review-component-separator
    decklite-review-component-linebreak
    decklite-review-component-word
    decklite-review-component-linebreak
    decklite-review-component-separator)
  "Components used for vertical centering and rendered before floating components."
  :type '(repeat function)
  :group 'decklite-review)

(defcustom decklite-review-floating-components
  '(decklite-review-component-linebreak
    decklite-review-component-hint)
  "Components rendered after the fixed block and excluded from centering."
  :type '(repeat function)
  :group 'decklite-review)

(defcustom decklite-review-daily-goal-progress-steps 50
  "Number of steps used in the daily goal progress bar."
  :type 'integer
  :group 'decklite-review)

(defcustom decklite-review-fill-column 50
  "Column beyond which automatic line-wrapping should happen."
  :type 'integer
  :group 'decklite-review)

;; Faces

(defface decklite-review-word-face
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
  :group 'decklite-review)

(defface decklite-review-status-new-face
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
  :group 'decklite-review)

(defface decklite-review-status-review-face
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
  :group 'decklite-review)

(defface decklite-review-counter-new-face
  `((t :foreground ,(face-attribute 'ansi-color-magenta :foreground)
       :weight bold :underline t))
  "Face for displaying the number of new words."
  :group 'decklite-review)

(defface decklite-review-counter-review-face
  `((t :foreground ,(face-attribute 'ansi-color-green :foreground)
       :weight bold :underline t))
  "Face for displaying the number of due words."
  :group 'decklite-review)

(defface decklite-review-counter-due-face
  `((t :foreground ,(face-attribute 'ansi-color-yellow :foreground)
       :weight bold :underline t))
  "Face for displaying the number of reviewed words today."
  :group 'decklite-review)

(defface decklite-review-status-goal-face
  `((t :foreground ,(face-attribute 'ansi-color-green :foreground)
       :weight bold))
  "Face for displaying the `DAILY GOAL REACHED' status."
  :group 'decklite-review)

(defface decklite-review-status-progress-face
  `((t :inherit default))
  "Face for displaying the daily goal progress bar."
  :group 'decklite-review)

(defface decklite-review-hint-placeholder-face
  `((t :inherit shadow :weight bold))
  "Face for displaying the hint placeholder."
  :group 'decklite-review)

(defface decklite-review-rating-interval-face
  `((t :inherit shadow))
  "Face for displaying rating interval hints."
  :group 'decklite-review)

(defface decklite-review-separator-face
  `((t :inherit shadow :weight bold))
  "Face for horizontal separators."
  :group 'decklite-review)

;; Hooks

(defcustom decklite-review-start-hook nil
  "Hook run when DeckLite review session starts."
  :type 'hook
  :group 'decklite-review)

(defcustom decklite-review-quit-hook nil
  "Hook run when DeckLite review quits/cleans up."
  :type 'hook
  :group 'decklite-review)

(defcustom decklite-review-next-card-hook nil
  "Hook run when DeckLite switches to the next word."
  :type 'hook
  :group 'decklite-review)

(defcustom decklite-review-daily-goal-reached-hook nil
  "Hook run once when the daily goal is reached."
  :type 'hook
  :group 'decklite-review)

;; Internal

(defvar decklite-review-buffer-name "*DeckLite Review*"
  "Name of the buffer used for reviews.")

(defvar decklite-review--separator-width 0
  "Current separator width used by `decklite-review-component-separator'.")

(defvar decklite-review--state-display-hint nil
  "UI state: display hint.")

(defvar decklite-review--hint-timer nil
  "Delay timer for hint display.")

;; Bring the definition up because it will be used by other functions down below.
(defvar decklite-review-mode-map
  (define-keymap
    "1" #'decklite-review-rate-again
    "2" #'decklite-review-rate-hard
    "3" #'decklite-review-rate-good
    "4" #'decklite-review-rate-easy
    "q" #'decklite-review-quit
    "n" #'decklite-review-next-card
    "g" #'decklite-review-refresh
    "D" #'decklite-review-delete-card
    "e" #'decklite-review-edit-word
    "t" #'decklite-review-edit-hint)
  "Keymap for `decklite-review-mode'.")

;; Format helpers

(defun decklite--string-max-line-width (text)
  "Return the maximum line width for TEXT."
  (let ((max-width 0))
    (dolist (line (split-string text "\n") max-width)
      ;; Strip left padding so separators match the real content width.
      (let ((width (string-width (string-trim-left line))))
        (setq max-width (max max-width width))))))

(defun decklite--string-pixel-size (text)
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

(defun decklite--center-padding (lines)
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
                        (car (decklite--string-pixel-size text)))
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

(defun decklite-center-text (text)
  "Center TEXT in the current window width.
Multi-line text is centered as a block, not per-line."
  (let* ((lines (split-string text "\n"))
         (padding (decklite--center-padding lines)))
    (mapconcat (lambda (line)
                 (concat padding line))
               lines
               "\n")))

(defun decklite-fill-and-center-text (text width)
  "Wrap TEXT to WIDTH and center each wrapped line as a block."
  (let ((lines (string-split text "\n")))
    (string-join (mapcar (lambda (line)
                           (decklite-center-text
                            (string-fill (string-trim line) width)))
                         lines)
                 "\n")))

(defun decklite--format-interval (seconds)
  "Return a human readable string for SECONDS."
  (cond
   ((< seconds 60) "<1m")
   ((< seconds 3600) (format "%dm" (floor (/ seconds 60))))
   ((< seconds 86400) (format "%dh" (floor (/ seconds 3600))))
   ((< seconds 2592000) (format "%dd" (floor (/ seconds 86400))))
   ((< seconds 31536000) (format "%dM" (floor (/ seconds 2592000))))
   (t (format "%dy" (floor (/ seconds 31536000))))))

;; Buffer rendering

(defun decklite-review--collect-component-items (components &optional last-was-sep)
  "Return (ITEMS . LAST-WAS-SEP) for COMPONENTS.
ITEMS contains (TEXT . SEPARATOR) pairs.  Leading or consecutive separators
are skipped so rendering won't stack separator lines."
  (let (items)
    (dolist (fn components)
      (let ((text (funcall fn))
            (separator (eq fn 'decklite-review-component-separator)))
        (when text
          (unless (and separator (or last-was-sep (null items)))
            (push (cons text separator) items)
            (setq last-was-sep separator)))))
    (cons (nreverse items) last-was-sep)))

(defun decklite-review--render-component-items (items)
  "Render ITEMS into a single string with trailing newlines."
  (concat (string-join (mapcar #'car items) "\n") "\n"))

(defun decklite-review--render-with-vertical-center (fixed-items floating-items)
  "Render FIXED-ITEMS and FLOATING-ITEMS with vertical centering."
  (let* ((fixed-text (decklite-review--render-component-items fixed-items))
         (floating-text (decklite-review--render-component-items floating-items)))
    (if (display-graphic-p)
        ;; In GUI, center using pixel measurements for more accurate alignment.
        (let* ((measure-text (string-trim-right fixed-text "\n+"))
               (fixed-h (cdr (decklite--string-pixel-size measure-text)))
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

(defun decklite-review--render-components ()
  "Render fixed and floating components with vertical centering for fixed ones."
  (let* ((content-components (seq-remove (lambda (fn)
                                           (eq fn 'decklite-review-component-separator))
                                         (append decklite-review-fixed-components
                                                 decklite-review-floating-components)))
         (content-texts (delq nil (mapcar #'funcall content-components))))
    (if (null content-texts)
        ""
      ;; Update separator width.
      ;; Width is based on content only so separators match visible text.
      (setq decklite-review--separator-width
            (seq-reduce
             #'max
             (mapcar #'decklite--string-max-line-width content-texts)
             0))
      (let* ((fixed-result (decklite-review--collect-component-items decklite-review-fixed-components))
             (fixed-items (car fixed-result))
             ;; Track if the fixed block ended with a separator so we
             ;; do not stack separators between fixed and floating blocks.
             (last-was-sep (cdr fixed-result))
             (floating-result (decklite-review--collect-component-items decklite-review-floating-components last-was-sep))
             (floating-items (car floating-result)))
        (decklite-review--render-with-vertical-center fixed-items floating-items)))))

(defun decklite-review--setup-buffer ()
  "Set up the review buffer."
  (let ((buffer (get-buffer-create decklite-review-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (unless (derived-mode-p 'decklite-review-mode)
          (decklite-review-mode))))
    buffer))

(defun decklite-review--hint-delay-enabled-p ()
  "Return non-nil when hint delay is enabled.
Hint delay is enabled when `decklite-review-hint-delay' is a positive number."
  (and (numberp decklite-review-hint-delay) (> decklite-review-hint-delay 0)))

(defun decklite-review--reset-ui-state ()
  "Reset UI state."
  (decklite-review--cancel-hint-timer)
  (setq decklite-review--state-display-hint
        (not (decklite-review--hint-delay-enabled-p))))

(defun decklite-review--clean-up ()
  "Clear transient review session state."
  (setq decklite-current-word nil)
  (setq decklite-last-added-word nil)
  (setq decklite-due-words nil)
  (decklite-review--reset-ui-state))

(defun decklite-review--refresh-visible (&rest _args)
  "Refresh the review buffer if it is visible in a window."
  (when-let ((window (get-buffer-window decklite-review-buffer-name 'visible)))
    (with-current-buffer (window-buffer window)
      (when (eq major-mode 'decklite-review-mode)
        (decklite-review--render-buffer t)))))

(defun decklite-review--enable-resize-refresh ()
  "Enable refresh hooks for resize and text scaling."
  (add-hook 'window-size-change-functions #'decklite-review--refresh-visible)
  (unless (advice-member-p #'decklite-review--refresh-visible 'text-scale-adjust)
    (advice-add 'text-scale-adjust :after #'decklite-review--refresh-visible))
  (unless (advice-member-p #'decklite-review--refresh-visible 'text-scale-set)
    (advice-add 'text-scale-set :after #'decklite-review--refresh-visible)))

(defun decklite-review--disable-resize-refresh ()
  "Disable refresh hooks for resize and text scaling."
  (remove-hook 'window-size-change-functions #'decklite-review--refresh-visible)
  (advice-remove 'text-scale-adjust #'decklite-review--refresh-visible)
  (advice-remove 'text-scale-set #'decklite-review--refresh-visible))

(defun decklite-review--daily-goal-reached-p ()
  "Check if the daily review goal has been reached."
  (when decklite-review-daily-goal
    (or (>= (plist-get decklite--counter :reviewed)
            decklite-review-daily-goal)
        (and (<= (+ (plist-get decklite--counter :due-review)
                    (plist-get decklite--counter :due-learning))
                 0)
             (<= (plist-get decklite--counter :new) 0)))))

(defun decklite-review--cancel-hint-timer ()
  "Cancel `decklite-review--hint-timer'."
  (when decklite-review--hint-timer
    (cancel-timer decklite-review--hint-timer)
    (setq decklite-review--hint-timer nil)))

(defun decklite-review--start-hint-timer ()
  "Start `decklite-review--hint-timer'."
  (when (and (not decklite-review--hint-timer)
             (decklite-review--hint-delay-enabled-p))
    (setq decklite-review--hint-timer
          (run-at-time decklite-review-hint-delay
                       nil
                       (lambda ()
                         (setq decklite-review--state-display-hint t)
                         (decklite-review--render-buffer t))))))

(defun decklite-review--instruction-key-label (command)
  "Return a key label for COMMAND from `decklite-review-mode-map'."
  (if (where-is-internal command (list decklite-review-mode-map))
      (substitute-command-keys
       (format "\\<decklite-review-mode-map>\\[%s]" command))
    ""))

(defun decklite-review--instruction-interval-label (word meta grade)
  "Return a propertized interval label for WORD with META at GRADE.
When `decklite-review-enable-interval-labels' is nil, return an empty string.
Otherwise, simulate one FSRS review with GRADE and format the predicted
interval as a compact label, for example (10m)."
  (if (not decklite-review-enable-interval-labels)
      ""
    (let* ((scheduler (decklite--get-fsrs-scheduler))
           (rating (decklite--fsrs-rating-from-grade grade))
           (review-time (fsrs-now))
           (card (decklite--card-meta->fsrs-card word meta))
           ;; Simulate the rating to show the interval before the user commits.
           (new-card (cl-nth-value 0
                                   (fsrs-scheduler-review-card
                                    scheduler card rating review-time))))
      (propertize
       (format " (%s)"
               (decklite--format-interval
                (fsrs-timestamp-difference (fsrs-card-due new-card) review-time)))
       'face 'decklite-review-rating-interval-face))))

(defun decklite-review--separator (&optional length)
  "Return the styled separator line for instruction blocks.
When LENGTH is non-nil, use it as the separator width."
  (propertize (make-string (or length 49) ?─)
              'face 'decklite-review-separator-face))

(defun decklite-review-component-title ()
  "Return the centered title line for the review header."
  (decklite-center-text
   (let ((meta (decklite--load-card-meta decklite-current-word)))
     (cond
      ((decklite-card-meta-is-new meta)
       (propertize "NEW WORD" 'face 'decklite-review-status-new-face))
      ((memq (decklite-card-meta-state meta) '(:learning :relearning))
       (propertize "LEARNING" 'face 'decklite-review-status-review-face))
      (t
       (propertize "REVIEWING" 'face 'decklite-review-status-review-face))))))

(defun decklite-review-component-counters ()
  "Return the counter block for the instructions."
  (let* ((n-reviewed (plist-get decklite--counter :reviewed))
         (n-due-review (plist-get decklite--counter :due-review))
         (n-due-learning (plist-get decklite--counter :due-learning))
         (n-new (plist-get decklite--counter :new)))
    (decklite-center-text
     (format "%s reviewed / %s review due / %s learning due / %s new"
             (propertize (number-to-string n-reviewed) 'face 'decklite-review-counter-review-face)
             (propertize (number-to-string n-due-review) 'face 'decklite-review-counter-due-face)
             (propertize (number-to-string n-due-learning) 'face 'decklite-review-counter-due-face)
             (propertize (number-to-string n-new) 'face 'decklite-review-counter-new-face)))))

(defun decklite-review-component-daily-goal ()
  "Insert the daily goal banner in the review buffer."
  (when (and decklite-review-daily-goal (> decklite-review-daily-goal 0))
    (if (decklite-review--daily-goal-reached-p)
        (decklite-center-text (propertize "DAILY GOAL REACHED" 'face 'decklite-review-status-goal-face))
      (let* ((n-reviewed (plist-get decklite--counter :reviewed))
             (goal-progress (/ (float n-reviewed) decklite-review-daily-goal))
             (steps (max 0 decklite-review-daily-goal-progress-steps))
             (n-clicks-completed (decklite--clamp (round (* goal-progress steps)) 0 steps))
             (percentage (format "%.2f%%" (* 100 goal-progress)))
             (progress-bar (concat
                            (make-string n-clicks-completed ?█)
                            (make-string (- steps n-clicks-completed) ?░))))
        (concat
         (decklite-center-text (propertize percentage 'face 'decklite-review-status-progress-face))
         "\n"
         (decklite-center-text (propertize progress-bar 'face 'decklite-review-status-progress-face)))))))

(defun decklite-review-component-rates ()
  "Return the options block for review ratings and commands.
Interval labels are included when
`decklite-review-enable-interval-labels' is non-nil."
  (let* ((meta (decklite--load-card-meta decklite-current-word))
         (option-lines
          (list
           (concat (decklite-review--instruction-key-label 'decklite-review-rate-again)
                   " Again"
                   (decklite-review--instruction-interval-label decklite-current-word meta 1))
           ;; Add one extra space after "Hard", "Good", and "Easy" to make interval labels vertically aligned
           (concat (decklite-review--instruction-key-label 'decklite-review-rate-hard)
                   " Hard "
                   (decklite-review--instruction-interval-label decklite-current-word meta 2))
           (concat (decklite-review--instruction-key-label 'decklite-review-rate-good)
                   " Good "
                   (decklite-review--instruction-interval-label decklite-current-word meta 3))
           (concat (decklite-review--instruction-key-label 'decklite-review-rate-easy)
                   " Easy "
                   (decklite-review--instruction-interval-label decklite-current-word meta 4)))))
    (decklite-center-text (string-join option-lines "\n"))))

(defun decklite-review-component-separator ()
  "Return the separator line for the review components."
  (when (> decklite-review--separator-width 0)
    (decklite-center-text
     (decklite-review--separator decklite-review--separator-width))))

(defun decklite-review-component-linebreak ()
  "Return an empty component that is kept to force a blank line."
  "")

(defun decklite-review-component-word ()
  "Insert the current word in the review buffer."
  (let ((word (propertize decklite-current-word 'face 'decklite-review-word-face)))
    (decklite-center-text word)))

(defun decklite-review-component-hint ()
  "Insert the current word's hint in the review buffer."
  (let ((hint (decklite--current-card-hint)))
    (when hint
      (if decklite-review--state-display-hint
          (decklite-fill-and-center-text hint decklite-review-fill-column)
        (let ((hint-placeholder (propertize "[HINT]" 'face 'decklite-review-hint-placeholder-face)))
          (decklite-center-text hint-placeholder))))))

(defun decklite-review--hide-cursor ()
  "Hide the cursor and hl-line in the review buffer window."
  (when (eq major-mode 'decklite-review-mode)
    ;; Hide cursor
    (setq-local cursor-type nil)
    ;; Disable hl-line-mode for a cleaner UI
    (when (boundp 'hl-line-mode)
      (hl-line-mode -1))
    (when (boundp 'global-hl-line-mode)
      (setq-local global-hl-line-mode nil))))

(defun decklite-review--render-buffer (&optional keep-position)
  "Render the review buffer.
When KEEP-POSITION is non-nil, preserve the window scroll and point."
  (with-current-buffer (get-buffer decklite-review-buffer-name)
    (when decklite-review-hide-cursor
      (decklite-review--hide-cursor))
    (let* ((window (get-buffer-window (current-buffer) 0))
           (saved-point (when (and keep-position window) (window-point window)))
           (saved-start (when (and keep-position window) (window-start window)))
           (render (lambda ()
                     (let ((inhibit-read-only t))
                       (erase-buffer)
                       (insert (decklite-review--render-components))))))
      ;; Render using the review window so centering uses its dimensions.
      (if window
          (with-selected-window window (funcall render))
        (funcall render))
      (if (decklite--current-card-hint)
          (decklite-review--start-hint-timer)
        (decklite-review--cancel-hint-timer))
      (if (and keep-position window)
          (progn
            (set-window-point window (min (or saved-point (point-min)) (point-max)))
            (when saved-start
              (set-window-start window saved-start t)))
        (goto-char (point-min))))))

;; Review flow and rating commands

(defun decklite-review-next-card ()
  "Review the next due card.
When current list is empty, re-check for due cards and continue if any exist."
  (interactive)
  (if (or decklite-due-words (decklite--refresh-due-words))
      (let ((word (pop decklite-due-words)))
        (setq decklite-current-word word)
        (decklite-review--reset-ui-state)
        (run-hooks 'decklite-review-next-card-hook)
        (decklite-review--render-buffer))
    (decklite-review-quit)))

(defun decklite-review-quit ()
  "Quit DeckLite review."
  (interactive)
  (decklite-review--clean-up)
  (when-let ((buffer (get-buffer decklite-review-buffer-name)))
    (kill-buffer buffer))
  (run-hooks 'decklite-review-quit-hook)
  (decklite-db--disconnect-if-idle)
  (message "Review session finished"))

(defun decklite-review--handle-grade (grade)
  "Handle a GRADE input and move on to the next word."
  (let ((word (decklite--require-current-word "rate")))
    (let ((goal-was-reached (decklite-review--daily-goal-reached-p)))
      (decklite-rate-card word grade)
      (when (and (not goal-was-reached)
                 (decklite-review--daily-goal-reached-p))
        (run-hooks 'decklite-review-daily-goal-reached-hook)))
    (let ((rating-text (pcase grade
                         (1 "Again")
                         (2 "Hard")
                         (3 "Good")
                         (4 "Easy")
                         (_ "Unknown"))))
      (message "Rated \"%s\" as (%s)" word rating-text))
    (decklite-review-next-card)))

(defun decklite-review-rate-again ()
  "Rate the current word as `again'."
  (interactive)
  (decklite-review--handle-grade 1))

(defun decklite-review-rate-hard ()
  "Rate the current word as `hard'."
  (interactive)
  (decklite-review--handle-grade 2))

(defun decklite-review-rate-good ()
  "Rate the current word as `good'."
  (interactive)
  (decklite-review--handle-grade 3))

(defun decklite-review-rate-easy ()
  "Rate the current word as `easy'."
  (interactive)
  (decklite-review--handle-grade 4))

(defun decklite-review-refresh ()
  "Refresh the review window."
  (interactive)
  (when decklite-current-word
    (let ((buffer (decklite-review--setup-buffer)))
      (switch-to-buffer buffer)
      (decklite-review--render-buffer))))

(defun decklite-review--edit-card-fields (edit-word edit-hint)
  "Edit the current card using EDIT-WORD and EDIT-HINT flags."
  (unless decklite-current-word
    (user-error "No current word to edit"))
  (setq decklite-current-word
        (decklite-prompt-edit-card-fields decklite-current-word edit-word edit-hint))
  (when (eq major-mode 'decklite-review-mode)
    (decklite-review--render-buffer))
  (message "Updated \"%s\"" decklite-current-word))

(defun decklite-review-edit-word ()
  "Edit the current word."
  (interactive)
  (decklite-review--edit-card-fields t nil))

(defun decklite-review-edit-hint ()
  "Edit the current hint."
  (interactive)
  (decklite-review--edit-card-fields nil t))

(defun decklite-review-delete-card ()
  "Delete the current card from the deck."
  (interactive)
  (if (null decklite-current-word)
      (message "No current word to delete")
    (when (yes-or-no-p (format "Are you sure you want to delete \"%s\" from the deck? " decklite-current-word))
      (decklite-delete-card decklite-current-word)
      (message "Deleted \"%s\" from the deck." decklite-current-word)
      (setq decklite-current-word nil)
      (when (eq major-mode 'decklite-review-mode)
        (decklite-review-next-card)))))

;; Review mode setup

;;;###autoload
(defun decklite-review ()
  "Start a review session."
  (interactive)
  (run-hooks 'decklite-review-start-hook)
  (decklite--refresh-due-words)
  (if (null decklite-due-words)
      (message "No words to review")
    (let ((buffer (decklite-review--setup-buffer)))
      (switch-to-buffer buffer)
      (decklite--refresh-counter)
      (decklite-review-next-card))))

;; Keep review UI in sync when a hint is added via the quick add flow.
;; This runs only in review buffers and only when the last-added word is
;; the current review word, so other contexts stay unaffected.
(defun decklite-review--maybe-refresh-after-add-hint (&rest _)
  "Refresh the review buffer after adding a hint for the current word."
  (when (and (eq major-mode 'decklite-review-mode)
             decklite-current-word
             decklite-last-added-word
             (string-equal decklite-current-word decklite-last-added-word))
    (decklite-review--render-buffer t)))

;; Use advice to make the logic less entangled.
;; This refresh logic is solely for the review mode.
(advice-add 'decklite-add-hint :after #'decklite-review--maybe-refresh-after-add-hint)

;; Backup
(add-hook 'decklite-review-start-hook #'decklite-db-backup)
(add-hook 'decklite-review-quit-hook #'decklite-db-backup)
;; Auto-refresh
(add-hook 'decklite-review-start-hook #'decklite-review--enable-resize-refresh)
(add-hook 'decklite-review-quit-hook #'decklite-review--disable-resize-refresh)

(define-derived-mode decklite-review-mode special-mode "DeckLite-Review"
  "Major mode for reviewing vocabulary with FSRS algorithm."
  (setq buffer-read-only t)
  (buffer-disable-undo))

(provide 'decklite-review)
;;; decklite-review.el ends here

;;; decklet-review.el --- Review mode for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Review UI and FSRS grading flow.

;;; Code:

(require 'ansi-color)
(require 'cl-lib)
(require 'seq)

(require 'decklet-db)
(require 'decklet-deck)

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
    decklet-review-component-hint)
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
     :foreground ,(face-attribute 'ansi-color-red :foreground)
     :weight bold
     :height 1.5)
    (((type tty))
     :inherit default
     :foreground ,(face-attribute 'ansi-color-red :foreground)
     :weight bold
     :height 1.0))
  "Face for displaying the current word."
  :group 'decklet-review)

(defface decklet-review-status-new-face
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
  :group 'decklet-review)

(defface decklet-review-status-review-face
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
  :group 'decklet-review)

(defface decklet-review-counter-new-face
  `((t :foreground ,(face-attribute 'ansi-color-magenta :foreground)
       :weight bold :underline t))
  "Face for displaying the number of new words."
  :group 'decklet-review)

(defface decklet-review-counter-review-face
  `((t :foreground ,(face-attribute 'ansi-color-green :foreground)
       :weight bold :underline t))
  "Face for displaying the number of due words."
  :group 'decklet-review)

(defface decklet-review-counter-due-face
  `((t :foreground ,(face-attribute 'ansi-color-yellow :foreground)
       :weight bold :underline t))
  "Face for displaying the number of reviewed words today."
  :group 'decklet-review)

(defface decklet-review-status-goal-face
  `((t :foreground ,(face-attribute 'ansi-color-green :foreground)
       :weight bold))
  "Face for displaying the `DAILY GOAL REACHED' status."
  :group 'decklet-review)

(defface decklet-review-status-progress-face
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
    "t" #'decklet-review-edit-hint)
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
ITEMS contains (TEXT . SEPARATOR) pairs.  Leading or consecutive separators
are skipped so rendering won't stack separator lines."
  (let (items)
    (dolist (fn components)
      (let ((text (funcall fn))
            (separator (eq fn 'decklet-review-component-separator)))
        (when text
          (unless (and separator (or last-was-sep (null items)))
            (push (cons text separator) items)
            (setq last-was-sep separator)))))
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
             (top-n-lines (max 0 (- half-body-h line-count 0))))
        (concat (make-string top-n-lines ?\n) fixed-text floating-text)))))

(defun decklet-review--render-components ()
  "Render fixed and floating components with vertical centering for fixed ones."
  (let* ((content-components (seq-remove (lambda (fn)
                                           (eq fn 'decklet-review-component-separator))
                                         (append decklet-review-fixed-components
                                                 decklet-review-floating-components)))
         (content-texts (delq nil (mapcar #'funcall content-components))))
    (if (null content-texts)
        ""
      ;; Update separator width.
      ;; Width is based on content only so separators match visible text.
      (setq decklet-review--separator-width
            (seq-reduce
             #'max
             (mapcar #'decklet--string-max-line-width content-texts)
             0))
      (let* ((fixed-result (decklet-review--collect-component-items decklet-review-fixed-components))
             (fixed-items (car fixed-result))
             ;; Track if the fixed block ended with a separator so we
             ;; do not stack separators between fixed and floating blocks.
             (last-was-sep (cdr fixed-result))
             (floating-result (decklet-review--collect-component-items decklet-review-floating-components last-was-sep))
             (floating-items (car floating-result)))
        (decklet-review--render-with-vertical-center fixed-items floating-items)))))

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
    (let* ((scheduler (decklet--get-fsrs-scheduler))
           (rating (decklet--fsrs-rating-from-grade grade))
           (review-time (fsrs-now))
           (card (decklet--card-meta->fsrs-card word meta))
           ;; Simulate the rating to show the interval before the user commits.
           (new-card (cl-nth-value 0
                                   (fsrs-scheduler-review-card
                                    scheduler card rating review-time))))
      (propertize
       (format " (%s)"
               (decklet--format-interval
                (fsrs-timestamp-difference (fsrs-card-due new-card) review-time)))
       'face 'decklet-review-rating-interval-face))))

(defun decklet-review--separator (&optional length)
  "Return the styled separator line for instruction blocks.
When LENGTH is non-nil, use it as the separator width."
  (propertize (make-string (or length 49) ?─)
              'face 'decklet-review-separator-face))

(defun decklet-review-component-title ()
  "Return the centered title line for the review header."
  (decklet-center-text
   (let ((meta (decklet--load-card-meta decklet-current-word)))
     (cond
      ((decklet-card-meta-is-new meta)
       (propertize "NEW WORD" 'face 'decklet-review-status-new-face))
      ((memq (decklet-card-meta-state meta) '(:learning :relearning))
       (propertize "LEARNING" 'face 'decklet-review-status-review-face))
      (t
       (propertize "REVIEWING" 'face 'decklet-review-status-review-face))))))

(defun decklet-review-component-counters ()
  "Return the counter block for the instructions."
  (let* ((n-reviewed (plist-get decklet--counter :reviewed))
         (n-due-review (plist-get decklet--counter :due-review))
         (n-due-learning (plist-get decklet--counter :due-learning))
         (n-new (plist-get decklet--counter :new)))
    (decklet-center-text
     (format "%s reviewed / %s review due / %s learning due / %s new"
             (propertize (number-to-string n-reviewed) 'face 'decklet-review-counter-review-face)
             (propertize (number-to-string n-due-review) 'face 'decklet-review-counter-due-face)
             (propertize (number-to-string n-due-learning) 'face 'decklet-review-counter-due-face)
             (propertize (number-to-string n-new) 'face 'decklet-review-counter-new-face)))))

(defun decklet-review-component-daily-goal ()
  "Insert the daily goal banner in the review buffer."
  (when (and decklet-review-daily-goal (> decklet-review-daily-goal 0))
    (if (decklet-review--daily-goal-reached-p)
        (decklet-center-text (propertize "DAILY GOAL REACHED" 'face 'decklet-review-status-goal-face))
      (let* ((n-reviewed (plist-get decklet--counter :reviewed))
             (goal-progress (/ (float n-reviewed) decklet-review-daily-goal))
             (steps (max 0 decklet-review-daily-goal-progress-steps))
             (n-clicks-completed (decklet--clamp (round (* goal-progress steps)) 0 steps))
             (percentage (format "%.2f%%" (* 100 goal-progress)))
             (progress-bar (concat
                            (make-string n-clicks-completed ?█)
                            (make-string (- steps n-clicks-completed) ?░))))
        (concat
         (decklet-center-text (propertize percentage 'face 'decklet-review-status-progress-face))
         "\n"
         (decklet-center-text (propertize progress-bar 'face 'decklet-review-status-progress-face)))))))

(defun decklet-review-component-rates ()
  "Return the options block for review ratings and commands.
Interval labels are included when
`decklet-review-enable-interval-labels' is non-nil."
  (let* ((meta (decklet--load-card-meta decklet-current-word))
         (option-lines
          (list
           (concat (decklet-review--instruction-key-label 'decklet-review-rate-again)
                   " Again"
                   (decklet-review--instruction-interval-label decklet-current-word meta 1))
           (concat (decklet-review--instruction-key-label 'decklet-review-rate-hard)
                   " Hard"
                   (decklet-review--instruction-interval-label decklet-current-word meta 2))
           (concat (decklet-review--instruction-key-label 'decklet-review-rate-good)
                   " Good"
                   (decklet-review--instruction-interval-label decklet-current-word meta 3))
           (concat (decklet-review--instruction-key-label 'decklet-review-rate-easy)
                   " Easy"
                   (decklet-review--instruction-interval-label decklet-current-word meta 4)))))
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
  (let ((hint (decklet--current-card-hint)))
    (when hint
      (if decklet-review--state-display-hint
          (decklet-fill-and-center-text hint decklet-review-fill-column)
        (let ((hint-placeholder (propertize "[HINT]" 'face 'decklet-review-hint-placeholder-face)))
          (decklet-center-text hint-placeholder))))))

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
    (let* ((window (get-buffer-window (current-buffer) 0))
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
      (if (decklet--current-card-hint)
          (decklet-review--start-hint-timer)
        (decklet-review--cancel-hint-timer))
      (if (and keep-position window)
          (progn
            (set-window-point window (min (or saved-point (point-min)) (point-max)))
            (when saved-start
              (set-window-start window saved-start t)))
        (goto-char (point-min))))))

;; Review flow and rating commands

(defun decklet-review-next-card ()
  "Review the next due card.
When current list is empty, re-check for due cards and continue if any exist."
  (interactive)
  (if (or decklet-due-words (decklet--refresh-due-words))
      (let ((word (pop decklet-due-words)))
        (setq decklet-current-word word)
        (decklet-review--reset-ui-state)
        (run-hooks 'decklet-review-next-card-hook)
        (decklet-review--render-buffer))
    (decklet-review-quit)))

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
  (let ((word (decklet--require-current-word "rate")))
    (let ((goal-was-reached (decklet-review--daily-goal-reached-p)))
      (decklet-rate-card word grade)
      (when (and (not goal-was-reached)
                 (decklet-review--daily-goal-reached-p))
        (run-hooks 'decklet-review-daily-goal-reached-hook)))
    (let ((rating-text (pcase grade
                         (1 "Again")
                         (2 "Hard")
                         (3 "Good")
                         (4 "Easy")
                         (_ "Unknown"))))
      (message "Rated \"%s\" as (%s)" word rating-text))
    (decklet-review-next-card)))

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
  (if (null decklet-current-word)
      (message "No current word to delete")
    (when (yes-or-no-p (format "Are you sure you want to delete \"%s\" from the deck? " decklet-current-word))
      (decklet-delete-card decklet-current-word)
      (message "Deleted \"%s\" from the deck." decklet-current-word)
      (setq decklet-current-word nil)
      (when (eq major-mode 'decklet-review-mode)
        (decklet-review-next-card)))))

;; Review mode setup

;;;###autoload
(defun decklet-review ()
  "Start a review session."
  (interactive)
  (run-hooks 'decklet-review-start-hook)
  (decklet--refresh-due-words)
  (if (null decklet-due-words)
      (progn
        (decklet-review-quit)
        (message "No words to review"))
    (let ((buffer (decklet-review--setup-buffer)))
      (switch-to-buffer buffer)
      (decklet--refresh-counter)
      (decklet-review-next-card))))

;; Keep review UI in sync when a hint is added via the quick add flow.
;; This runs only in review buffers and only when the last-added word is
;; the current review word, so other contexts stay unaffected.
(defun decklet-review--maybe-refresh-after-add-hint (&rest _)
  "Refresh the review buffer after adding a hint for the current word."
  (when (and (eq major-mode 'decklet-review-mode)
             decklet-current-word
             decklet-last-added-word
             (string-equal decklet-current-word decklet-last-added-word))
    (decklet-review--render-buffer t)))

;; Use advice to make the logic less entangled.
;; This refresh logic is solely for the review mode.
(advice-add 'decklet-add-hint :after #'decklet-review--maybe-refresh-after-add-hint)

;; Backup
(add-hook 'decklet-review-start-hook #'decklet-db-backup)
(add-hook 'decklet-review-quit-hook #'decklet-db-backup)
;; Auto-refresh
(add-hook 'decklet-review-start-hook #'decklet-review--enable-resize-refresh)
(add-hook 'decklet-review-quit-hook #'decklet-review--disable-resize-refresh)

(define-derived-mode decklet-review-mode special-mode "Decklet-Review"
  "Major mode for reviewing vocabulary with FSRS algorithm."
  (setq buffer-read-only t)
  (buffer-disable-undo))

(provide 'decklet-review)
;;; decklet-review.el ends here

;;; decklite-dictionary.el --- Dictionary integration for DeckLite -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Browser lookup, API definition, and pronunciation audio.

;;; Code:

(require 'ansi-color)
(require 'seq)
(require 'subr-x)
(require 'url)

(require 'decklite-core)
(require 'decklite-schedular)
(require 'decklite-deck)
(require 'decklite-edit)
(require 'decklite-review)

(defgroup decklite-dictionary nil
  "Dictionary integration for DeckLite."
  :group 'decklite)

(defcustom decklite-dictionary-audio-cache-dir
  (expand-file-name "audio-cache" decklite-directory)
  "Audio cache directory."
  :type 'file
  :group 'decklite-dictionary)

(defcustom decklite-lookup-providers
  '(("Google" . "https://www.google.com/search?q=define:%s")
    ("Merriam-Webster" . "https://www.merriam-webster.com/dictionary/%s")
    ("Oxford Learner's" . "https://www.oxfordlearnersdictionaries.com/definition/english/%s")
    ("Cambridge" . "https://dictionary.cambridge.org/dictionary/english/%s")
    ("Wiktionary" . "https://en.wiktionary.org/wiki/%s"))
  "Alist of word lookup providers.
Each entry is (NAME . URL), where URL expects a single %s for the word."
  :type '(alist :key-type string :value-type string)
  :group 'decklite-dictionary)

(defcustom decklite-lookup-default-provider "Google"
  "Default provider name used for word lookups."
  :type 'string
  :group 'decklite-dictionary)

(defcustom decklite-dictionary-define-function
  #'decklite-dictionary-default-define-function
  "Function to define WORD and return a formatted string.
The function takes a WORD string and returns a propertized string for display.
Caching is handled by `decklite-define'."
  :type 'function
  :group 'decklite-dictionary)

(defcustom decklite-dictionary-audio-function
  #'decklite-dictionary-default-audio-function
  "Function to return a local audio file path for WORD.
The function should take a WORD string and return a local file path or nil.
Caching is handled by `decklite-speak'."
  :type 'function
  :group 'decklite-dictionary)

(defcustom decklite-lookup-hook nil
  "Hook run after browser lookup is opened."
  :type 'hook
  :group 'decklite-dictionary)

(defcustom decklite-define-hook nil
  "Hook run after `decklite-define' prepares definition content."
  :type 'hook
  :group 'decklite-dictionary)

(defface decklite-dictionary-word-face
  `((t :foreground ,(face-attribute 'ansi-color-red :foreground)
       :weight bold))
  "Face for displaying the word in dictionary buffer."
  :group 'decklite-dictionary)

(defvar decklite-dictionary-buffer-name "*DeckLite Definition*"
  "Name of the buffer used to display dictionary definitions.")

(defvar decklite-dictionary-cache-definition (make-hash-table :test 'equal)
  "Cache for `decklite-dictionary-define-function'.")

(defvar decklite-dictionary-cache-audio (make-hash-table :test 'equal)
  "Cache for `decklite-dictionary-audio-function'.")

;;;###autoload
(defun decklite-lookup (word &optional provider)
  "Lookup WORD in the browser using PROVIDER.
PROVIDER should be a key in `decklite-lookup-providers`.
When PROVIDER is nil, use `decklite-lookup-default-provider`."
  (interactive (list nil nil))
  (let* ((word (decklite--resolve-word word "Lookup word: "))
         (provider (or provider decklite-lookup-default-provider))
         (url-template (cdr (assoc provider decklite-lookup-providers))))
    (unless url-template
      (user-error "Unknown provider: %s" provider))
    (browse-url (format url-template (url-hexify-string word)))
    (run-hooks 'decklite-lookup-hook)))

;;;###autoload
(defun decklite-lookup-with-provider (word &optional provider)
  "Lookup WORD using a selected PROVIDER.
When WORD or PROVIDER is nil, prompt for them."
  (interactive (list nil nil))
  (let ((word (decklite--resolve-word word "Lookup word: "))
        (provider (or provider
                      (completing-read "Lookup provider: "
                                       (mapcar #'car decklite-lookup-providers)
                                       nil t))))
    (decklite-lookup word provider)))

;; Dictionary API helpers

(define-derived-mode decklite-dictionary-mode special-mode "DeckLite-Dictionary"
  "Major mode for DeckLite dictionary popups.")

(defun decklite-dictionary--close-buffer ()
  "Close the dictionary buffer and window if present."
  (let ((buffer (get-buffer decklite-dictionary-buffer-name)))
    (when buffer
      (when-let ((window (get-buffer-window buffer)))
        (quit-window t window))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun decklite-dictionary--display (content &optional focus-popup)
  "Display dictionary CONTENT in a dedicated buffer.
When FOCUS-POPUP is non-nil, focus the popup window; otherwise keep focus."
  (let ((buffer (get-buffer-create decklite-dictionary-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert content)
        (goto-char (point-min))
        (decklite-dictionary-mode)))
    (if focus-popup
        (pop-to-buffer buffer '(display-buffer-pop-up-window))
      (save-selected-window
        (display-buffer buffer '(display-buffer-pop-up-window))))
    buffer))

(defun decklite-dictionary--fetch-definition (url &optional method headers body)
  "Fetch definition data from URL.
METHOD, HEADERS, and BODY override the request defaults.
Returns parsed JSON data or nil if request fails or JSON is invalid."
  (let* ((url-request-method (or method "GET"))
         (url-request-extra-headers headers)
         (url-request-data body)
         (buffer (condition-case err
                     (url-retrieve-synchronously url t nil 10)
                   (error
                    (message "Error fetching definition: %s" (error-message-string err))
                    nil))))
    (when buffer
      (with-current-buffer buffer
        (goto-char (point-min))
        ;; Skip HTTP headers before parsing the JSON body.
        (when (re-search-forward "^$" nil t)
          (let* ((json-string (buffer-substring-no-properties (point) (point-max)))
                 (parsed-data (decklite--json-parse-safe json-string "Error parsing JSON")))
            (kill-buffer buffer)
            parsed-data))))))

(defun decklite-dictionary--format-phonetics (phonetics)
  "Format PHONETICS data into a readable string."
  (when phonetics
    (let ((phonetic-texts (delq nil (mapcar (lambda (p) (alist-get 'text p)) phonetics))))
      (when phonetic-texts
        (format "Pronunciation: %s\n" (string-join phonetic-texts ", "))))))

(defun decklite-dictionary--format-meanings (meanings)
  "Format MEANINGS data into a readable string."
  (mapconcat
   (lambda (meaning)
     (let ((part-of-speech (alist-get 'partOfSpeech meaning))
           (definitions (alist-get 'definitions meaning)))
       (concat
        (format "\n%s:\n" (capitalize part-of-speech))
        (mapconcat
         (lambda (def)
           (let ((definition (alist-get 'definition def))
                 (example (alist-get 'example def)))
             (concat
              (format "  • %s" definition)
              (when example
                (format "\n    Example: \"%s\"" example)))))
         definitions
         "\n"))))
   meanings
   "\n"))

(defun decklite-dictionary-default-define-function (word)
  "Return a formatted definition string for WORD using Dictionary API."
  (let* ((url (format "https://api.dictionaryapi.dev/api/v2/entries/en/%s"
                      (url-hexify-string word)))
         (result (decklite-dictionary--fetch-definition url)))
    (cond
     ((not result)
      (format "No definition found for \"%s\"." word))
     ((and (listp result) (alist-get 'title result))
      ;; Some error payloads come back as JSON objects instead of vectors.
      (format "No definition found for \"%s\". Try browser lookup instead." word))
     ((not (vectorp result))
      (format "No definition found for \"%s\"." word))
     (t
      (let* ((entry (aref result 0))
             (word-text (alist-get 'word entry))
             (phonetics (alist-get 'phonetics entry))
             (meanings (alist-get 'meanings entry)))
        (concat
         (format "Word: %s\n"
                 (propertize word-text 'face 'decklite-dictionary-word-face))
         (or (decklite-dictionary--format-phonetics phonetics) "")
         (decklite-dictionary--format-meanings meanings)))))))

(defun decklite-dictionary-default-audio-function (word)
  "Return a local audio file path for WORD using Dictionary API."
  (when-let* ((url (format "https://api.dictionaryapi.dev/api/v2/entries/en/%s"
                           (url-hexify-string word)))
              (result (decklite-dictionary--fetch-definition url))
              (entry (and (vectorp result) (> (length result) 0) (aref result 0)))
              (phonetics (alist-get 'phonetics entry))
              (audio-url (seq-find (lambda (phonetic)
                                     (let ((audio (alist-get 'audio phonetic)))
                                       (and audio (not (string-empty-p audio)))))
                                   phonetics))
              (audio-url (alist-get 'audio audio-url)))
    (make-directory decklite-dictionary-audio-cache-dir t)
    (let* ((file-extension (or (file-name-extension audio-url) "mp3"))
           (hash (secure-hash 'sha1 audio-url))
           (target (expand-file-name (format "%s.%s" hash file-extension)
                                     decklite-dictionary-audio-cache-dir)))
      (unless (file-exists-p target)
        (condition-case err
            (url-copy-file audio-url target t)
          (error
           (message "Failed to download audio: %s" (error-message-string err))
           (setq target nil))))
      (and (file-exists-p target) target))))

;;;###autoload
(defun decklite-define (word &optional popup focus-popup)
  "Define WORD and return formatted result.
Ignores audio links and focuses on definitions and phonetics.
When POPUP is non-nil, show the definition in a popup buffer.
When FOCUS-POPUP is non-nil, focus the popup window; otherwise keep focus."
  (interactive (list nil nil nil))
  (let* ((word (decklite--resolve-word word "Define word: "))
         (popup (or popup (called-interactively-p 'any)))
         ;; Always focus popup if its called interactively.
         ;; The popup window can be easily closed by pressing "q",
         (focus-popup (or (called-interactively-p 'any)
                          focus-popup))
         (cached (gethash word decklite-dictionary-cache-definition))
         (result (or cached
                     (when (functionp decklite-dictionary-define-function)
                       (funcall decklite-dictionary-define-function word))
                     (format "Dictionary define function is not set for \"%s\"." word))))
    ;; Ensure result is a string
    (unless (stringp result)
      (setq result (format "Dictionary define function returned invalid data for \"%s\"." word)))
    ;; Cache new results
    (unless cached
      (puthash word result decklite-dictionary-cache-definition))
    ;; Run hooks
    (run-hooks 'decklite-define-hook)
    ;; Display in popup if requested
    (when popup
      (decklite-dictionary--display result focus-popup))
    result))

;;;###autoload
(defun decklite-speak (word &optional audio-player)
  "Play pronunciation audio for WORD using `decklite-dictionary-audio-function'.
Downloads and caches audio files locally for better compatibility.
AUDIO-PLAYER specifies the command to play audio (defaults to system default)."
  (interactive (list nil nil))
  (let* ((word (decklite--resolve-word word "Pronounce word: "))
         (cached (gethash word decklite-dictionary-cache-audio))
         (audio-path (if (and (stringp cached) (file-exists-p cached))
                         cached
                       (when (functionp decklite-dictionary-audio-function)
                         (funcall decklite-dictionary-audio-function word))))
         (player (or audio-player
                     (executable-find "afplay")
                     (executable-find "mpv")
                     (if (eq system-type 'windows-nt) "start" "mpv"))))
    (cond
     ((and audio-path (file-exists-p audio-path))
      (puthash word audio-path decklite-dictionary-cache-audio)
      (message "Playing pronunciation of \"%s\"..." word)
      (start-process "decklite-audio" nil player audio-path))
     ((not (functionp decklite-dictionary-audio-function))
      (message "Dictionary audio function is not set for \"%s\"" word))
     (t
      (message "No audio pronunciation available for \"%s\"" word)))))

;;;###autoload
(defun decklite-clear-audio-cache ()
  "Clear the audio cache directory."
  (interactive)
  (when (file-directory-p decklite-dictionary-audio-cache-dir)
    (delete-directory decklite-dictionary-audio-cache-dir t)
    (message "Audio cache cleared"))
  (unless (file-directory-p decklite-dictionary-audio-cache-dir)
    (message "Audio cache was already empty")))

;;;###autoload
(defun decklite-clear-api-cache ()
  "Clear the in-memory dictionary cache.
This is a no-op unless your custom functions use their own caches."
  (interactive)
  (clrhash decklite-dictionary-cache-definition)
  (clrhash decklite-dictionary-cache-audio)
  (when (called-interactively-p 'any)
    (message "Dictionary cache cleared")))

;; Automatically close the dictionary buffer for a better review flow
(add-hook 'decklite-review-quit-hook #'decklite-dictionary--close-buffer)
(add-hook 'decklite-review-next-card-hook #'decklite-dictionary--close-buffer)
(add-hook 'decklite-edit-quit-hook #'decklite-dictionary--close-buffer)
;; Clear API cache but still keep audio cache
(add-hook 'decklite-review-quit-hook #'decklite-clear-api-cache)
(add-hook 'decklite-edit-quit-hook #'decklite-clear-api-cache)

;; Default keybindings

(dolist (binding '(("l" . decklite-lookup)
                   ("L" . decklite-lookup-with-provider)
                   ("f" . decklite-define)
                   ("s" . decklite-speak)))
  (keymap-set decklite-review-mode-map (car binding) (cdr binding))
  (keymap-set decklite-edit-mode-map (car binding) (cdr binding)))

(provide 'decklite-dictionary)
;;; decklite-dictionary.el ends here

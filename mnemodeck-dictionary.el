;;; mnemodeck-dictionary.el --- Dictionary integration for MnemoDeck -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Browser lookup, API definition, and pronunciation audio.

;;; Code:

(require 'ansi-color)
(require 'seq)
(require 'subr-x)
(require 'url)

(require 'mnemodeck-core)
(require 'mnemodeck-schedular)
(require 'mnemodeck-deck)
(require 'mnemodeck-edit)
(require 'mnemodeck-review)

(defgroup mnemodeck-dictionary nil
  "Dictionary integration for MnemoDeck."
  :group 'mnemodeck)

(defcustom mnemodeck-dictionary-audio-cache-dir
  (expand-file-name "audio-cache" mnemodeck-directory)
  "Audio cache directory."
  :type 'file
  :group 'mnemodeck-dictionary)

(defcustom mnemodeck-lookup-providers
  '(("Google" . "https://www.google.com/search?q=define:%s")
    ("Merriam-Webster" . "https://www.merriam-webster.com/dictionary/%s")
    ("Oxford Learner's" . "https://www.oxfordlearnersdictionaries.com/definition/english/%s")
    ("Cambridge" . "https://dictionary.cambridge.org/dictionary/english/%s")
    ("Wiktionary" . "https://en.wiktionary.org/wiki/%s"))
  "Alist of word lookup providers.
Each entry is (NAME . URL), where URL expects a single %s for the word."
  :type '(alist :key-type string :value-type string)
  :group 'mnemodeck-dictionary)

(defcustom mnemodeck-lookup-default-provider "Google"
  "Default provider name used for word lookups."
  :type 'string
  :group 'mnemodeck-dictionary)

(defcustom mnemodeck-dictionary-define-function
  #'mnemodeck-dictionary-default-define-function
  "Function to define WORD and return a formatted string.
The function takes a WORD string and returns a propertized string for display.
Caching is handled by `mnemodeck-define'."
  :type 'function
  :group 'mnemodeck-dictionary)

(defcustom mnemodeck-dictionary-audio-function
  #'mnemodeck-dictionary-default-audio-function
  "Function to return a local audio file path for WORD.
The function should take a WORD string and return a local file path or nil.
Caching is handled by `mnemodeck-speak'."
  :type 'function
  :group 'mnemodeck-dictionary)

(defcustom mnemodeck-lookup-hook nil
  "Hook run after browser lookup is opened."
  :type 'hook
  :group 'mnemodeck-dictionary)

(defcustom mnemodeck-define-hook nil
  "Hook run after `mnemodeck-define' prepares definition content."
  :type 'hook
  :group 'mnemodeck-dictionary)

(defface mnemodeck-dictionary-word-face
  `((t :foreground ,(face-attribute 'ansi-color-red :foreground)
       :weight bold))
  "Face for displaying the word in dictionary buffer."
  :group 'mnemodeck-dictionary)

(defvar mnemodeck-dictionary-buffer-name "*MnemoDeck Definition*"
  "Name of the buffer used to display dictionary definitions.")

(defvar mnemodeck-dictionary-cache-definition (make-hash-table :test 'equal)
  "Cache for `mnemodeck-dictionary-define-function'.")

(defvar mnemodeck-dictionary-cache-audio (make-hash-table :test 'equal)
  "Cache for `mnemodeck-dictionary-audio-function'.")

;;;###autoload
(defun mnemodeck-lookup (word &optional provider)
  "Lookup WORD in the browser using PROVIDER.
PROVIDER should be a key in `mnemodeck-lookup-providers`.
When PROVIDER is nil, use `mnemodeck-lookup-default-provider`."
  (interactive (list nil nil))
  (let* ((word (mnemodeck--resolve-word word "Lookup word: "))
         (provider (or provider mnemodeck-lookup-default-provider))
         (url-template (cdr (assoc provider mnemodeck-lookup-providers))))
    (unless url-template
      (user-error "Unknown provider: %s" provider))
    (browse-url (format url-template (url-hexify-string word)))
    (run-hooks 'mnemodeck-lookup-hook)))

;;;###autoload
(defun mnemodeck-lookup-with-provider (word &optional provider)
  "Lookup WORD using a selected PROVIDER.
When WORD or PROVIDER is nil, prompt for them."
  (interactive (list nil nil))
  (let ((word (mnemodeck--resolve-word word "Lookup word: "))
        (provider (or provider
                      (completing-read "Lookup provider: "
                                       (mapcar #'car mnemodeck-lookup-providers)
                                       nil t))))
    (mnemodeck-lookup word provider)))

;; Dictionary API helpers

(define-derived-mode mnemodeck-dictionary-mode special-mode "MnemoDeck-Dictionary"
  "Major mode for MnemoDeck dictionary popups.")

(defun mnemodeck-dictionary--close-buffer ()
  "Close the dictionary buffer and window if present."
  (let ((buffer (get-buffer mnemodeck-dictionary-buffer-name)))
    (when buffer
      (when-let ((window (get-buffer-window buffer)))
        (quit-window t window))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun mnemodeck-dictionary--display (content &optional focus-popup)
  "Display dictionary CONTENT in a dedicated buffer.
When FOCUS-POPUP is non-nil, focus the popup window; otherwise keep focus."
  (let ((buffer (get-buffer-create mnemodeck-dictionary-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert content)
        (goto-char (point-min))
        (mnemodeck-dictionary-mode)))
    (if focus-popup
        (pop-to-buffer buffer '(display-buffer-pop-up-window))
      (save-selected-window
        (display-buffer buffer '(display-buffer-pop-up-window))))
    buffer))

(defun mnemodeck-dictionary--fetch-definition (url &optional method headers body)
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
                 (parsed-data (mnemodeck--json-parse-safe json-string "Error parsing JSON")))
            (kill-buffer buffer)
            parsed-data))))))

(defun mnemodeck-dictionary--format-phonetics (phonetics)
  "Format PHONETICS data into a readable string."
  (when phonetics
    (let ((phonetic-texts (delq nil (mapcar (lambda (p) (alist-get 'text p)) phonetics))))
      (when phonetic-texts
        (format "Pronunciation: %s\n" (string-join phonetic-texts ", "))))))

(defun mnemodeck-dictionary--format-meanings (meanings)
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

(defun mnemodeck-dictionary-default-define-function (word)
  "Return a formatted definition string for WORD using Dictionary API."
  (let* ((url (format "https://api.dictionaryapi.dev/api/v2/entries/en/%s"
                      (url-hexify-string word)))
         (result (mnemodeck-dictionary--fetch-definition url)))
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
                 (propertize word-text 'face 'mnemodeck-dictionary-word-face))
         (or (mnemodeck-dictionary--format-phonetics phonetics) "")
         (mnemodeck-dictionary--format-meanings meanings)))))))

(defun mnemodeck-dictionary-default-audio-function (word)
  "Return a local audio file path for WORD using Dictionary API."
  (when-let* ((url (format "https://api.dictionaryapi.dev/api/v2/entries/en/%s"
                           (url-hexify-string word)))
              (result (mnemodeck-dictionary--fetch-definition url))
              (entry (and (vectorp result) (> (length result) 0) (aref result 0)))
              (phonetics (alist-get 'phonetics entry))
              (audio-url (seq-find (lambda (phonetic)
                                     (let ((audio (alist-get 'audio phonetic)))
                                       (and audio (not (string-empty-p audio)))))
                                   phonetics))
              (audio-url (alist-get 'audio audio-url)))
    (make-directory mnemodeck-dictionary-audio-cache-dir t)
    (let* ((file-extension (or (file-name-extension audio-url) "mp3"))
           (hash (secure-hash 'sha1 audio-url))
           (target (expand-file-name (format "%s.%s" hash file-extension)
                                     mnemodeck-dictionary-audio-cache-dir)))
      (unless (file-exists-p target)
        (condition-case err
            (url-copy-file audio-url target t)
          (error
           (message "Failed to download audio: %s" (error-message-string err))
           (setq target nil))))
      (and (file-exists-p target) target))))

;;;###autoload
(defun mnemodeck-define (word &optional popup focus-popup)
  "Define WORD and return formatted result.
Ignores audio links and focuses on definitions and phonetics.
When POPUP is non-nil, show the definition in a popup buffer.
When FOCUS-POPUP is non-nil, focus the popup window; otherwise keep focus."
  (interactive (list nil nil nil))
  (let* ((word (mnemodeck--resolve-word word "Define word: "))
         (popup (or popup (called-interactively-p 'any)))
         ;; Always focus popup if its called interactively.
         ;; The popup window can be easily closed by pressing "q",
         (focus-popup (or (called-interactively-p 'any)
                          focus-popup))
         (cached (gethash word mnemodeck-dictionary-cache-definition))
         (result (or cached
                     (when (functionp mnemodeck-dictionary-define-function)
                       (funcall mnemodeck-dictionary-define-function word))
                     (format "Dictionary define function is not set for \"%s\"." word))))
    ;; Ensure result is a string
    (unless (stringp result)
      (setq result (format "Dictionary define function returned invalid data for \"%s\"." word)))
    ;; Cache new results
    (unless cached
      (puthash word result mnemodeck-dictionary-cache-definition))
    ;; Run hooks
    (run-hooks 'mnemodeck-define-hook)
    ;; Display in popup if requested
    (when popup
      (mnemodeck-dictionary--display result focus-popup))
    result))

;;;###autoload
(defun mnemodeck-speak (word &optional audio-player)
  "Play pronunciation audio for WORD using `mnemodeck-dictionary-audio-function'.
Downloads and caches audio files locally for better compatibility.
AUDIO-PLAYER specifies the command to play audio (defaults to system default)."
  (interactive (list nil nil))
  (let* ((word (mnemodeck--resolve-word word "Pronounce word: "))
         (cached (gethash word mnemodeck-dictionary-cache-audio))
         (audio-path (if (and (stringp cached) (file-exists-p cached))
                         cached
                       (when (functionp mnemodeck-dictionary-audio-function)
                         (funcall mnemodeck-dictionary-audio-function word))))
         (player (or audio-player
                     (executable-find "afplay")
                     (executable-find "mpv")
                     (if (eq system-type 'windows-nt) "start" "mpv"))))
    (cond
     ((and audio-path (file-exists-p audio-path))
      (puthash word audio-path mnemodeck-dictionary-cache-audio)
      (message "Playing pronunciation of \"%s\"..." word)
      (start-process "mnemodeck-audio" nil player audio-path))
     ((not (functionp mnemodeck-dictionary-audio-function))
      (message "Dictionary audio function is not set for \"%s\"" word))
     (t
      (message "No audio pronunciation available for \"%s\"" word)))))

;;;###autoload
(defun mnemodeck-clear-audio-cache ()
  "Clear the audio cache directory."
  (interactive)
  (when (file-directory-p mnemodeck-dictionary-audio-cache-dir)
    (delete-directory mnemodeck-dictionary-audio-cache-dir t)
    (message "Audio cache cleared"))
  (unless (file-directory-p mnemodeck-dictionary-audio-cache-dir)
    (message "Audio cache was already empty")))

;;;###autoload
(defun mnemodeck-clear-api-cache ()
  "Clear the in-memory dictionary cache.
This is a no-op unless your custom functions use their own caches."
  (interactive)
  (clrhash mnemodeck-dictionary-cache-definition)
  (clrhash mnemodeck-dictionary-cache-audio)
  (when (called-interactively-p 'any)
    (message "Dictionary cache cleared")))

;; Automatically close the dictionary buffer for a better review flow
(add-hook 'mnemodeck-review-quit-hook #'mnemodeck-dictionary--close-buffer)
(add-hook 'mnemodeck-review-next-card-hook #'mnemodeck-dictionary--close-buffer)
(add-hook 'mnemodeck-edit-quit-hook #'mnemodeck-dictionary--close-buffer)
;; Clear API cache but still keep audio cache
(add-hook 'mnemodeck-review-quit-hook #'mnemodeck-clear-api-cache)
(add-hook 'mnemodeck-edit-quit-hook #'mnemodeck-clear-api-cache)

;; Default keybindings

(dolist (binding '(("l" . mnemodeck-lookup)
                   ("L" . mnemodeck-lookup-with-provider)
                   ("f" . mnemodeck-define)
                   ("s" . mnemodeck-speak)))
  (keymap-set mnemodeck-review-mode-map (car binding) (cdr binding))
  (keymap-set mnemodeck-edit-mode-map (car binding) (cdr binding)))

(provide 'mnemodeck-dictionary)
;;; mnemodeck-dictionary.el ends here

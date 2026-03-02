;;; decklet-dictionary.el --- Dictionary integration for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Browser lookup, API definition, and pronunciation audio.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'url)

(require 'decklet-core)
(require 'decklet-schedular)
(require 'decklet-deck)
(require 'decklet-edit)
(require 'decklet-review)

(defgroup decklet-dictionary nil
  "Dictionary integration for Decklet."
  :group 'decklet)

(defcustom decklet-dictionary-audio-cache-dir
  (expand-file-name "audio-cache" decklet-directory)
  "Audio cache directory."
  :type 'file
  :group 'decklet-dictionary)

(defcustom decklet-lookup-providers nil
  "Alist of word lookup providers.
Each entry is (NAME . URL), where URL expects a single %s for the word."
  :type '(alist :key-type string :value-type string)
  :group 'decklet-dictionary)

(defcustom decklet-lookup-default-provider nil
  "Default provider name used for word lookups."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'decklet-dictionary)

(defcustom decklet-dictionary-define-function
  #'decklet-dictionary-default-define-function
  "Function to define WORD and return a formatted string.
The function takes a WORD string and returns a propertized string for display.
Caching is handled by `decklet-define'."
  :type 'function
  :group 'decklet-dictionary)

(defcustom decklet-dictionary-audio-function
  #'decklet-dictionary-default-audio-function
  "Function to return a local audio file path for WORD.
The function should take a WORD string and return a local file path or nil.
Caching is handled by `decklet-speak'."
  :type 'function
  :group 'decklet-dictionary)

(defcustom decklet-lookup-hook nil
  "Hook run after browser lookup is opened."
  :type 'hook
  :group 'decklet-dictionary)

(defcustom decklet-define-hook nil
  "Hook run after `decklet-define' prepares definition content."
  :type 'hook
  :group 'decklet-dictionary)

(defface decklet-dictionary-word-face
  '((t :inherit decklet-word-face))
  "Face for displaying the word in dictionary buffer."
  :group 'decklet-dictionary)

(defvar decklet-dictionary-buffer-name "*Decklet Definition*"
  "Name of the buffer used to display dictionary definitions.")

(defvar decklet-dictionary-cache-definition (make-hash-table :test 'equal)
  "Cache for `decklet-dictionary-define-function'.")

(defvar decklet-dictionary-cache-audio (make-hash-table :test 'equal)
  "Cache for `decklet-dictionary-audio-function'.")

;;;###autoload
(defun decklet-lookup (word &optional provider)
  "Lookup WORD in the browser using PROVIDER.
PROVIDER should be a key in `decklet-lookup-providers'.
When PROVIDER is nil, use `decklet-lookup-default-provider'."
  (interactive (list nil nil))
  (if (null decklet-lookup-providers)
      (message "No lookup providers configured. Set `decklet-lookup-providers' first.")
    (let* ((word (decklet--resolve-word word "Lookup word: "))
           (provider (or provider decklet-lookup-default-provider))
           (url-template (and provider
                              (cdr (assoc provider decklet-lookup-providers)))))
      (cond
       ((null provider)
        (message "No default lookup provider set. Configure `decklet-lookup-default-provider' or use `decklet-lookup-with-provider'."))
       ((null url-template)
        (message "Unknown lookup provider `%s'." provider))
       (t
        (browse-url (format url-template (url-hexify-string word)))
        (run-hooks 'decklet-lookup-hook))))))

;;;###autoload
(defun decklet-lookup-with-provider (word &optional provider)
  "Lookup WORD using a selected PROVIDER.
When WORD or PROVIDER is nil, prompt for them."
  (interactive (list nil nil))
  (if (null decklet-lookup-providers)
      (message "No lookup providers configured. Set `decklet-lookup-providers' first.")
    (let ((word (decklet--resolve-word word "Lookup word: "))
          (provider (or provider
                        (completing-read "Lookup provider: "
                                         (mapcar #'car decklet-lookup-providers)
                                         nil t))))
      (decklet-lookup word provider))))

;;;###autoload
(defun decklet-switch-default-provider ()
  "Prompt and set `decklet-lookup-default-provider'."
  (interactive)
  (if (null decklet-lookup-providers)
      (message "No lookup providers configured. Set `decklet-lookup-providers' first.")
    (let ((provider (completing-read "Default lookup provider: "
                                     (mapcar #'car decklet-lookup-providers)
                                     nil t
                                     nil nil
                                     decklet-lookup-default-provider)))
      (setq decklet-lookup-default-provider provider)
      (message "Default lookup provider set to `%s'." provider))))

;; Dictionary API helpers

(define-derived-mode decklet-dictionary-mode special-mode "Decklet-Dictionary"
  "Major mode for Decklet dictionary popups.")

(defun decklet-dictionary--close-buffer ()
  "Close the dictionary buffer and window if present."
  (let ((buffer (get-buffer decklet-dictionary-buffer-name)))
    (when buffer
      (when-let ((window (get-buffer-window buffer)))
        (quit-window t window))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun decklet-dictionary--display (content &optional focus-popup)
  "Display dictionary CONTENT in a dedicated buffer.
When FOCUS-POPUP is non-nil, focus the popup window; otherwise keep focus."
  (let ((buffer (get-buffer-create decklet-dictionary-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert content)
        (goto-char (point-min))
        (decklet-dictionary-mode)))
    (if focus-popup
        (pop-to-buffer buffer '(display-buffer-pop-up-window))
      (save-selected-window
        (display-buffer buffer '(display-buffer-pop-up-window))))
    buffer))

(defun decklet-dictionary--fetch-definition (url &optional method headers body)
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
                 (parsed-data (decklet--json-parse-safe json-string "Error parsing JSON")))
            (kill-buffer buffer)
            parsed-data))))))

(defun decklet-dictionary--format-phonetics (phonetics)
  "Format PHONETICS data into a readable string."
  (when phonetics
    (let ((phonetic-texts (delq nil (mapcar (lambda (p) (alist-get 'text p)) phonetics))))
      (when phonetic-texts
        (format "Pronunciation: %s\n" (string-join phonetic-texts ", "))))))

(defun decklet-dictionary--format-meanings (meanings)
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

(defun decklet-dictionary-default-define-function (word)
  "Return a formatted definition string for WORD using Dictionary API."
  (let* ((url (format "https://api.dictionaryapi.dev/api/v2/entries/en/%s"
                      (url-hexify-string word)))
         (result (decklet-dictionary--fetch-definition url)))
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
                 (propertize word-text 'face 'decklet-dictionary-word-face))
         (or (decklet-dictionary--format-phonetics phonetics) "")
         (decklet-dictionary--format-meanings meanings)))))))

(defun decklet-dictionary-default-audio-function (word)
  "Return a local audio file path for WORD using Dictionary API."
  (when-let* ((url (format "https://api.dictionaryapi.dev/api/v2/entries/en/%s"
                           (url-hexify-string word)))
              (result (decklet-dictionary--fetch-definition url))
              (entry (and (vectorp result) (> (length result) 0) (aref result 0)))
              (phonetics (alist-get 'phonetics entry))
              (audio-url (seq-find (lambda (phonetic)
                                     (let ((audio (alist-get 'audio phonetic)))
                                       (and audio (not (string-empty-p audio)))))
                                   phonetics))
              (audio-url (alist-get 'audio audio-url)))
    (make-directory decklet-dictionary-audio-cache-dir t)
    (let* ((file-extension (or (file-name-extension audio-url) "mp3"))
           (hash (secure-hash 'sha1 audio-url))
           (target (expand-file-name (format "%s.%s" hash file-extension)
                                     decklet-dictionary-audio-cache-dir)))
      (unless (file-exists-p target)
        (condition-case err
            (url-copy-file audio-url target t)
          (error
           (message "Failed to download audio: %s" (error-message-string err))
           (setq target nil))))
      (and (file-exists-p target) target))))

;;;###autoload
(defun decklet-define (word &optional popup focus-popup)
  "Define WORD and return formatted result.
Ignores audio links and focuses on definitions and phonetics.
When POPUP is non-nil, show the definition in a popup buffer.
When FOCUS-POPUP is non-nil, focus the popup window; otherwise keep focus."
  (interactive (list nil nil nil))
  (let* ((word (decklet--resolve-word word "Define word: "))
         (popup (or popup (called-interactively-p 'any)))
         ;; Always focus popup if its called interactively.
         ;; The popup window can be easily closed by pressing "q",
         (focus-popup (or (called-interactively-p 'any)
                          focus-popup))
         (cached (gethash word decklet-dictionary-cache-definition))
         (result (or cached
                     (when (functionp decklet-dictionary-define-function)
                       (funcall decklet-dictionary-define-function word))
                     (format "Dictionary define function is not set for \"%s\"." word))))
    ;; Ensure result is a string
    (unless (stringp result)
      (setq result (format "Dictionary define function returned invalid data for \"%s\"." word)))
    ;; Cache new results
    (unless cached
      (puthash word result decklet-dictionary-cache-definition))
    ;; Run hooks
    (run-hooks 'decklet-define-hook)
    ;; Display in popup if requested
    (when popup
      (decklet-dictionary--display result focus-popup))
    result))

;;;###autoload
(defun decklet-speak (word &optional audio-player)
  "Play pronunciation audio for WORD using `decklet-dictionary-audio-function'.
Downloads and caches audio files locally for better compatibility.
AUDIO-PLAYER specifies the command to play audio (defaults to system default)."
  (interactive (list nil nil))
  (let* ((word (decklet--resolve-word word "Pronounce word: "))
         (cached (gethash word decklet-dictionary-cache-audio))
         (audio-path (if (and (stringp cached) (file-exists-p cached))
                         cached
                       (when (functionp decklet-dictionary-audio-function)
                         (funcall decklet-dictionary-audio-function word))))
         (player (or audio-player
                     (executable-find "afplay")
                     (executable-find "mpv")
                     (if (eq system-type 'windows-nt) "start" "mpv"))))
    (cond
     ((and audio-path (file-exists-p audio-path))
      (puthash word audio-path decklet-dictionary-cache-audio)
      (message "Playing pronunciation of \"%s\"..." word)
      (start-process "decklet-audio" nil player audio-path))
     ((not (functionp decklet-dictionary-audio-function))
      (message "Dictionary audio function is not set for \"%s\"" word))
     (t
      (message "No audio pronunciation available for \"%s\"" word)))))

;;;###autoload
(defun decklet-clear-audio-cache ()
  "Clear the audio cache directory."
  (interactive)
  (when (file-directory-p decklet-dictionary-audio-cache-dir)
    (delete-directory decklet-dictionary-audio-cache-dir t)
    (message "Audio cache cleared"))
  (unless (file-directory-p decklet-dictionary-audio-cache-dir)
    (message "Audio cache was already empty")))

;;;###autoload
(defun decklet-clear-api-cache ()
  "Clear the in-memory dictionary cache.
This is a no-op unless your custom functions use their own caches."
  (interactive)
  (clrhash decklet-dictionary-cache-definition)
  (clrhash decklet-dictionary-cache-audio)
  (when (called-interactively-p 'any)
    (message "Dictionary cache cleared")))

;; Automatically close the dictionary buffer for a better review flow
(add-hook 'decklet-review-quit-hook #'decklet-dictionary--close-buffer)
(add-hook 'decklet-review-next-card-hook #'decklet-dictionary--close-buffer)
(add-hook 'decklet-edit-quit-hook #'decklet-dictionary--close-buffer)
;; Clear API cache but still keep audio cache
(add-hook 'decklet-review-quit-hook #'decklet-clear-api-cache)
(add-hook 'decklet-edit-quit-hook #'decklet-clear-api-cache)

;; Default keybindings

(dolist (binding '(("l" . decklet-lookup)
                   ("L" . decklet-lookup-with-provider)
                   ("f" . decklet-define)
                   ("s" . decklet-speak)))
  (keymap-set decklet-review-mode-map (car binding) (cdr binding))
  (keymap-set decklet-edit-mode-map (car binding) (cdr binding)))

(provide 'decklet-dictionary)
;;; decklet-dictionary.el ends here

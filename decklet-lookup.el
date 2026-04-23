;;; decklet-lookup.el --- Browser lookup for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Browser-based word lookup.  A selected word is substituted into a
;; URL template and opened in the user's browser.  Providers are
;; user-configurable; there is no network, parsing, or popup logic
;; in Decklet itself — extensions can build definition popups or
;; audio playback on top of the public API and hooks documented in
;; the Decklet README.

;;; Code:

(require 'url-util)

(require 'decklet-core)
(require 'decklet-deck)
(require 'decklet-edit)
(require 'decklet-review)

(defgroup decklet-lookup nil
  "Browser lookup for Decklet."
  :group 'decklet)

(defcustom decklet-lookup-providers nil
  "Alist of word lookup providers.
Each entry is (NAME . URL), where URL expects a single %s for the word."
  :type '(alist :key-type string :value-type string)
  :group 'decklet-lookup)

(defcustom decklet-lookup-default-provider nil
  "Default provider name used for word lookups."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'decklet-lookup)

(defcustom decklet-lookup-hook nil
  "Hook run after browser lookup is opened."
  :type 'hook
  :group 'decklet-lookup)

;;;###autoload
(defun decklet-lookup (word &optional provider)
  "Lookup WORD in the browser using PROVIDER.
PROVIDER should be a key in `decklet-lookup-providers'.
When WORD is nil, prompt for it.
When PROVIDER is nil, use `decklet-lookup-default-provider'."
  (interactive (list nil nil))
  (if (null decklet-lookup-providers)
      (message "No lookup providers configured. Set `decklet-lookup-providers' first.")
    (let* ((word (or word (decklet-prompt-word "Lookup word: ")))
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
    (let ((word (or word (decklet-prompt-word "Lookup word: ")))
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

;; Default keybindings

(dolist (binding '(("l" . decklet-lookup)
                   ("L" . decklet-lookup-with-provider)))
  (keymap-set decklet-review-mode-map (car binding) (cdr binding))
  (keymap-set decklet-edit-mode-map (car binding) (cdr binding)))

(provide 'decklet-lookup)
;;; decklet-lookup.el ends here

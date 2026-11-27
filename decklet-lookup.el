;;; decklet-lookup.el --- Browser lookup for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yilin Zhang

;;; Commentary:

;; Browser-based word lookup.  The word is substituted into a
;; provider's URL template and opened in the browser.

;;; Code:

(require 'url-util)

(require 'decklet-core)
(require 'decklet-deck)

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

(defun decklet-lookup--ensure-providers ()
  "Signal a `user-error' when no lookup providers are configured."
  (unless decklet-lookup-providers
    (user-error "No lookup providers configured; set `decklet-lookup-providers'")))

(defun decklet-lookup (word &optional provider)
  "Lookup WORD in the browser using PROVIDER.
PROVIDER should be a key in `decklet-lookup-providers'.
When WORD is nil, prompt for it.
When PROVIDER is nil, use `decklet-lookup-default-provider'."
  (interactive (list nil nil))
  (decklet-lookup--ensure-providers)
  (let* ((provider (or provider decklet-lookup-default-provider))
         (url-template (and provider
                            (not (string-empty-p provider))
                            (cdr (assoc provider decklet-lookup-providers)))))
    (cond
     ((or (null provider) (string-empty-p provider))
      (user-error "No default lookup provider; set `decklet-lookup-default-provider' or use `decklet-lookup-with-provider'"))
     ((null url-template)
      (user-error "Unknown lookup provider `%s'" provider))
     (t
      (let ((word (or word (decklet-prompt-word "Lookup word: "))))
        (browse-url (string-replace "%s" (url-hexify-string word) url-template))
        (run-hooks 'decklet-lookup-hook))))))

(defun decklet-lookup-with-provider (word &optional provider)
  "Lookup WORD using a selected PROVIDER.
When WORD or PROVIDER is nil, prompt for them."
  (interactive (list nil nil))
  (decklet-lookup--ensure-providers)
  (let ((word (or word (decklet-prompt-word "Lookup word: ")))
        (provider (or provider
                      (completing-read "Lookup provider: "
                                       (mapcar #'car decklet-lookup-providers)
                                       nil t))))
    (when (string-empty-p provider)
      (user-error "No lookup provider selected"))
    (decklet-lookup word provider)))

(defun decklet-switch-default-provider ()
  "Prompt and set `decklet-lookup-default-provider'."
  (interactive)
  (decklet-lookup--ensure-providers)
  (let ((provider (completing-read "Default lookup provider: "
                                   (mapcar #'car decklet-lookup-providers)
                                   nil t
                                   nil nil
                                   decklet-lookup-default-provider)))
    (when (string-empty-p provider)
      (user-error "No lookup provider selected"))
    (setq decklet-lookup-default-provider provider)
    (message "Default lookup provider set to `%s'." provider)))

(provide 'decklet-lookup)
;;; decklet-lookup.el ends here

;;; decklite-core.el --- Core shared settings for DeckLite -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Shared root group and directory settings used by all modules.

;;; Code:

(defgroup decklite nil
  "A spaced repetition system using the FSRS algorithm."
  :group 'applications)

(defcustom decklite-directory
  (expand-file-name "decklite/" user-emacs-directory)
  "Base directory for all DeckLite data files."
  :type 'directory
  :group 'decklite)

(provide 'decklite-core)
;;; decklite-core.el ends here

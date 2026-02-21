;;; decklet-core.el --- Core shared settings for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Shared root group and directory settings used by all modules.

;;; Code:

(defgroup decklet nil
  "A spaced repetition system using the FSRS algorithm."
  :group 'applications)

(defcustom decklet-directory
  (expand-file-name "decklet/" user-emacs-directory)
  "Base directory for all Decklet data files."
  :type 'directory
  :group 'decklet)

(provide 'decklet-core)
;;; decklet-core.el ends here

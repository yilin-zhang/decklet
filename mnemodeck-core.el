;;; mnemodeck-core.el --- Core shared settings for MnemoDeck -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Shared root group and directory settings used by all modules.

;;; Code:

(defgroup mnemodeck nil
  "A spaced repetition system using the FSRS algorithm."
  :group 'applications)

(defcustom mnemodeck-directory
  (expand-file-name "mnemodeck/" user-emacs-directory)
  "Base directory for all MnemoDeck data files."
  :type 'directory
  :group 'mnemodeck)

(provide 'mnemodeck-core)
;;; mnemodeck-core.el ends here

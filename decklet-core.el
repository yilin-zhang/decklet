;;; decklet-core.el --- Core shared settings for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Shared root group and directory settings used by all modules.

;;; Code:

(require 'ansi-color)

(defgroup decklet nil
  "A spaced repetition system using the FSRS algorithm."
  :group 'applications)

(defcustom decklet-directory
  (expand-file-name "decklet/" user-emacs-directory)
  "Base directory for all Decklet data files."
  :type 'directory
  :group 'decklet)

;; Shared faces

(defface decklet-word-face
  `((t :foreground ,(face-attribute 'ansi-color-red :foreground)
       :weight bold))
  "Shared face for displaying words."
  :group 'decklet)

(defface decklet-state-new-face
  `((t :foreground ,(face-attribute 'ansi-color-magenta :foreground)
       :weight bold))
  "Shared face for new-card state indicators."
  :group 'decklet)

(defface decklet-state-learning-face
  `((t :foreground ,(face-attribute 'ansi-color-yellow :foreground)
       :weight bold))
  "Shared face for learning-card state indicators."
  :group 'decklet)

(defface decklet-state-review-face
  `((t :foreground ,(face-attribute 'ansi-color-green :foreground)
       :weight bold))
  "Shared face for review-card state indicators."
  :group 'decklet)

(defface decklet-card-back-indicator-face
  `((t :foreground ,(face-attribute 'ansi-color-bright-blue :foreground)
       :weight bold))
  "Face for the card back indicator."
  :group 'decklet)

(provide 'decklet-core)
;;; decklet-core.el ends here

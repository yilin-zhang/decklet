;;; decklet.el --- Spaced repetition system for language learning -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yilin Zhang

;; Author: Yilin Zhang
;; Keywords: tools
;; Version: 0.1.0
;; URL: https://github.com/yilin-zhang/decklet
;; Package-Requires: ((emacs "31.1") (fsrs "6.0"))

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Decklet is a spaced repetition tool for language learners to build
;; vocabulary without much card-construction overhead.  It builds on top of FSRS
;; scheduling, and gives you enough control to shape the workflow inside Emacs.

;;; Code:

(require 'decklet-core)
(require 'decklet-scheduler)
(require 'decklet-db)
(require 'decklet-queue)
(require 'decklet-review-log)
(require 'decklet-backup)
(require 'decklet-deck)
(require 'decklet-batch)
(require 'decklet-card-back)
(require 'decklet-lookup)
(require 'decklet-edit)
(require 'decklet-review)

;; Route all public entry points through `decklet' so `with-eval-after-load'
;; and `(use-package decklet :config ...)' run regardless of which command
;; triggers loading.
;;;###autoload (autoload 'decklet-review "decklet" "Start a review session, restarting if one is already open." t)
;;;###autoload (autoload 'decklet-edit "decklet" "Open the card list for editing, restarting if one is already open." t)
;;;###autoload (autoload 'decklet-add-card "decklet" "Add WORD, then offer hint and tag editing when called interactively." t)
;;;###autoload (autoload 'decklet-add-card-batch "decklet" "Open a buffer for batch word entry." t)
;;;###autoload (autoload 'decklet-lookup "decklet" "Lookup WORD in the browser using PROVIDER." t)
;;;###autoload (autoload 'decklet-lookup-with-provider "decklet" "Lookup WORD using a selected PROVIDER." t)
;;;###autoload (autoload 'decklet-switch-default-provider "decklet" "Prompt and set `decklet-lookup-default-provider'." t)
;;;###autoload (autoload 'decklet-db-backup "decklet" "Create a database backup if the DB has changed since the last backup." t)
;;;###autoload (autoload 'decklet-db-restore "decklet" "Restore the database from a selected backup file." t)
;;;###autoload (autoload 'decklet-disconnect "decklet" "Close the Decklet review and edit buffers, then disconnect the DB." t)
;;;###autoload (autoload 'decklet-open-db-file "decklet" "Open the SQLite database file in `sqlite-mode'." t)

(provide 'decklet)
;;; decklet.el ends here

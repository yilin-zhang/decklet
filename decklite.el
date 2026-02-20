;;; decklite.el --- Spaced repetition system for language learning -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Yilin Zhang
;; Keywords: tools
;; Version: 0.1.0
;; URL: https://github.com/yilin-zhang/decklite
;; Package-Requires: ((emacs "30.1") (fsrs "6.0"))

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

;; DeckLite is a spaced repetition tool for language learners to build
;; vocabulary without much card-construction overhead.  It builds on top of FSRS
;; scheduling, and gives you enough control to shape the workflow inside Emacs.

;;; Code:

(require 'decklite-core)
(require 'decklite-schedular)
(require 'decklite-db)
(require 'decklite-deck)
(require 'decklite-edit)
(require 'decklite-review)
(require 'decklite-dictionary)
(require 'decklite-calendar)
(require 'decklite-import)

(provide 'decklite)
;;; decklite.el ends here

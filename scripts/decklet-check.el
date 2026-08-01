;;; decklet-check.el --- CI checks for Decklet -*- lexical-binding: t; -*-

;;; Commentary:

;; Helpers invoked by the shell scripts in this directory.

;;; Code:

(require 'checkdoc)

(defconst decklet-check--file (or load-file-name buffer-file-name)
  "Absolute path to this checker library.")

(defconst decklet-check--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Absolute path to the Decklet repository root.")

(defun decklet-check--elisp-files ()
  "Return absolute paths of tracked Decklet Elisp files."
  (let* ((default-directory decklet-check--root)
         (files (mapcar (lambda (file)
                          (expand-file-name file decklet-check--root))
                        (process-lines "git" "ls-files" "*.el"))))
    (if (member decklet-check--file files)
        files
      (cons decklet-check--file files))))

(defun decklet-check-parens ()
  "Check balanced parentheses in every tracked Decklet Elisp file."
  (dolist (file (decklet-check--elisp-files))
    (with-temp-buffer
      (insert-file-contents file)
      (check-parens))))

(defun decklet-check-indent ()
  "Check or fix indentation in every tracked Decklet Elisp file.
When DECKLET_FIX_INDENT is set, rewrite files instead of failing."
  (let (bad-files)
    (dolist (file (decklet-check--elisp-files))
      (with-temp-buffer
        (insert-file-contents file)
        (let ((original (buffer-string)))
          (emacs-lisp-mode)
          (indent-region (point-min) (point-max))
          (unless (string-equal original (buffer-string))
            (if (getenv "DECKLET_FIX_INDENT")
                (write-region (point-min) (point-max) file nil 'silent)
              (push file bad-files))))))
    (if bad-files
        (progn
          (princ "Indentation check failed for:\n")
          (dolist (file (nreverse bad-files))
            (princ (format "  %s\n" (file-relative-name file decklet-check--root))))
          (kill-emacs 1))
      (princ "Indentation looks good.\n"))))

(defun decklet-check-checkdoc ()
  "Run Checkdoc against the main Decklet package file."
  (unless (checkdoc-file (expand-file-name "decklet.el" decklet-check--root))
    (princ "Checkdoc failed\n")
    (kill-emacs 1)))

(defun decklet-check-configure-package-lint ()
  "Configure package-lint for Decklet's dependencies and package layout."
  (require 'package)
  (setq package-archives
        '(("gnu" . "https://elpa.gnu.org/packages/")
          ("nongnu" . "https://elpa.nongnu.org/nongnu/")
          ("melpa" . "https://melpa.org/packages/")))
  (package-initialize)
  (unless (assq 'fsrs package-archive-contents)
    (package-refresh-contents))
  (setq package-lint-main-file "decklet.el"))

(provide 'decklet-check)

;;; decklet-check.el ends here

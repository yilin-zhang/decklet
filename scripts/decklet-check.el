;;; decklet-check.el --- CI checks for Decklet -*- lexical-binding: t; -*-

;;; Commentary:

;; Helpers invoked by the shell scripts in this directory.

;;; Code:

(require 'checkdoc)

;; Load the libraries whose macros appear in the sources, so their own
;; `declare' specs are registered.  Without `cl-lib', for instance,
;; `cl-letf' bodies get measured against the fallback rule.
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

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

(defun decklet-check--register-indent-declaration (form)
  "Register the `lisp-indent-function' spec FORM declares, if it declares one."
  (when (and (proper-list-p form)
             (memq (car form) '(defmacro cl-defmacro))
             (symbolp (nth 1 form)))
    (let ((declaration (seq-find (lambda (subform)
                                   (and (consp subform)
                                        (eq (car subform) 'declare)))
                                 (nthcdr 3 form))))
      (when-let* ((spec (assq 'indent (cdr declaration))))
        (put (nth 1 form) 'lisp-indent-function (cadr spec))))))

(defun decklet-check--register-indent-form (form)
  "Register `lisp-indent-function' specs declared anywhere within FORM.
Walks FORM recursively so macros wrapped in conditionals are found too.
The spine is walked iteratively and dotted pairs are tolerated, so
quoted test data cannot abort the scan."
  (when (consp form)
    (decklet-check--register-indent-declaration form)
    (while (consp form)
      (decklet-check--register-indent-form (car form))
      (setq form (cdr form)))))

(defun decklet-check--register-indent-specs (files)
  "Register indentation specs declared by macros defined in FILES.
The indentation check never evaluates the sources, so `declare' forms
inside `defmacro' would otherwise be invisible and macro call sites
would be measured against Emacs' fallback rule instead of the rule the
macro actually declares."
  (dolist (file files)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (condition-case nil
          (while t
            (decklet-check--register-indent-form (read (current-buffer))))
        (end-of-file nil)
        ;; A file we cannot fully read still contributes whatever it
        ;; declared before the unreadable form; the indentation check
        ;; itself will report the real problem.
        (error nil)))))

(defun decklet-check-indent ()
  "Check or fix indentation in every tracked Decklet Elisp file.
When DECKLET_FIX_INDENT is set, rewrite files instead of failing."
  (let ((files (decklet-check--elisp-files))
        bad-files)
    (decklet-check--register-indent-specs files)
    (dolist (file files)
      (with-temp-buffer
        (insert-file-contents file)
        (let ((original (buffer-string)))
          (let ((emacs-lisp-mode-hook nil))
            (emacs-lisp-mode))
          ;; Keep the result independent of host and user defaults.
          (setq-local indent-tabs-mode nil)
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
          (princ "Run ./scripts/check-indent.sh --fix to correct them.\n")
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

;;; decklet-test-helpers.el --- This file provides shared Decklet test infrastructure. -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'decklet)

;; `cl-letf' on C primitives triggers native-compilation of a
;; trampoline on first use, which costs ~500 ms per primitive and
;; dominates the entire test suite wall clock.  Disabling trampolines
;; falls back to a cheap interpreted wrapper; this cuts the suite
;; from ~5.6 s to ~0.65 s with no behavioral change.
(setq native-comp-enable-subr-trampolines nil)

;;; Database fixture

(defmacro decklet-test--with-temp-db (&rest body)
  "Run BODY with an isolated temporary Decklet database.
Binds a fresh SQLite file, a fresh review log file, resets all UI
state variables and id counters, and cleans up the temp directory
on exit.  BODY can refer to `tmp-dir', the temporary directory."
  (declare (indent 0) (debug t))
  `(let* ((tmp-dir (make-temp-file "decklet-test-" t))
          (decklet-directory (file-name-as-directory tmp-dir))
          (decklet-db-file (expand-file-name "decklet.sqlite" tmp-dir))
          (decklet-backup-directory (expand-file-name "backups" tmp-dir))
          (decklet-review-log-file
           (expand-file-name "review-log.jsonl" tmp-dir))
          (decklet-db--conn nil)
          (decklet--fsrs-scheduler nil)
          ;; Shadow tuner-installed weights so scheduler tests can
          ;; toggle the override without leaking the global default.
          (decklet-fsrs-parameters nil)
          ;; Reset id counters so each test mints from a fresh state.
          (decklet-db--last-card-id nil)
          (decklet-review-log--next-record-id nil)
          ;; Use the real production default so config regressions are caught.
          (decklet-review-order (default-value 'decklet-review-order))
          ;; Reset UI state to prevent cross-test pollution.
          (decklet-current-card-id nil)
          (decklet-last-added-word nil)
          (decklet-due-card-ids nil)
          (decklet--counter '(:reviewed 0 :due-review 0 :due-learning 0 :new 0)))
     (unwind-protect
         (progn ,@body)
       (when (and (boundp 'decklet-db--conn) decklet-db--conn)
         (sqlite-close decklet-db--conn)
         (setq decklet-db--conn nil))
       (delete-directory tmp-dir t))))

;;; Card construction

(defun decklet-test--ts (time)
  "Convert TIME to a Decklet timestamp string."
  (decklet--time->fsrs-timestamp time))

(cl-defun decklet-test--make-card-meta (&rest args
                                              &key
                                              (state :review)
                                              (timestamp nil)
                                              &allow-other-keys)
  "Return a `decklet-card-meta' pre-populated with scheduled-card defaults.
STATE defaults to `:review'.  TIMESTAMP, when provided, is used for
`:added-date', `:last-review', and `:due' unless those keys appear
explicitly in ARGS.  When TIMESTAMP is nil, the current time is
used.  Any additional keys in ARGS override the defaults."
  (let* ((ts (or timestamp (decklet-test--ts (current-time))))
	 (defaults (list :added-date ts :last-review ts :due ts :state state))
	 (merged (copy-sequence defaults)))
    ;; Strip our own keyword args so we don't forward :timestamp to
    ;; `make-decklet-card-meta' (which would signal).
    (let ((clean args))
      (while clean
	(unless (eq (car clean) :timestamp)
	  (setq merged (plist-put merged (car clean) (cadr clean))))
	(setq clean (cddr clean))))
    (apply #'make-decklet-card-meta merged)))

(defun decklet-test--card-id (word)
  "Return the card id stored for WORD, or nil when absent."
  (plist-get (decklet-db--select-card-row-by-word word) :card-id))

(defun decklet-test--add-card-meta (word &rest keys)
  "Upsert WORD with a scheduled card-meta built from KEYS, return its card id.
KEYS are forwarded to `decklet-test--make-card-meta'."
  (decklet-db--upsert-card word (apply #'decklet-test--make-card-meta keys))
  (decklet-test--card-id word))

(cl-defun decklet-test--trail-entry (card-id &key (grade 3) pre-meta)
  "Return a trail entry plist for CARD-ID.
GRADE defaults to 3; pass `:grade nil' for a skip entry.  PRE-META
defaults to a fresh `decklet-card-meta'."
  (list :card-id card-id
	:grade grade
	:pre-meta (or pre-meta (make-decklet-card-meta))))

;;; JSON import / review-log readback

(defun decklet-test--import (rows)
  "Write ROWS to a temp JSON file in the test directory and import it.
Return the import stats plist from `decklet-db-import-json'."
  (let ((file (expand-file-name "import.json" decklet-directory))
        (json-encoding-pretty-print t))
    (with-temp-file file (insert (json-encode rows)))
    (decklet-db-import-json file)))

(defun decklet-test--read-log ()
  "Return the review-log records as plists, or nil when the file is empty.
Reads `decklet-review-log-file', one JSON object per line."
  (when (file-exists-p decklet-review-log-file)
    (with-temp-buffer
      (insert-file-contents decklet-review-log-file)
      (let (records)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (unless (string-empty-p line)
              (push (json-parse-string line :object-type 'plist
                                       :null-object nil :false-object nil)
                    records)))
          (forward-line 1))
        (nreverse records)))))

;;; Buffers, faces, backups

(defmacro decklet-test--with-temp-buffers (names &rest body)
  "Bind each symbol in NAMES to a fresh buffer, run BODY, kill them on exit.
Teardown clears `kill-buffer-query-functions' in each buffer first, so a
buffer that installed a blocking query (e.g. a dirty card back) still dies."
  (declare (indent 1) (debug t))
  `(let ,(mapcar (lambda (n) `(,n (generate-new-buffer ,(format " *%s*" n)))) names)
     (unwind-protect
         (progn ,@body)
       ,@(mapcar (lambda (n)
                   `(when (buffer-live-p ,n)
                      (with-current-buffer ,n
                        (setq kill-buffer-query-functions nil))
                      (kill-buffer ,n)))
                 names))))

(defun decklet-test--string-has-face-p (string face)
  "Return non-nil when FACE is the `face' text property anywhere in STRING."
  (cl-loop for i below (length string)
           thereis (eq (get-text-property i 'face string) face)))

(defmacro decklet-test--with-backup-dir (&rest body)
  "Run BODY with the backup directory created and bound.
Binds `backup-dir' (a directory name) and `base' (the DB file base name)."
  (declare (indent 0) (debug t))
  `(let* ((backup-dir (file-name-as-directory decklet-backup-directory))
          (base (file-name-base decklet-db-file)))
     (make-directory backup-dir t)
     ,@body))

(defun decklet-test--touch (file &optional content)
  "Create FILE with CONTENT (default \"dummy\")."
  (with-temp-file file (insert (or content "dummy"))))

(defun decklet-test--file-string (file)
  "Return the contents of FILE as a string."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

;;; Review UI stubs

(defmacro decklet-test--with-silent-review-ui (&rest body)
  "Run BODY with review-mode UI side effects stubbed to no-ops.
Stubs `decklet-review--reset-ui-state', `decklet-review--render-buffer',
and `run-hooks' so unit tests can exercise review logic without
touching a real buffer or firing user hooks."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'decklet-review--reset-ui-state) #'ignore)
             ((symbol-function 'decklet-review--render-buffer) #'ignore)
             ((symbol-function 'run-hooks) #'ignore))
     ,@body))

(provide 'decklet-test-helpers)
;;; decklet-test-helpers.el ends here

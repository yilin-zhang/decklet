;;; decklet-test-helpers.el --- This file provides shared Decklet test infrastructure. -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decklet)

;; `cl-letf' on a C primitive compiles a trampoline on first use, about
;; 500 ms each, which took the suite from 0.65 s to 5.6 s.
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
          ;; Drop the cached log scan so daily-limit accounting starts
          ;; from an empty log in every test.
          (decklet-review-log--scan-cache nil)
          ;; Use the real production default so config regressions are caught.
          (decklet-review-order (default-value 'decklet-review-order))
          ;; Reset UI state to prevent cross-test pollution.
          (decklet-current-card-id nil)
          (decklet-due-card-ids nil)
          (decklet-queue--cache nil)
          (decklet-review--queue-context nil)
          (decklet-edit--tag-filter nil)
          (decklet--counter (copy-sequence (default-value 'decklet--counter))))
     (unwind-protect
         (progn ,@body)
       (when (and (boundp 'decklet-db--conn) decklet-db--conn)
         (sqlite-close decklet-db--conn)
         (setq decklet-db--conn nil))
       (delete-directory tmp-dir t))))

;;; Card construction

(defun decklet-test--ts (time)
  "Convert TIME to a Decklet timestamp string."
  (decklet--now time))

(cl-defun decklet-test--make-card-meta (&rest args
                                              &key timestamp
                                              (last-review nil last-review-p)
                                              &allow-other-keys)
  "Return a `decklet-card-meta' in a state the real code can produce.
By default the card has been reviewed, so it is in state `:review'
with stability and difficulty.  Passing `:last-review nil' makes it a new card in the
learning state with no memory data.  TIMESTAMP, when given, replaces
the current time for the added, last-review and due dates.  Any other
keys in ARGS override these defaults."
  (let* ((ts (or timestamp (decklet-test--ts (current-time))))
         (meta (if (and last-review-p (null last-review))
                   (list :added-date ts :due ts :state :learning :step 0)
                 (list :added-date ts :last-review ts :due ts :state :review
                       :stability 1.0 :difficulty 5.0))))
    (cl-loop for (key value) on args by #'cddr
             unless (eq key :timestamp)
             do (setq meta (plist-put meta key value)))
    (apply #'make-decklet-card-meta meta)))

(defun decklet-test--card-id (word)
  "Return the card id stored for WORD, or nil when absent."
  (plist-get (decklet-db--select-card-row-by-word word) :card-id))

(defun decklet-test--add-card-meta (word &rest keys)
  "Upsert WORD with a scheduled card-meta built from KEYS, return its card id.
KEYS are forwarded to `decklet-test--make-card-meta'."
  (decklet-db--upsert-card word (apply #'decklet-test--make-card-meta keys))
  (decklet-test--card-id word))

;;; Review-log readback

(defun decklet-test--log-rated (state &optional stamp)
  "Append a rated log record whose effective pre-state is STATE.
STAMP defaults to now.  Returns the record id."
  (let ((id (decklet--mint-monotonic-id 'decklet-review-log--next-record-id)))
    (decklet-review-log--append-line
     (list :kind "rated"
           :id id
           :card_id id
           :t (or stamp (decklet--now))
           :word (format "logged-%s" id)
           :grade 3
           :pre_state state
           :pre_effective_state state
           :pre_stability nil
           :elapsed_days 0.0))
    id))

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

;;; Buffers and files

(defmacro decklet-test--with-temp-buffers (names &rest body)
  "Bind each symbol in NAMES to a fresh buffer, run BODY, kill them on exit.
Teardown clears `kill-buffer-query-functions' in each buffer first, so a
buffer that installed a blocking query, such as a dirty card back, still
dies."
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

(defun decklet-test--touch (file &optional content)
  "Create FILE with CONTENT (default \"dummy\")."
  (with-temp-file file (insert (or content "dummy"))))

(defun decklet-test--file-string (file)
  "Return the contents of FILE as a string."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(provide 'decklet-test-helpers)
;;; decklet-test-helpers.el ends here

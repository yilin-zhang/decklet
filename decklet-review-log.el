;;; decklet-review-log.el --- Persistent review history log for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yilin Zhang

;;; Commentary:

;; Append-only JSONL log of review events at `decklet-review-log-file'.
;; A rating appends a "rated" record, re-rating after an undo appends a
;; "void" record for the replaced rating, and renaming a card appends a
;; "rename" record.  Deletes are not logged.  docs/extensions.md
;; describes the record format.
;;
;; Core reads back today's ratings for the daily limits of
;; `decklet-review-order'.

;;; Code:

(require 'seq)

(require 'decklet-core)
(require 'decklet-db)
(require 'decklet-scheduler)

(defgroup decklet-review-log nil
  "Persistent review history log for Decklet."
  :group 'decklet)

(defun decklet-review-log-file ()
  "Return the path to the Decklet review log JSONL file.
Every completed rating is appended to this file.  Consumers should
treat the file as append-only and parse it one JSON object per line."
  (expand-file-name "review-log.jsonl" decklet-directory))

(defvar decklet-review-log--next-record-id nil
  "Last minted review log record id, or nil before the first mint.")

;; Low-level writer

(defun decklet-review-log--append-line (record)
  "Append RECORD plist as one JSONL line to `decklet-review-log-file'.
Return non-nil on success.  A failed write is reported with `message'
and returns nil."
  (condition-case err
      (let ((log-file (decklet-review-log-file)))
        (when-let* ((dir (file-name-directory log-file)))
          (make-directory dir t))
        (let* ((file (file-truename log-file))
               (size (file-attribute-size (file-attributes file)))
               ;; Guard against a prior truncated line swallowing the next record.
               (needs-newline
                (and size (> size 0)
                     (with-temp-buffer
                       (set-buffer-multibyte nil)
                       (insert-file-contents-literally file nil (1- size) size)
                       (/= (char-after (point-min)) ?\n))))
               (json (json-serialize record :null-object nil)))
          (with-temp-buffer
            (when needs-newline (insert "\n"))
            (insert json "\n")
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region (point-min) (point-max)
                            log-file t 'no-message))))
        t)
    (error
     (message "Decklet: failed to write review log: %s"
              (error-message-string err))
     nil)))

;; Public append API

(defun decklet-review-log-append-rated (word card-id grade old-meta new-meta)
  "Append a rated event to the review log and return its record id.
WORD and CARD-ID identify the card, GRADE is 1-4, and OLD-META and
NEW-META are the card meta before and after the rating.  Return nil
if the write fails."
  (let* ((now-str (or (decklet-card-meta-last-review new-meta) (decklet--now)))
         (record-id (decklet--mint-monotonic-id
                     'decklet-review-log--next-record-id))
         (last-review (decklet-card-meta-last-review old-meta))
         (record (list :kind "rated"
                       :id record-id
                       :card_id card-id
                       :t now-str
                       :word word
                       :grade grade
                       :pre_state (decklet-fsrs-state-string
                                   (decklet-card-meta-state old-meta))
                       :pre_effective_state
                       (decklet-fsrs-state-string
                        (decklet-card-meta-effective-state old-meta))
                       :pre_stability (decklet-card-meta-stability old-meta)
                       :pre_difficulty (decklet-card-meta-difficulty old-meta)
                       :post_state (decklet-fsrs-state-string
                                    (decklet-card-meta-state new-meta))
                       :post_stability (decklet-card-meta-stability new-meta)
                       :post_difficulty (decklet-card-meta-difficulty new-meta)
                       :elapsed_days
                       (if last-review
                           (/ (decklet--timestamp-difference now-str last-review)
                              86400.0)
                         0.0))))
    (and (decklet-review-log--append-line record)
         record-id)))

(defun decklet-review-log-append-void (voided-record-id)
  "Append a void event that nullifies VOIDED-RECORD-ID.
Consumers skip any rated record whose `id' appears as a void's
`voids' field."
  (decklet-review-log--append-line
   (list :kind "void"
         :voids voided-record-id
         :t (decklet--now))))

(defun decklet-review-log-append-rename (card-id old-word new-word)
  "Append a rename event for CARD-ID from OLD-WORD to NEW-WORD."
  (decklet-review-log--append-line
   (list :kind "rename"
         :card_id card-id
         :old old-word
         :new new-word
         :t (decklet--now))))

;; Reading recent ratings back.  Only the tail after the cutoff is
;; parsed, and the result is cached by file size.  A missing or
;; unreadable log counts as no ratings.

(defconst decklet-review-log--scan-chunk 65536
  "Byte size of each backward read when locating the records after a cutoff.")

(defvar decklet-review-log--scan-cache nil
  "Cached scan of the review log tail after a cutoff.
A plist with keys `:file', `:since', `:size' and `:records'.
`:records' holds the rated records that no void event retired,
newest first.")

(defun decklet-review-log--clear-scan-cache ()
  "Drop the scan cache.
Runs when the DB disconnects, and after anything rewrites the log."
  (setq decklet-review-log--scan-cache nil))

(add-hook 'decklet-db-pre-disconnect-hook #'decklet-review-log--clear-scan-cache)

(defun decklet-review-log--parse-line (line)
  "Return LINE parsed as a plist, or nil when it is not valid JSON."
  (condition-case nil
      (let ((record (json-parse-string line :object-type 'plist :null-object nil
                                       :array-type 'list)))
        (when (and (listp record) (stringp (plist-get record :t)))
          record))
    (error nil)))

(defun decklet-review-log--read-lines (start end drop-first)
  "Return complete log lines in the byte range START to END.
DROP-FIRST discards the leading line, which is truncated whenever
START is not a line boundary."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents (decklet-review-log-file) nil start end))
    (let ((lines (split-string (buffer-string) "\n" t)))
      (if drop-first (cdr lines) lines))))

(defun decklet-review-log--read-lines-since (since size)
  "Return log lines covering SINCE onwards within the first SIZE bytes.
Reads backward in `decklet-review-log--scan-chunk' steps until a
record older than SINCE is in view, so the returned list is a
superset of the lines after SINCE."
  (let ((start size)
        (lines nil)
        (done nil))
    (while (not done)
      (setq start (max 0 (- start decklet-review-log--scan-chunk)))
      (setq lines (decklet-review-log--read-lines start size (> start 0)))
      (setq done
            (or (zerop start)
                (when-let* ((first (car lines))
                            (record (decklet-review-log--parse-line first))
                            (stamp (plist-get record :t)))
                  (string< stamp since)))))
    lines))

(defun decklet-review-log--collect (lines since records)
  "Fold the rated LINES at or after SINCE into RECORDS and return them.
A void line drops the record it retires.  The log is append-only, so
that record is already in RECORDS, or older than SINCE."
  (dolist (line lines)
    (when-let* ((record (decklet-review-log--parse-line line))
                (stamp (plist-get record :t))
                ((not (string< stamp since))))
      (let ((kind (plist-get record :kind)))
        (cond
         ((equal kind "rated")
          (push record records))
         ((equal kind "void")
          (let ((id (plist-get record :voids)))
            (setq records (seq-remove (lambda (rated)
                                        (eql (plist-get rated :id) id))
                                      records))))))))
  records)

(defun decklet-review-log--refresh-scan (since)
  "Return the scan cache for SINCE, refreshing it when stale.
Reuses the cached scan and parses only appended bytes when the log
has merely grown; rescans the day from scratch otherwise.  Returns
nil when the log file cannot be read."
  (let* ((file (file-truename (decklet-review-log-file)))
         (size (file-attribute-size (file-attributes file))))
    (when size
      (let* ((cache decklet-review-log--scan-cache)
             (reusable (and cache
                            (equal (plist-get cache :file) file)
                            (equal (plist-get cache :since) since)
                            (<= (plist-get cache :size) size)))
             (from (if reusable (plist-get cache :size) nil))
             (lines (condition-case nil
                        (if reusable
                            (if (= from size)
                                nil
                              (decklet-review-log--read-lines from size nil))
                          (decklet-review-log--read-lines-since since size))
                      (error 'unreadable))))
        (unless (eq lines 'unreadable)
          (setq decklet-review-log--scan-cache
                (list :file file
                      :since since
                      :size size
                      :records (decklet-review-log--collect
                                lines since
                                (and reusable (plist-get cache :records))))))))))

(defun decklet-review-log-ratings-since (cutoff)
  "Return the rated records logged at or after the time CUTOFF.
Each record is a plist with the keys of a `rated' log line, such as
`:card_id' and `:pre_effective_state'.  Voided ratings are left out.
The newest record comes first."
  (plist-get (decklet-review-log--refresh-scan (decklet--now cutoff))
             :records))

(provide 'decklet-review-log)

;;; decklet-review-log.el ends here

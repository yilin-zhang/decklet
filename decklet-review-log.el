;;; decklet-review-log.el --- Persistent review history log for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Persistent per-review event log for Decklet, stored as JSONL at
;; `decklet-review-log-file'.  Used by external tools to fine-tune FSRS
;; parameters from the user's actual memory behaviour.
;;
;; The log is append-only.  Three event kinds are written:
;;
;;   "rated"
;;     A card was graded by the user.  Records the card's identity,
;;     grade, pre- and post-scheduling state, and elapsed days since
;;     the previous review.  "pre_state" is the card's stored FSRS
;;     state, which cannot distinguish a brand-new card from one
;;     already in learning; "pre_effective_state" resolves that and
;;     is the field consumers should prefer.
;;
;;   "void"
;;     Nullifies a previously-written rated record by its id.  Used
;;     when the user undoes and re-rates within a single review
;;     session.  Consumers should skip any rated record whose id
;;     appears as the target of a void event.
;;
;;   "rename"
;;     Records that a card's word changed.  Consumers can use this to
;;     reconstruct the "word at the time of rating" history for a
;;     card that has been renamed.  Identity across renames is
;;     preserved by card_id, so consumers grouping by card_id (e.g.
;;     FSRS optimizers) can safely ignore rename events.
;;
;; Delete is silent to the log — historical ratings for deleted
;; cards remain for FSRS tuning.
;;
;; The log writer is owned by Decklet core so every rating is
;; captured transactionally with the card update.  External
;; consumers (dashboards, optimizers, analytics) should read the
;; file directly; the only reader in core is
;; `decklet-review-log-daily-state-counts', which serves the daily
;; limits in `decklet-review-order' and is documented in the "Daily
;; consumption accounting" section below.

;;; Code:

(require 'json)

(require 'decklet-core)
(require 'decklet-scheduler)

(defgroup decklet-review-log nil
  "Persistent review history log for Decklet."
  :group 'decklet)

(defcustom decklet-review-log-file
  (expand-file-name "review-log.jsonl" decklet-directory)
  "Path to the Decklet review log JSONL file.
Every completed rating is appended to this file.  Consumers should
treat the file as append-only and parse it one JSON object per line."
  :type 'file
  :group 'decklet-review-log)

(defvar decklet-review-log--next-record-id nil
  "In-memory monotonic counter for review log record ids.
Seeded lazily on the first mint; cross-session monotonicity holds
as long as the system clock advances.")

(defconst decklet-review-log-kind-rated "rated"
  "Serialized kind for rating records.")
(defconst decklet-review-log-kind-void "void"
  "Serialized kind for records that retire an earlier rating.")
(defconst decklet-review-log-kind-rename "rename"
  "Serialized kind for card rename records.")

(defun decklet-review-log--mint-record-id ()
  "Return a fresh monotonic microsecond record id."
  (decklet--mint-monotonic-id 'decklet-review-log--next-record-id))

;; Low-level writer

(defun decklet-review-log--ensure-directory ()
  "Ensure the directory for `decklet-review-log-file' exists."
  (when-let* ((dir (file-name-directory decklet-review-log-file)))
    (make-directory dir t)))

(defun decklet-review-log--append-line (record)
  "Append RECORD plist as one JSONL line to `decklet-review-log-file'.
RECORD nil values are serialised as JSON null.  Errors are caught
and reported via `message'; the function returns non-nil on a
successful write, nil on failure."
  (condition-case err
      (progn
        (decklet-review-log--ensure-directory)
        (let ((json (json-serialize record :null-object nil)))
          (with-temp-buffer
            (insert json "\n")
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region (point-min) (point-max)
                            decklet-review-log-file t 'no-message))))
        t)
    (error
     (message "Decklet: failed to write review log: %s"
              (error-message-string err))
     nil)))

;; Public append API

(defun decklet-review-log-append-rated (word card-id grade old-meta new-meta)
  "Append a rated event to the review log.
WORD is the card's word at the time of rating.  CARD-ID is its
stable card id (`decklet-card-meta-card-id').  GRADE is the rating,
1-4.  OLD-META is the card meta before this rating; NEW-META is the
meta after FSRS scheduled the rating.  Returns the new record id on
success, nil on write failure."
  (let* ((now-str (decklet--now))
         (record-id (decklet-review-log--mint-record-id))
         (elapsed-days (decklet--elapsed-days-since
                        (decklet-card-meta-last-review old-meta)
                        now-str))
         (record (list :kind decklet-review-log-kind-rated
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
                       :elapsed_days elapsed-days)))
    (and (decklet-review-log--append-line record)
         record-id)))

(defun decklet-review-log-append-void (voided-record-id)
  "Append a void event that nullifies VOIDED-RECORD-ID.
Consumers skip any rated record whose `id' appears as a void's
`voids' field."
  (decklet-review-log--append-line
   (list :kind decklet-review-log-kind-void
         :voids voided-record-id
         :t (decklet--now))))

(defun decklet-review-log-append-rename (card-id old-word new-word)
  "Append a rename event for CARD-ID from OLD-WORD to NEW-WORD."
  (decklet-review-log--append-line
   (list :kind decklet-review-log-kind-rename
         :card_id card-id
         :old old-word
         :new new-word
         :t (decklet--now))))

;; Daily consumption accounting
;;
;; Decklet core reads its own log back to answer one question: how many
;; cards has each `decklet-review-order' step already handed out during
;; the current review day?  That fact is history, not card state, so it
;; lives here rather than in the `cards' table.  Only the tail covering
;; today is parsed, and the result is cached against the file size so
;; repeated queue rebuilds within a session stay cheap.
;;
;; The log is advisory for this purpose: when it is missing or
;; unreadable the accounting reports nothing consumed, which lets
;; reviewing continue with full daily allowances rather than blocking.

(defconst decklet-review-log--scan-chunk 65536
  "Byte size of each backward read when locating today's records.")

(defvar decklet-review-log--scan-cache nil
  "Cached scan of the current review day's tail of the review log.
A plist with keys `:file', `:day-start', `:size', `:records' and
`:voided'.  `:records' holds (ID CARD-ID STATE) triples for rated
events, in no particular order; `:voided' holds the ids retired by
void events.")

(defun decklet-review-log--parse-line (line)
  "Return LINE parsed as a plist, or nil when it is not valid JSON."
  (condition-case nil
      (json-parse-string line :object-type 'plist :null-object nil
                         :array-type 'list)
    (error nil)))

(defun decklet-review-log--record-effective-state (record)
  "Return the effective state string a card had when RECORD was written."
  (or (plist-get record :pre_effective_state)
      ;; Compatibility path for records written before
      ;; `pre_effective_state' existed.  FSRS assigns stability on a
      ;; card's very first review, so a null `pre_stability' identifies
      ;; that first review -- i.e. the card was new -- while any other
      ;; record's stored `pre_state' is already the effective one.
      ;; Deprecated: drop this branch once such records no longer
      ;; matter for daily accounting.
      (if (plist-get record :pre_stability)
          (plist-get record :pre_state)
        "new")))

(defun decklet-review-log--read-lines (start end drop-first)
  "Return complete log lines in the byte range START to END.
DROP-FIRST discards the leading line, which is truncated whenever
START is not a line boundary."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents decklet-review-log-file nil start end))
    (let ((lines (split-string (buffer-string) "\n" t)))
      (if drop-first (cdr lines) lines))))

(defun decklet-review-log--read-day-lines (day-start size)
  "Return log lines covering DAY-START onwards within the first SIZE bytes.
Reads backward in `decklet-review-log--scan-chunk' steps until a
record older than DAY-START is in view, so the returned list is a
superset of the day's lines."
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
                  (string< stamp day-start)))))
    lines))

(defun decklet-review-log--collect (lines day-start records voided)
  "Fold LINES at or after DAY-START into RECORDS and VOIDED.
Return the cons of the extended (RECORDS . VOIDED) lists."
  (dolist (line lines)
    (when-let* ((record (decklet-review-log--parse-line line))
                (stamp (plist-get record :t))
                (_ (not (string< stamp day-start))))
      (let ((kind (plist-get record :kind)))
        (cond
         ((equal kind decklet-review-log-kind-rated)
          (push (list (plist-get record :id)
                      (plist-get record :card_id)
                      (decklet-review-log--record-effective-state record))
                records))
         ((equal kind decklet-review-log-kind-void)
          (push (plist-get record :voids) voided))))))
  (cons records voided))

(defun decklet-review-log--refresh-scan (day-start)
  "Return the scan cache for DAY-START, refreshing it when stale.
Reuses the cached scan and parses only appended bytes when the log
has merely grown; rescans the day from scratch otherwise.  Returns
nil when the log file cannot be read."
  (let ((size (file-attribute-size
               (file-attributes decklet-review-log-file))))
    (when size
      (let* ((cache decklet-review-log--scan-cache)
             (reusable (and cache
                            (equal (plist-get cache :file)
                                   decklet-review-log-file)
                            (equal (plist-get cache :day-start) day-start)
                            (<= (plist-get cache :size) size)))
             (from (if reusable (plist-get cache :size) nil))
             (lines (condition-case nil
                        (if reusable
                            (if (= from size)
                                nil
                              (decklet-review-log--read-lines from size nil))
                          (decklet-review-log--read-day-lines day-start size))
                      (error 'unreadable))))
        (unless (eq lines 'unreadable)
          (let ((folded (decklet-review-log--collect
                         lines day-start
                         (and reusable (plist-get cache :records))
                         (and reusable (plist-get cache :voided)))))
            (setq decklet-review-log--scan-cache
                  (list :file decklet-review-log-file
                        :day-start day-start
                        :size size
                        :records (car folded)
                        :voided (cdr folded)))))))))

(defun decklet-review-log-daily-state-counts (&optional time)
  "Return an alist of (STATE . COUNT) for the review day containing TIME.
STATE is one of the keywords `:new', `:learning', `:relearning' or
`:review', naming the effective state a card was in when it was
graded -- that is, the `decklet-review-order' target that handed it
out.  A card is counted once per state no matter how many times it
was graded from that state.  Ratings retired by a void event are
ignored.  An unreadable or absent log yields nil, so callers treat
the day as having consumed nothing."
  (let* ((day-start (decklet--time->fsrs-timestamp
                     (decklet-day-start-time time)))
         (cache (decklet-review-log--refresh-scan day-start)))
    (when cache
      (let ((voided (plist-get cache :voided))
            (seen (make-hash-table :test 'equal))
            (counts nil))
        (dolist (record (plist-get cache :records))
          (pcase-let ((`(,id ,card-id ,state) record))
            (unless (or (member id voided)
                        (null state)
                        (gethash (cons state card-id) seen))
              (puthash (cons state card-id) t seen)
              (let* ((key (decklet--normalize-fsrs-state state))
                     (cell (assq key counts)))
                (if cell
                    (setcdr cell (1+ (cdr cell)))
                  (push (cons key 1) counts))))))
        counts))))

(provide 'decklet-review-log)

;;; decklet-review-log.el ends here

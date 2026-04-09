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
;;     the previous review.
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
;; captured transactionally with the card update.  Consumers
;; (dashboards, optimizers, analytics) should read the file directly;
;; no reader API is provided in core.

;;; Code:

(require 'json)

(require 'decklet-core)
(require 'decklet-scheduler)
(require 'decklet-db)

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
Seeded lazily on the first call to `decklet-review-log--mint-record-id'
from the current microsecond timestamp; cross-session monotonicity
holds as long as the system clock advances.")

(defun decklet-review-log--mint-record-id ()
  "Return a fresh monotonic microsecond record id."
  (let ((now (truncate (* (float-time) 1e6))))
    (setq decklet-review-log--next-record-id
          (if decklet-review-log--next-record-id
              (max (1+ decklet-review-log--next-record-id) now)
            now)))
  decklet-review-log--next-record-id)

;; Low-level writer

(defun decklet-review-log--ensure-directory ()
  "Ensure the directory for `decklet-review-log-file' exists."
  (let ((dir (file-name-directory decklet-review-log-file)))
    (when dir
      (make-directory dir t))))

(defun decklet-review-log--append-line (record)
  "Append RECORD plist as one JSONL line to `decklet-review-log-file'.
RECORD nil values are serialised as JSON null."
  (decklet-review-log--ensure-directory)
  (let ((json (json-serialize record :null-object nil)))
    (with-temp-buffer
      (insert json "\n")
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region (point-min) (point-max)
                      decklet-review-log-file t 'no-message)))))

;; Public append API

(defun decklet-review-log-append-rated (word card-id grade old-meta new-meta)
  "Append a rated event to the review log and return the new record id.
WORD is the card's word at the time of rating.  CARD-ID is its
stable instance id (`decklet-card-meta-instance-id').  GRADE is the
rating, 1-4.  OLD-META is the card meta before this rating; NEW-META
is the meta after FSRS scheduled the rating."
  (let* ((now-str (decklet--now))
         (record-id (decklet-review-log--mint-record-id))
         (elapsed-days (decklet--elapsed-days-since
                        (decklet-card-meta-last-review old-meta)
                        now-str))
         (record (list :kind "rated"
                       :id record-id
                       :card_id card-id
                       :t now-str
                       :word word
                       :grade grade
                       :pre_state (decklet--fsrs-state-string
                                   (decklet-card-meta-state old-meta))
                       :pre_stability (decklet-card-meta-stability old-meta)
                       :pre_difficulty (decklet-card-meta-difficulty old-meta)
                       :post_state (decklet--fsrs-state-string
                                    (decklet-card-meta-state new-meta))
                       :post_stability (decklet-card-meta-stability new-meta)
                       :post_difficulty (decklet-card-meta-difficulty new-meta)
                       :elapsed_days elapsed-days)))
    (decklet-review-log--append-line record)
    record-id))

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

;; Backup integration

(defun decklet-review-log--on-db-backup (backup-dir timestamp)
  "Back up the review log alongside the DB via `decklet-db-post-backup-functions'."
  (decklet-db-backup-auxiliary-file decklet-review-log-file backup-dir timestamp))

(add-hook 'decklet-db-post-backup-functions #'decklet-review-log--on-db-backup)

(provide 'decklet-review-log)

;;; decklet-review-log.el ends here

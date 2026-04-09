;;; decklet-review-log-test.el --- Tests for decklet-review-log -*- lexical-binding: t; -*-

(require 'decklet-test-helpers)
(require 'json)

;; ---------------------------------------------------------------------------
;; Helpers for reading back the JSONL file
;; ---------------------------------------------------------------------------

(defun decklet-test--read-log ()
  "Return the list of plist records from `decklet-review-log-file'.
Returns nil when the file does not exist or is empty."
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
                                       :null-object nil
                                       :false-object nil)
                    records)))
          (forward-line 1))
        (nreverse records)))))

;; ---------------------------------------------------------------------------
;; decklet-db--mint-instance-id
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-mint-instance-id-seeds-from-empty-db ()
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (let ((id (decklet-db--mint-instance-id)))
      (should (integerp id))
      (should (> id 0)))))

(ert-deftest decklet-test-mint-instance-id-is-strictly-monotonic ()
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (let ((ids (cl-loop repeat 20 collect (decklet-db--mint-instance-id))))
      (should (equal ids (sort (copy-sequence ids) #'<)))
      (should (= (length ids) (length (delete-dups (copy-sequence ids))))))))

(ert-deftest decklet-test-mint-instance-id-seeds-above-existing-max ()
  (decklet-test--with-temp-db
    (let ((conn (decklet-db--ensure)))
      ;; Insert two rows with known large instance_id values, then
      ;; reset the counter and mint.  The next mint must be greater
      ;; than the highest existing id.
      (sqlite-execute
       conn
       "INSERT INTO cards (word, added_date, due, state, instance_id)
        VALUES ('one', ?, ?, 'review', 9999999999),
               ('two', ?, ?, 'review', 8888888888);"
       (let ((now (decklet--now)))
         (list now now now now)))
      (setq decklet-db--last-instance-id nil)
      (let ((id (decklet-db--mint-instance-id)))
        (should (> id 9999999999))))))

;; ---------------------------------------------------------------------------
;; decklet-review-log-append-rated
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-log-append-rated-writes-one-line ()
  (decklet-test--with-temp-db
    (let* ((old (make-decklet-card-meta
                 :instance-id 42
                 :state :review
                 :stability 4.5
                 :difficulty 5.1
                 :last-review "2026-04-01T00:00:00Z"))
           (new (make-decklet-card-meta
                 :instance-id 42
                 :state :review
                 :stability 5.2
                 :difficulty 5.3
                 :last-review (decklet--now))))
      (decklet-review-log-append-rated "ephemeral" 42 3 old new)
      (let ((records (decklet-test--read-log)))
        (should (= 1 (length records)))
        (let ((rec (car records)))
          (should (equal "rated" (plist-get rec :kind)))
          (should (equal "ephemeral" (plist-get rec :word)))
          (should (= 42 (plist-get rec :card_id)))
          (should (= 3 (plist-get rec :grade)))
          (should (equal "review" (plist-get rec :pre_state)))
          (should (equal "review" (plist-get rec :post_state)))
          (should (numberp (plist-get rec :pre_stability)))
          (should (numberp (plist-get rec :post_stability)))
          (should (numberp (plist-get rec :elapsed_days)))
          (should (integerp (plist-get rec :id))))))))

(ert-deftest decklet-test-review-log-append-rated-returns-monotonic-ids ()
  (decklet-test--with-temp-db
    (let* ((old (make-decklet-card-meta
                 :instance-id 1
                 :state :review
                 :stability 3.0
                 :difficulty 5.0))
           (new (copy-decklet-card-meta old))
           (id1 (decklet-review-log-append-rated "a" 1 3 old new))
           (id2 (decklet-review-log-append-rated "a" 1 3 old new))
           (id3 (decklet-review-log-append-rated "a" 1 3 old new)))
      (should (< id1 id2))
      (should (< id2 id3)))))

(ert-deftest decklet-test-review-log-append-rated-null-pre-stability ()
  ;; A first-ever review has nil stability/difficulty.  These must
  ;; serialise to JSON null, not break the writer.
  (decklet-test--with-temp-db
    (let* ((old (make-decklet-card-meta
                 :instance-id 7
                 :state :learning
                 :stability nil
                 :difficulty nil))
           (new (make-decklet-card-meta
                 :instance-id 7
                 :state :learning
                 :stability 2.1
                 :difficulty 5.0
                 :last-review (decklet--now))))
      (decklet-review-log-append-rated "novel" 7 3 old new)
      (let ((rec (car (decklet-test--read-log))))
        (should (null (plist-get rec :pre_stability)))
        (should (null (plist-get rec :pre_difficulty)))
        (should (numberp (plist-get rec :post_stability)))
        (should (= 0.0 (plist-get rec :elapsed_days)))))))

;; ---------------------------------------------------------------------------
;; decklet-review-log-append-void
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-log-append-void-records-target-id ()
  (decklet-test--with-temp-db
    (decklet-review-log-append-void 12345)
    (let ((rec (car (decklet-test--read-log))))
      (should (equal "void" (plist-get rec :kind)))
      (should (= 12345 (plist-get rec :voids)))
      (should (stringp (plist-get rec :t))))))

(ert-deftest decklet-test-review-log-void-then-rated-both-present ()
  (decklet-test--with-temp-db
    (let* ((old (make-decklet-card-meta :instance-id 1 :state :review
                                        :stability 4.0 :difficulty 5.0))
           (new (copy-decklet-card-meta old))
           (id1 (decklet-review-log-append-rated "w" 1 3 old new)))
      (decklet-review-log-append-void id1)
      (let* ((records (decklet-test--read-log))
             (kinds (mapcar (lambda (r) (plist-get r :kind)) records)))
        (should (equal '("rated" "void") kinds))
        (should (= id1 (plist-get (nth 1 records) :voids)))))))

;; ---------------------------------------------------------------------------
;; decklet-review-log-append-rename
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-review-log-append-rename-captures-both-words ()
  (decklet-test--with-temp-db
    (decklet-review-log-append-rename 99 "colour" "color")
    (let ((rec (car (decklet-test--read-log))))
      (should (equal "rename" (plist-get rec :kind)))
      (should (= 99 (plist-get rec :card_id)))
      (should (equal "colour" (plist-get rec :old)))
      (should (equal "color" (plist-get rec :new))))))

;; ---------------------------------------------------------------------------
;; decklet-rate-card integration
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-rate-card-writes-log-and-returns-id ()
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (decklet--add-card "inveigh")
    (let ((log-id (decklet-rate-card "inveigh" 3)))
      (should (integerp log-id))
      (let ((records (decklet-test--read-log)))
        (should (= 1 (length records)))
        (let ((rec (car records)))
          (should (equal "rated" (plist-get rec :kind)))
          (should (equal "inveigh" (plist-get rec :word)))
          (should (= 3 (plist-get rec :grade)))
          (should (= log-id (plist-get rec :id)))
          (should (integerp (plist-get rec :card_id))))))))

;; ---------------------------------------------------------------------------
;; decklet-rename-word integration
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-rename-word-appends-rename-log-entry ()
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (decklet--add-card "colour")
    (let* ((meta (decklet--load-card-meta "colour"))
           (card-id (decklet-card-meta-instance-id meta)))
      (decklet-rename-word "colour" "color")
      (let ((rec (car (decklet-test--read-log))))
        (should (equal "rename" (plist-get rec :kind)))
        (should (= card-id (plist-get rec :card_id)))
        (should (equal "colour" (plist-get rec :old)))
        (should (equal "color" (plist-get rec :new)))))))

;; ---------------------------------------------------------------------------
;; decklet--add-card and instance_id minting
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-add-card-mints-instance-id-on-fresh-create ()
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (decklet--add-card "alpha")
    (let* ((meta (decklet--load-card-meta "alpha"))
           (id (decklet-card-meta-instance-id meta)))
      (should (integerp id))
      (should (> id 0)))))

(ert-deftest decklet-test-add-card-refresh-preserves-instance-id ()
  ;; Re-adding an existing new (never-reviewed) card should NOT mint
  ;; a new instance_id — the card's identity hasn't changed.
  (decklet-test--with-temp-db
    (let ((decklet-add-and-refresh t))
      (decklet-db--ensure)
      (decklet--add-card "alpha")
      (let* ((first-id (decklet-card-meta-instance-id
                        (decklet--load-card-meta "alpha"))))
        (decklet--add-card "alpha")
        (let* ((second-id (decklet-card-meta-instance-id
                           (decklet--load-card-meta "alpha"))))
          (should (= first-id second-id)))))))

(ert-deftest decklet-test-add-card-delete-re-add-mints-new-instance-id ()
  ;; After deleting and re-adding with the same word, the new card
  ;; should have a different instance_id — it's a fresh card
  ;; instance, not a continuation.
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (decklet--add-card "beta")
    (let ((first-id (decklet-card-meta-instance-id
                     (decklet--load-card-meta "beta"))))
      (decklet-delete-card "beta")
      (decklet--add-card "beta")
      (let ((second-id (decklet-card-meta-instance-id
                        (decklet--load-card-meta "beta"))))
        (should (integerp second-id))
        (should (not (= first-id second-id)))
        (should (> second-id first-id))))))

(provide 'decklet-review-log-test)
;;; decklet-review-log-test.el ends here

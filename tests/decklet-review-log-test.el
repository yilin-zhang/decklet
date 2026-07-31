;;; decklet-review-log-test.el --- Tests for decklet-review-log -*- lexical-binding: t; -*-

(require 'decklet-test-helpers)

;;; Appending records

(ert-deftest decklet-test-review-log-append-rated-writes-record ()
  "A rated event writes one line carrying identity, grade, pre/post state, and
a monotonic record id."
  (decklet-test--with-temp-db
   (let ((old (make-decklet-card-meta :card-id 42 :state :review :stability 4.5
                                      :difficulty 5.1 :last-review "2026-04-01T00:00:00Z"))
         (new (make-decklet-card-meta :card-id 42 :state :review :stability 5.2
                                      :difficulty 5.3 :last-review (decklet--now))))
     (decklet-review-log-append-rated "ephemeral" 42 3 old new)
     (let ((rec (car (decklet-test--read-log))))
       (should (equal "rated" (plist-get rec :kind)))
       (should (equal "ephemeral" (plist-get rec :word)))
       (should (= 42 (plist-get rec :card_id)))
       (should (= 3 (plist-get rec :grade)))
       (should (equal "review" (plist-get rec :pre_state)))
       (should (equal "review" (plist-get rec :post_state)))
       (should (numberp (plist-get rec :pre_stability)))
       (should (numberp (plist-get rec :elapsed_days)))
       (should (integerp (plist-get rec :id)))))))

(ert-deftest decklet-test-review-log-append-rated-returns-monotonic-ids ()
  "Each rated append returns a strictly increasing record id."
  (decklet-test--with-temp-db
   (let* ((old (make-decklet-card-meta :card-id 1 :state :review
                                       :stability 3.0 :difficulty 5.0))
          (new (copy-decklet-card-meta old))
          (id1 (decklet-review-log-append-rated "a" 1 3 old new))
          (id2 (decklet-review-log-append-rated "a" 1 3 old new))
          (id3 (decklet-review-log-append-rated "a" 1 3 old new)))
     (should (< id1 id2))
     (should (< id2 id3)))))

(ert-deftest decklet-test-review-log-append-rated-serializes-nil-stability ()
  "A first-ever review has nil pre-stability/difficulty, serialized as JSON null,
and zero elapsed days."
  (decklet-test--with-temp-db
   (let ((old (make-decklet-card-meta :card-id 7 :state :learning
                                      :stability nil :difficulty nil))
         (new (make-decklet-card-meta :card-id 7 :state :learning :stability 2.1
                                      :difficulty 5.0 :last-review (decklet--now))))
     (decklet-review-log-append-rated "novel" 7 3 old new)
     (let ((rec (car (decklet-test--read-log))))
       (should (null (plist-get rec :pre_stability)))
       (should (null (plist-get rec :pre_difficulty)))
       (should (numberp (plist-get rec :post_stability)))
       (should (= 0.0 (plist-get rec :elapsed_days)))))))

(ert-deftest decklet-test-review-log-void-targets-a-rated-id ()
  "A void event records the rated id it nullifies, appended after the rated line."
  (decklet-test--with-temp-db
   (let* ((old (make-decklet-card-meta :card-id 1 :state :review
                                       :stability 4.0 :difficulty 5.0))
          (new (copy-decklet-card-meta old))
          (id (decklet-review-log-append-rated "w" 1 3 old new)))
     (decklet-review-log-append-void id)
     (let ((records (decklet-test--read-log)))
       (should (equal '("rated" "void") (mapcar (lambda (r) (plist-get r :kind)) records)))
       (should (= id (plist-get (nth 1 records) :voids)))))))

(ert-deftest decklet-test-review-log-append-rename-captures-both-words ()
  "A rename event records the card id and both the old and new words."
  (decklet-test--with-temp-db
   (decklet-review-log-append-rename 99 "colour" "color")
   (let ((rec (car (decklet-test--read-log))))
     (should (equal "rename" (plist-get rec :kind)))
     (should (= 99 (plist-get rec :card_id)))
     (should (equal "colour" (plist-get rec :old)))
     (should (equal "color" (plist-get rec :new))))))

;;; Integration with the public API

(ert-deftest decklet-test-review-log-rate-card-writes-and-returns-id ()
  "`decklet-rate-card' logs a rated event and returns its record id."
  (decklet-test--with-temp-db
   (decklet--add-card "inveigh")
   (let ((log-id (decklet-rate-card (decklet-test--card-id "inveigh") 3)))
     (should (integerp log-id))
     (let ((rec (car (decklet-test--read-log))))
       (should (equal "rated" (plist-get rec :kind)))
       (should (equal "inveigh" (plist-get rec :word)))
       (should (= 3 (plist-get rec :grade)))
       (should (= log-id (plist-get rec :id)))))))

(ert-deftest decklet-test-review-log-rename-card-appends-rename ()
  "`decklet-set-card-word' logs a rename event."
  (decklet-test--with-temp-db
   (decklet--add-card "colour")
   (let ((id (decklet-test--card-id "colour")))
     (decklet-set-card-word id "color")
     (let ((rec (car (decklet-test--read-log))))
       (should (equal "rename" (plist-get rec :kind)))
       (should (= id (plist-get rec :card_id)))
       (should (equal "colour" (plist-get rec :old)))
       (should (equal "color" (plist-get rec :new)))))))

;;; Writer failure path
;; A dropped log record is preferable to a lost rating, so the writer swallows
;; write errors and the rating still persists.

(ert-deftest decklet-test-review-log-append-returns-nil-on-write-failure ()
  "When the write fails, both the low-level and rated appenders return nil
instead of signalling."
  (decklet-test--with-temp-db
   (cl-letf (((symbol-function 'write-region)
              (lambda (&rest _) (error "simulated disk full"))))
     (should-not (decklet-review-log--append-line
		  (list :kind "void" :voids 1 :t (decklet--now))))
     (let* ((old (make-decklet-card-meta :card-id 1 :state :review
					 :stability 3.0 :difficulty 5.0))
	    (new (copy-decklet-card-meta old)))
       (should-not (decklet-review-log-append-rated "boom" 1 3 old new))))))

(ert-deftest decklet-test-review-log-directory-cache-follows-file-changes ()
  "Changing `decklet-review-log-file' creates the new parent directory."
  (decklet-test--with-temp-db
   (let ((file-a (expand-file-name "logs-a/review-log.jsonl" tmp-dir))
         (file-b (expand-file-name "logs-b/review-log.jsonl" tmp-dir)))
     (let ((decklet-review-log-file file-a))
       (should (decklet-review-log--append-line
                (list :kind "void" :voids 1 :t (decklet--now)))))
     (let ((decklet-review-log-file file-b))
       (should (decklet-review-log--append-line
                (list :kind "void" :voids 2 :t (decklet--now)))))
     (should (file-exists-p file-a))
     (should (file-exists-p file-b)))))

(ert-deftest decklet-test-review-log-rate-card-survives-write-failure ()
  "A log-write failure does not abort `decklet-rate-card': the FSRS state still
advances and persists, only the log id comes back nil."
  (decklet-test--with-temp-db
   (decklet--add-card "resilient")
   (let ((log-id (cl-letf (((symbol-function 'write-region)
                            (lambda (&rest _) (error "simulated disk full"))))
		   (decklet-rate-card (decklet-test--card-id "resilient") 3))))
     (should-not log-id))
   (let ((meta (decklet-get-card-meta (decklet-test--card-id "resilient"))))
     (should (decklet-card-meta-last-review meta)))))

(provide 'decklet-review-log-test)
;;; decklet-review-log-test.el ends here

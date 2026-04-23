;;; decklet-deck-test.el --- Tests for decklet-deck.el and card display -*- lexical-binding: t; -*-

(require 'decklet-test-helpers)

;; ---------------------------------------------------------------------------
;; Card effective state derivation
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-card-effective-state-derivation ()
  (should (eq (decklet-card-effective-state :learning nil) :new))
  (should (eq (decklet-card-effective-state :learning "") :new))
  (should (eq (decklet-card-effective-state :learning "2025-01-01T00:00:00Z") :learning))
  (should (eq (decklet-card-effective-state :relearning "2025-01-01T00:00:00Z") :relearning))
  (should (eq (decklet-card-effective-state :review "2025-01-01T00:00:00Z") :review))
  (should (eq (decklet-card-effective-state :unknown "2025-01-01T00:00:00Z") :review)))

(ert-deftest decklet-test-card-meta-effective-state-derivation ()
  (should
   (eq (decklet-card-meta-effective-state
        (make-decklet-card-meta :state :learning :last-review nil))
       :new))
  (should
   (eq (decklet-card-meta-effective-state
        (make-decklet-card-meta :state :learning
                                :last-review "2025-01-01T00:00:00Z"))
       :learning)))

;; ---------------------------------------------------------------------------
;; Batch card collection mode
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-add-card-batch-mode-highlights-hint-lines ()
  (with-temp-buffer
    (decklet-add-card-batch-mode)
    (should (equal font-lock-defaults
                   '(decklet-add-card-batch-font-lock-keywords)))))

;; ---------------------------------------------------------------------------
;; Card back — buffer utilities
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-card-back-buffer-name-format ()
  "Buffer name follows *Decklet Card Back: WORD* convention."
  (should (string= "*Decklet Card Back: hello*"
                   (decklet-card-back--buffer-name "hello"))))

(ert-deftest decklet-test-card-back-show-creates-readonly-buffer-with-content ()
  "decklet-show-card-back opens a read-only buffer with the stored back content."
  (decklet-test--with-temp-db
   (decklet-db--upsert-card "bright"
                            (make-decklet-card-meta
                             :added-date "20250101T000000Z"
                             :due "20250101T000000Z"
                             :state :new))
   (decklet-db--update-back
    (plist-get (decklet-db--select-card-row-by-word "bright") :card-id)
    "shining example")
   ;; Mock pop-to-buffer to avoid needing a live window during tests.
   (cl-letf (((symbol-function 'pop-to-buffer) (lambda (_buf) nil)))
     (decklet-show-card-back "bright"))
   (let ((buf (get-buffer (decklet-card-back--buffer-name "bright"))))
     (unwind-protect
         (progn
           (should (buffer-live-p buf))
           (with-current-buffer buf
             (should (string= "shining example"
                              (buffer-substring-no-properties
                               (point-min) (point-max))))
             (should buffer-read-only)))
       (when (buffer-live-p buf)
         (kill-buffer buf))))))

(ert-deftest decklet-test-card-back-show-editable-when-back-absent ()
  "decklet-show-card-back opens an editable buffer when the card has no back."
  (decklet-test--with-temp-db
   (decklet-db--upsert-card "glow"
                            (make-decklet-card-meta
                             :added-date "20250101T000000Z"
                             :due "20250101T000000Z"
                             :state :new))
   (cl-letf (((symbol-function 'pop-to-buffer) (lambda (_buf) nil)))
     (decklet-show-card-back "glow"))
   (let ((buf (get-buffer (decklet-card-back--buffer-name "glow"))))
     (unwind-protect
         (with-current-buffer buf
           (should-not buffer-read-only))
       (when (buffer-live-p buf)
         (kill-buffer buf))))))

(ert-deftest decklet-test-card-back-save-errors-when-read-only ()
  "decklet-save-card-back signals user-error when buffer is read-only."
  (with-temp-buffer
    (setq buffer-read-only t)
    (should-error (decklet-save-card-back) :type 'user-error)))

(ert-deftest decklet-test-card-back-mode-uses-buffer-local-write-hook ()
  "Enabling `decklet-card-back-mode' must not touch the global value of
`write-contents-functions' — regression test for the lambda+global
`add-hook' that would accumulate a save handler per card-back buffer."
  (let ((before (default-value 'write-contents-functions)))
    (with-temp-buffer
      (decklet-card-back-mode 1)
      (should (equal (default-value 'write-contents-functions) before))
      (should (memq #'decklet-card-back--write-contents
                    write-contents-functions))
      (decklet-card-back-mode 0)
      (should (equal (default-value 'write-contents-functions) before))
      (should-not (memq #'decklet-card-back--write-contents
                        write-contents-functions)))))

(defun decklet-test--open-dirty-card-back (word original-back new-content)
  "Seed a card for WORD with ORIGINAL-BACK, open its card-back popup, and
leave the buffer modified with NEW-CONTENT.  Return the buffer.
Caller is responsible for killing the buffer on teardown."
  (decklet-db--upsert-card word
                           (make-decklet-card-meta
                            :added-date "20250101T000000Z"
                            :due "20250101T000000Z"
                            :state :new))
  (decklet-db--update-back
   (plist-get (decklet-db--select-card-row-by-word word) :card-id)
   original-back)
  (cl-letf (((symbol-function 'pop-to-buffer) (lambda (_buf) nil)))
    (decklet-show-card-back word))
  (let ((buf (get-buffer (decklet-card-back--buffer-name word))))
    (with-current-buffer buf
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert new-content)
      (set-buffer-modified-p t))
    buf))

(ert-deftest decklet-test-card-back-kill-query-save-writes-and-kills ()
  "Choosing save on a dirty card-back kill writes the new content to the
DB and lets `kill-buffer' proceed."
  (decklet-test--with-temp-db
   (let ((buf (decklet-test--open-dirty-card-back "bright" "old-back" "new-back")))
     (unwind-protect
         (progn
           (cl-letf (((symbol-function 'read-char-choice)
                      (lambda (_prompt _chars) ?s)))
             (kill-buffer buf))
           (should-not (buffer-live-p buf))
           (should (string= "new-back"
                            (decklet-db--select-card-back
                             (plist-get
                              (decklet-db--select-card-row-by-word "bright")
                              :card-id)))))
       (when (buffer-live-p buf)
         (with-current-buffer buf (set-buffer-modified-p nil))
         (kill-buffer buf))))))

(ert-deftest decklet-test-card-back-kill-query-discard-kills-without-write ()
  "Choosing discard kills the buffer without writing; DB keeps old back."
  (decklet-test--with-temp-db
   (let ((buf (decklet-test--open-dirty-card-back "bright" "old-back" "new-back")))
     (unwind-protect
         (progn
           (cl-letf (((symbol-function 'read-char-choice)
                      (lambda (_prompt _chars) ?d)))
             (kill-buffer buf))
           (should-not (buffer-live-p buf))
           (should (string= "old-back"
                            (decklet-db--select-card-back
                             (plist-get
                              (decklet-db--select-card-row-by-word "bright")
                              :card-id)))))
       (when (buffer-live-p buf)
         (with-current-buffer buf (set-buffer-modified-p nil))
         (kill-buffer buf))))))

(ert-deftest decklet-test-card-back-kill-query-cancel-keeps-buffer-and-db ()
  "Choosing cancel aborts the kill; buffer stays alive and modified, DB
keeps its old back."
  (decklet-test--with-temp-db
   (let ((buf (decklet-test--open-dirty-card-back "bright" "old-back" "new-back")))
     (unwind-protect
         (progn
           (cl-letf (((symbol-function 'read-char-choice)
                      (lambda (_prompt _chars) ?c)))
             (kill-buffer buf))
           (should (buffer-live-p buf))
           (with-current-buffer buf
             (should (buffer-modified-p)))
           (should (string= "old-back"
                            (decklet-db--select-card-back
                             (plist-get
                              (decklet-db--select-card-row-by-word "bright")
                              :card-id)))))
       (when (buffer-live-p buf)
         (with-current-buffer buf (set-buffer-modified-p nil))
         (kill-buffer buf))))))

;; (ert-deftest decklet-test-card-back-save-updates-db-and-calls-on-save ()
;;   "decklet-save-card-back writes back to DB and invokes on-save callback."
;;   (decklet-test--with-temp-db
;;     (decklet-db--upsert-card "radiant"
;;                              (make-decklet-card-meta
;;                               :added-date "20250101T000000Z"
;;                               :due "20250101T000000Z"
;;                               :state :new))
;;     ;; Mock pop-to-buffer (no window) and quit-window (no window config to restore).
;;     (cl-letf (((symbol-function 'pop-to-buffer) (lambda (_buf) nil))
;;               ((symbol-function 'quit-window) (lambda (&rest _) nil)))
;;       (decklet-card-back--open "radiant" nil))
;;     (let ((buf (get-buffer (decklet-card-back--buffer-name "radiant")))
;;           (on-save-called nil))
;;       (unwind-protect
;;           (with-current-buffer buf
;;             (setq-local decklet-card-back--callback (lambda () (setq on-save-called t)))
;;             (erase-buffer)
;;             (insert "a vivid glow")
;;             (decklet-save-card-back)
;;             (should (string= "a vivid glow"
;;                              (decklet-db--select-card-back
;;                               (plist-get (decklet-db--select-card-row-by-word "radiant") :card-id))))
;;             (should on-save-called))
;;         (when (buffer-live-p buf)
;;           (kill-buffer buf))))))

;; ---------------------------------------------------------------------------
;; Batch card collection parsing
;; ---------------------------------------------------------------------------
;; These tests protect batch-mode hint parsing: multi-line hints accumulate
;; under the preceding word, and orphan hints (no preceding word) must fail.

(ert-deftest decklet-test-batch-collect-cards-supports-hint-lines ()
  (with-temp-buffer
    (insert "\n  lucid  \n# adj.\n\n\t\n# lucid rain\n  dirt\n# ...\n")
    (should
     (equal (decklet--batch-collect-cards)
            '((:word "lucid" :hint "adj.\nlucid rain")
              (:word "dirt" :hint "..."))))))

(ert-deftest decklet-test-batch-collect-cards-rejects-orphan-hint ()
  (with-temp-buffer
    (insert "# lonely hint\nlucid\n")
    (should-error (decklet--batch-collect-cards))))

(provide 'decklet-deck-test)
;;; decklet-deck-test.el ends here

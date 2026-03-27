;;; decklet-deck-test.el --- Tests for decklet-deck.el and card display -*- lexical-binding: t; -*-

(require 'decklet-test-helpers)

;; ---------------------------------------------------------------------------
;; Card display state derivation
;; ---------------------------------------------------------------------------

(ert-deftest decklet-test-card-display-state-derivation ()
  (should (eq (decklet-card-display-state :learning nil) :new))
  (should (eq (decklet-card-display-state :learning "") :new))
  (should (eq (decklet-card-display-state :learning "2025-01-01T00:00:00Z") :learning))
  (should (eq (decklet-card-display-state :relearning "2025-01-01T00:00:00Z") :relearning))
  (should (eq (decklet-card-display-state :review "2025-01-01T00:00:00Z") :review))
  (should (eq (decklet-card-display-state :unknown "2025-01-01T00:00:00Z") :review)))

(ert-deftest decklet-test-card-meta-display-state-derivation ()
  (should
   (eq (decklet-card-meta-display-state
        (make-decklet-card-meta :state :learning :last-review nil))
       :new))
  (should
   (eq (decklet-card-meta-display-state
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

(ert-deftest decklet-test-card-back-kill-buffers-only-kills-matching ()
  "kill-buffers kills card-back buffers and leaves unrelated ones alone."
  (let* ((back-buf (get-buffer-create "*Decklet Card Back: x*"))
         (other-buf (get-buffer-create "*SomeOtherBuffer*")))
    (unwind-protect
        (progn
          (decklet-card-back--kill-buffers)
          (should-not (buffer-live-p back-buf))
          (should (buffer-live-p other-buf)))
      (when (buffer-live-p other-buf)
        (kill-buffer other-buf)))))

(ert-deftest decklet-test-card-back-open-creates-buffer-with-content ()
  "decklet-card-back--open populates buffer with stored back content."
  (decklet-test--with-temp-db
    (decklet-db--upsert-card "bright"
                             (make-decklet-card-meta
                              :added-date "20250101T000000Z"
                              :due "20250101T000000Z"
                              :state :new))
    (decklet-db--update-back "bright" "shining example")
    ;; Mock pop-to-buffer to avoid needing a live window during tests.
    (cl-letf (((symbol-function 'pop-to-buffer) (lambda (_buf) nil)))
      (decklet-card-back--open "bright" t))
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

(ert-deftest decklet-test-card-back-open-editable-not-read-only ()
  "decklet-card-back--open with read-only-p nil creates editable buffer."
  (decklet-test--with-temp-db
    (decklet-db--upsert-card "glow"
                             (make-decklet-card-meta
                              :added-date "20250101T000000Z"
                              :due "20250101T000000Z"
                              :state :new))
    (cl-letf (((symbol-function 'pop-to-buffer) (lambda (_buf) nil)))
      (decklet-card-back--open "glow" nil))
    (let ((buf (get-buffer (decklet-card-back--buffer-name "glow"))))
      (unwind-protect
          (with-current-buffer buf
            (should-not buffer-read-only))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(ert-deftest decklet-test-card-back-save-errors-when-read-only ()
  "decklet-card-back-save signals user-error when buffer is read-only."
  (with-temp-buffer
    (setq buffer-read-only t)
    (should-error (decklet-card-back-save) :type 'user-error)))

(ert-deftest decklet-test-card-back-save-updates-db-and-calls-on-save ()
  "decklet-card-back-save writes back to DB and invokes on-save callback."
  (decklet-test--with-temp-db
    (decklet-db--upsert-card "radiant"
                             (make-decklet-card-meta
                              :added-date "20250101T000000Z"
                              :due "20250101T000000Z"
                              :state :new))
    ;; Mock pop-to-buffer (no window) and quit-window (no window config to restore).
    (cl-letf (((symbol-function 'pop-to-buffer) (lambda (_buf) nil))
              ((symbol-function 'quit-window) (lambda (&rest _) nil)))
      (decklet-card-back--open "radiant" nil))
    (let ((buf (get-buffer (decklet-card-back--buffer-name "radiant")))
          (on-save-called nil))
      (unwind-protect
          (with-current-buffer buf
            (setq-local decklet-card-back--on-save (lambda () (setq on-save-called t)))
            (erase-buffer)
            (insert "a vivid glow")
            (decklet-card-back-save)
            (should (string= "a vivid glow"
                             (decklet-db--select-card-back "radiant")))
            (should on-save-called))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(provide 'decklet-deck-test)
;;; decklet-deck-test.el ends here

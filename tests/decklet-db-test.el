;;; decklet-db-test.el --- Tests for decklet-db.el -*- lexical-binding: t; -*-

;;; Code:

(require 'decklet-test-helpers)

;;; Card identity and fields

(ert-deftest decklet-test-db-scheduling-writes-keep-user-fields ()
  "Rating and renaming a card leave its hint, back and tags alone."
  (decklet-test--with-temp-db
    (decklet--add-card "lucid")
    (let ((id (decklet-test--card-id "lucid")))
      (decklet-set-card-hint id "adj.")
      (decklet-set-card-back id "clear and bright")
      (decklet-set-card-tags id '("reading"))
      (decklet-rate-card id 3)
      (decklet-set-card-word id "lucidity")
      (should (equal "adj." (decklet-get-card-hint id)))
      (should (equal "clear and bright" (decklet-get-card-back id)))
      (should (equal '("reading") (decklet-get-card-tags id))))))

;;; Connection lifecycle

(ert-deftest decklet-test-db-connection-lives-while-a-session-buffer-does ()
  "The connection stays open until the last session buffer is killed.
An open card-back popup does not keep it open."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (decklet-test--with-temp-buffers (first second popup)
      (dolist (buf (list first second))
        (with-current-buffer buf (decklet-db--acquire-session-buffer)))
      (with-current-buffer popup (decklet-card-back-mode 1))
      (kill-buffer first)
      (should decklet-db--conn)
      (kill-buffer second)
      (should (buffer-live-p popup))
      (should-not decklet-db--conn))))

(ert-deftest decklet-test-db-disconnect-needs-every-session-buffer-to-die ()
  "`decklet-disconnect' keeps the DB open if a session buffer refuses to die.
Once every buffer can die, it kills them all, closes the DB, and runs
the pre-disconnect hook exactly once."
  (decklet-test--with-temp-db
    (decklet-db--ensure)
    (decklet-test--with-temp-buffers (plain stubborn)
      (dolist (buf (list plain stubborn))
        (with-current-buffer buf (decklet-db--acquire-session-buffer)))
      (with-current-buffer stubborn
        (add-hook 'kill-buffer-query-functions #'ignore nil t))
      (let* ((hook-count 0)
             (decklet-db-pre-disconnect-hook (list (lambda () (cl-incf hook-count)))))
        (should-error (decklet-disconnect) :type 'user-error)
        (should (buffer-live-p stubborn))
        (should decklet-db--conn)
        (should (= hook-count 0))
        (with-current-buffer stubborn
          (remove-hook 'kill-buffer-query-functions #'ignore t))
        (decklet-disconnect)
        (should-not (buffer-live-p plain))
        (should-not (buffer-live-p stubborn))
        (should-not decklet-db--conn)
        (should (= hook-count 1))))))

(ert-deftest decklet-test-db-pre-connect-hook-gates-each-connection ()
  "The pre-connect hook can refuse a connection, and runs once per opening."
  (decklet-test--with-temp-db
    (let ((decklet-db-pre-connect-hook (list (lambda () (user-error "Refused")))))
      (should-error (decklet-db--ensure) :type 'user-error)
      (should-not decklet-db--conn)
      (should-not (file-exists-p decklet-db-file)))
    (let* ((hook-count 0)
           (decklet-db-pre-connect-hook (list (lambda () (cl-incf hook-count)))))
      (decklet-db--ensure)
      (decklet-db--ensure)
      (should (= hook-count 1)))))

(ert-deftest decklet-test-db-with-db-disconnects-when-idle-and-outermost ()
  "`decklet-with-db' closes an idle connection only at the outermost exit.
It keeps the connection open while a session buffer lives, and still
disconnects when the body signals an error."
  (decklet-test--with-temp-db
    ;; Nested calls share one connection and disconnect only once at the end.
    (let* ((disconnects 0)
           (decklet-db-pre-disconnect-hook
            (list (lambda () (cl-incf disconnects)))))
      (decklet-with-db
        (decklet-db--ensure)
        (decklet-with-db
          (should decklet-db--conn))
        (should decklet-db--conn)
        (should (= disconnects 0)))
      (should-not decklet-db--conn)
      (should (= disconnects 1)))
    ;; Errors still release an idle connection.
    (should-error
     (decklet-with-db
       (decklet-db--ensure)
       (error "Boom")))
    (should-not decklet-db--conn)
    ;; A live session buffer keeps the connection open across `decklet-with-db'.
    (decklet-test--with-temp-buffers (session)
      (with-current-buffer session (decklet-db--acquire-session-buffer))
      (decklet-with-db
        (decklet-db--ensure))
      (should decklet-db--conn))))

;;; Calendar due counts

(ert-deftest decklet-test-db-due-counts-by-date-splits-overdue-and-range ()
  "`decklet-db-due-counts-by-date' separates overdue cards from in-range ones.
This is the public API the calendar extension relies on."
  (decklet-test--with-temp-db
    (let* ((now (current-time))
           (day-start (decklet-day-start-time now))
           (cutoff (decklet--next-day-start-time now))
           (ts-added (decklet-test--ts (time-subtract now (seconds-to-time 7200))))
           (ts-last (decklet-test--ts (time-subtract now (seconds-to-time 1800)))))
      (decklet-test--add-card-meta
       "overdue-card" :added-date ts-added :last-review ts-last
       :due (decklet-test--ts (time-subtract day-start (seconds-to-time 60))))
      (decklet-test--add-card-meta
       "range-card" :added-date ts-added :last-review ts-last
       :due (decklet-test--ts (time-add day-start (seconds-to-time 3600))))
      (let ((result (decklet-db-due-counts-by-date day-start cutoff)))
        (should (= 1 (plist-get result :overdue)))
        (should (= 1 (apply #'+ (mapcar #'cadr (plist-get result :rows)))))))))

(provide 'decklet-db-test)
;;; decklet-db-test.el ends here

;;; decklet-queue.el --- Review queue for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yilin Zhang

;;; Commentary:

;; Builds the review queue from `decklet-review-order'.  It assigns due
;; cards to order groups, applies daily limits from the review log, and
;; computes the review counters.

;;; Code:

(require 'cl-lib)
(require 'seq)

(require 'decklet-core)
(require 'decklet-scheduler)
(require 'decklet-db)
(require 'decklet-review-log)

(defvar decklet-queue--cache nil
  "Inputs and result of the most recent `decklet-queue--build'.")

(defun decklet-queue--clear-cache ()
  "Drop the cached queue when the DB disconnects."
  (setq decklet-queue--cache nil))

(add-hook 'decklet-db-pre-disconnect-hook #'decklet-queue--clear-cache)

(defun decklet-queue--shuffle (lst)
  "Return a new randomly shuffled copy of LST.
Fisher-Yates; Emacs has no built-in shuffle."
  (let* ((vec (vconcat lst))
         (len (length vec)))
    (dotimes (i len)
      (let* ((j (+ i (random (- len i))))
             (tmp (aref vec i)))
        (aset vec i (aref vec j))
        (aset vec j tmp)))
    (append vec nil)))

(defun decklet-queue--interleave-evenly (base items)
  "Return a new list with ITEMS distributed evenly through BASE.
ITEMS are placed at half-stride offsets, so the result never starts
with an element of ITEMS unless BASE is empty, and never ends with
a run of them.  Order within BASE and within ITEMS is preserved."
  (let ((n-base (length base))
        (n-items (length items)))
    (cond
     ((null items) (copy-sequence base))
     ((null base) (copy-sequence items))
     (t
      (let* ((total (+ n-base n-items))
             (stride (/ (float total) n-items))
             (rest base)
             (pending items)
             ;; Half-stride offset keeps the first slot for BASE.
             (slot (round (/ stride 2.0)))
             (placed 1)
             (result nil))
        (dotimes (i total)
          (cond
           ((and pending (= i slot))
            (push (pop pending) result)
            (setq slot (round (+ (* stride placed) (/ stride 2.0)))
                  placed (1+ placed)))
           (rest (push (pop rest) result))
           (pending (push (pop pending) result))))
        (nreverse result))))))

(defun decklet-queue--compile-filter (filter)
  "Compile review FILTER into a predicate on a card's state and tags.
The predicate takes an FSRS state keyword and a list of tag strings."
  (pcase filter
    (`(state . ,(and states (pred consp) (pred proper-list-p)))
     (dolist (state states)
       (unless (memq state '(:new :learning :relearning :review))
         (error "Invalid review state: %S" state)))
     (lambda (state _tags) (memq state states)))
    (`(tag ,(and name (pred stringp)))
     (decklet-normalize-tags (list name))
     (lambda (_state tags) (member name tags)))
    (`(not ,inner)
     (let ((match (decklet-queue--compile-filter inner)))
       (lambda (state tags) (not (funcall match state tags)))))
    (`(,(and op (or 'and 'or)) . ,(and parts (pred consp) (pred proper-list-p)))
     (let ((matches (mapcar #'decklet-queue--compile-filter parts))
           (combine (if (eq op 'and) #'cl-every #'cl-some)))
       (lambda (state tags)
         (funcall combine (lambda (match) (funcall match state tags)) matches))))
    (_ (error "Invalid review filter: %S" filter))))

(defun decklet-queue--sort (items field direction)
  "Return ITEMS sorted by FIELD in DIRECTION, `:asc' or `:desc'.
Ties keep card-id order in the same direction.  An item without a
value for FIELD counts as smallest."
  (let ((less (lambda (a b)
                (let ((x (plist-get a field))
                      (y (plist-get b field)))
                  (cond ((equal x y) (< (plist-get a :card-id)
                                        (plist-get b :card-id)))
                        ((null x) t)
                        ((null y) nil)
                        ((numberp x) (< x y))
                        (t (string< x y)))))))
    (sort (copy-sequence items)
          (if (eq direction :asc)
              less
            (lambda (a b) (funcall less b a))))))

(defun decklet-queue--compile-op (op)
  "Compile review OP into a function of a group's cards and USED.
USED is how many cards the group has handed out today."
  (pcase op
    ('shuffle
     (lambda (items _used) (decklet-queue--shuffle items)))
    (`(sort ,(and field (or :due :added :last-review :stability :difficulty))
            ,(and direction (or :asc :desc)))
     (lambda (items _used) (decklet-queue--sort items field direction)))
    (`(limit ,(and n (pred natnump)))
     (lambda (items used) (seq-take items (max 0 (- n used)))))
    ('spread (error "`spread' must come last in a review group"))
    (_ (error "Invalid review operation: %S" op))))

(defun decklet-queue--compile-order (order)
  "Compile review ORDER into a list of group plists, or signal an error.
Each plist has :match, the compiled filter, :ops, the compiled
operations, and :spread, non-nil when the group ends with `spread'."
  (unless (proper-list-p order)
    (error "Invalid review order: %S" order))
  (mapcar (lambda (group)
            (unless (and (consp group) (proper-list-p group))
              (error "Invalid review group: %S" group))
            (pcase-let* ((`(,filter . ,ops) group)
                         (spread (eq (car (last ops)) 'spread)))
              (list :match (decklet-queue--compile-filter filter)
                    :ops (mapcar #'decklet-queue--compile-op
                                 (if spread (butlast ops) ops))
                    :spread spread)))
          order))

(defcustom decklet-review-order
  '(((state :learning :relearning) (sort :due :asc))
    ((state :review) shuffle)
    ((state :new) (sort :added :desc)))
  "Rules for selecting and placing due cards.
Each group is (FILTER OP...).  FILTER picks cards: (state STATE...)
with STATE one of :new, :learning, :relearning and :review, (tag NAME),
or an (and ...), (or ...) or (not ...) of filters.  A due card belongs
to the first group whose filter matches it.

The operations then run left to right on the group's cards: shuffle,
\=(sort FIELD :asc/:desc) and (limit N).  FIELD is :due, :added,
:last-review, :stability or :difficulty.  (limit N) keeps N cards
minus those the group handed out today; 0 pauses the group.  A final
spread interleaves the cards into the queue built so far; otherwise
they are appended.  See README for examples."
  :type '(repeat sexp)
  :set (lambda (symbol value)
         (decklet-queue--compile-order value)
         (set-default symbol value))
  :group 'decklet-review)

(defun decklet-queue--build (&optional time)
  "Build the review queue for TIME, shared by drawing and counters.
The result is a plist with :due, every due card, :queue, the queue,
and :limited, non-nil when a limit held cards back.  Current tags
assign both due cards and today's ratings to groups.  Unchanged inputs
reuse the queue so counter refreshes do not reshuffle cards."
  (let* ((now (or time (current-time)))
         (day-start (decklet-day-start-time now))
         ;; ((:card-id 7 :effective-state :new :added "..." ...) ...)
         (due-cards (decklet-db--due-items now))
         ;; ((:kind "rated" :card_id 7 :pre_effective_state "new" ...) ...)
         (ratings-today (decklet-review-log-ratings-since day-start))
         ;; ((:match FILTER-FN :ops (OP-FN ...) :spread nil) ...)
         (groups (decklet-queue--compile-order decklet-review-order))
         ;; #s(hash-table data (7 ("botany") 8 nil ...))
         (tags-by-card (decklet-db--tag-map))
         ;; (funcall group-index :new 7) => 2, or nil when no group matches
         (group-index
          (lambda (state card-id)
            ;; Deleted cards have no tags, so only untagged filters match.
            (cl-position-if (lambda (group)
                              (funcall (plist-get group :match)
                                       state (gethash card-id tags-by-card)))
                            groups)))
         (bucket
          (lambda (items state-fn id-fn)
            (let ((buckets (make-vector (length groups) nil)))
              (dolist (item items)
                (let ((index (funcall group-index
                                      (funcall state-fn item)
                                      (funcall id-fn item))))
                  (when index
                    (push item (aref buckets index)))))
              (mapcar #'nreverse buckets))))
         ;; One list of DUE-CARDS per group, in group order.
         (due-by-group
          (funcall bucket due-cards
                   (lambda (c) (plist-get c :effective-state))
                   (lambda (c) (plist-get c :card-id))))
         ;; Distinct cards each group handed out today, in group order.
         (used-by-group
          (mapcar (lambda (ratings)
                    (length (seq-uniq (mapcar (lambda (r) (plist-get r :card_id))
                                              ratings))))
                  (funcall bucket ratings-today
                           (lambda (r) (decklet--normalize-fsrs-state
                                        (plist-get r :pre_effective_state)))
                           (lambda (r) (plist-get r :card_id)))))
         ;; (DAY-START ORDER DUE-BY-GROUP USED-BY-GROUP), the cache key
         (inputs (list day-start (copy-tree decklet-review-order)
                       due-by-group used-by-group)))
    (unless (equal inputs (car decklet-queue--cache))
      ;; Each group runs its operations on its due cards, then appends
      ;; them to the queue or, with spread, interleaves them into it.
      (let ((queue nil)
            (limited nil))
        (cl-loop
         for group in groups
         for cards in due-by-group
         for used in used-by-group
         do (let ((picked cards))
              (dolist (op (plist-get group :ops))
                (setq picked (funcall op picked used)))
              (when (< (length picked) (length cards))
                (setq limited t))
              (setq queue (if (plist-get group :spread)
                              (decklet-queue--interleave-evenly queue picked)
                            (append queue picked)))))
        (setq decklet-queue--cache
              (cons inputs (list :queue queue :limited limited)))))
    `(:due ,due-cards ,@(cdr decklet-queue--cache))))

(defun decklet-queue--due-card-ids ()
  "Return card ids due for review according to `decklet-review-order'."
  (mapcar (lambda (card) (plist-get card :card-id))
          (plist-get (decklet-queue--build) :queue)))

(defun decklet-queue--counts ()
  "Return the review counter plist.
`:due-review', `:due-learning' and `:new' count the cards due today.
Their `-remaining' companions count what the queue still hands out,
and `:limited' is non-nil when a daily limit holds cards back."
  (let* ((now (current-time))
         (built (decklet-queue--build now))
         (count (lambda (key &rest states)
                  (cl-count-if (lambda (card)
                                 (memq (plist-get card :effective-state) states))
                               (plist-get built key)))))
    (list :reviewed (decklet-db--reviewed-count
                     (decklet-day-start-time now)
                     (decklet--next-day-start-time now))
          :due-review (funcall count :due :review)
          :due-learning (funcall count :due :learning :relearning)
          :new (funcall count :due :new)
          :due-review-remaining (funcall count :queue :review)
          :due-learning-remaining (funcall count :queue :learning :relearning)
          :new-remaining (funcall count :queue :new)
          :limited (plist-get built :limited))))

(provide 'decklet-queue)
;;; decklet-queue.el ends here

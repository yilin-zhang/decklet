;;; decklet-queue.el --- Review queue planning for Decklet -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Yilin Zhang

;;; Commentary:

;; Plans the review queue from `decklet-review-order'.  It assigns due
;; cards to order groups, applies daily limits from the review log, and
;; computes the review counters.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'sqlite)

(require 'decklet-core)
(require 'decklet-scheduler)
(require 'decklet-db)
(require 'decklet-review-log)

(defvar decklet-queue--plan-cache nil
  "Cached input and result of the most recent queue plan.")

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

(defun decklet-queue--run (groups group-cards used)
  "Run GROUPS on their GROUP-CARDS and return the queue plan.
USED lists how many cards each group handed out today.  The plan is a
plist with :items, the queue, and :limited, non-nil when a limit held
cards back."
  (let ((queue nil)
        (limited nil))
    (while groups
      (let* ((group (pop groups))
             (cards (pop group-cards))
             (count (pop used))
             (picked cards))
        (dolist (op (plist-get group :ops))
          (setq picked (funcall op picked count)))
        (when (< (length picked) (length cards))
          (setq limited t))
        (setq queue (if (plist-get group :spread)
                        (decklet-queue--interleave-evenly queue picked)
                      (append queue picked)))))
    (list :items queue :limited limited)))

(defun decklet-queue--plan (&optional time)
  "Return a queue plan for TIME, shared by drawing and counters.
The result contains :due, every due card, :items, the queue, and
:limited.  Current tags assign both due cards and today's ratings to
groups.  Unchanged inputs reuse the queue so counter refreshes do not
reshuffle cards."
  (let* ((now (or time (current-time)))
         (due (decklet-db--due-items now))
         (groups (decklet-queue--compile-order decklet-review-order))
         (tags (decklet-db--tag-map))
         (owner (lambda (state card-id)
                  ;; Deleted cards have no tags, so only untagged filters match.
                  (cl-position-if (lambda (group)
                                    (funcall (plist-get group :match)
                                             state (gethash card-id tags)))
                                  groups)))
         (by-owner (seq-group-by (lambda (item)
                                   (funcall owner (plist-get item :state)
                                            (plist-get item :card-id)))
                                 due))
         (group-cards (cl-loop for index below (length groups)
                               collect (alist-get index by-owner)))
         (ratings (decklet-review-log-daily-card-states now))
         (used (cl-loop for index below (length groups)
                        collect (seq-count (pcase-lambda (`(,card-id . ,state))
                                             (eql index (funcall owner state card-id)))
                                           ratings)))
         (key (list decklet-db--conn (decklet-day-start-time now)
                    (copy-tree decklet-review-order) group-cards used)))
    (unless (equal key (car decklet-queue--plan-cache))
      (setq decklet-queue--plan-cache
            (cons key (decklet-queue--run groups group-cards used))))
    (cl-list* :due due (cdr decklet-queue--plan-cache))))

(defun decklet-queue--due-card-ids ()
  "Return card ids due for review according to `decklet-review-order'."
  (mapcar (lambda (item) (plist-get item :card-id))
          (plist-get (decklet-queue--plan) :items)))

(defun decklet-queue--counts ()
  "Return counter plist from database state.
The `:due-review', `:due-learning' and `:new' keys count the cards due
today.  Their `-remaining' companions count what `decklet-review-order'
will still hand out, which is smaller whenever a group has a `limit'
operation.  `:limited' is non-nil when such a limit is what is holding
cards back."
  (let* ((now (current-time))
         (plan (decklet-queue--plan now))
         (count (lambda (key &rest states)
                  (cl-count-if (lambda (item) (memq (plist-get item :state) states))
                               (plist-get plan key)))))
    (list :reviewed (caar (sqlite-select
                           (decklet-db--ensure)
                           "SELECT COUNT(*) FROM cards
                             WHERE archived_at IS NULL
                               AND last_review >= ? AND last_review < ?;"
                           (list (decklet--now
                                  (decklet-day-start-time now))
                                 (decklet--now
                                  (decklet--next-day-start-time now)))))
          :due-review (funcall count :due :review)
          :due-learning (funcall count :due :learning :relearning)
          :new (funcall count :due :new)
          :due-review-remaining (funcall count :items :review)
          :due-learning-remaining (funcall count :items :learning :relearning)
          :new-remaining (funcall count :items :new)
          :limited (plist-get plan :limited))))

(provide 'decklet-queue)
;;; decklet-queue.el ends here

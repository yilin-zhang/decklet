# Customization

Decklet's user options in detail. The [README](../README.md) covers the
common ones.

- [Review Order](#review-order)
- [Scheduling](#scheduling)
- [Review Screen](#review-screen)
- [Adding Cards](#adding-cards)
- [Data](#data)

## Review Order

`decklet-review-order` decides which cards review offers and in what order.
Each entry is a group `(FILTER OP...)`. The filter picks cards, and the
operations run on them from left to right.

```emacs-lisp
;; The default offers learning cards first, then reviews, then the newest words.
(setopt decklet-review-order
        '(((state :learning :relearning) (sort :due :asc))
          ((state :review) shuffle)
          ((state :new) (sort :added :desc))))

;; For steady intake, allow at most 120 reviews and 10 new cards a day.
(setopt decklet-review-order
        '(((state :learning :relearning) (sort :due :asc))
          ((state :review) shuffle (limit 120))
          ((state :new) (sort :added :desc) (limit 10) spread)))

;; Bulk-import topic vocabulary, but introduce only a few words each day.
(setopt decklet-review-order
        '(((state :learning :relearning) (sort :due :asc))
          ((state :review) shuffle)
          ((and (state :new) (tag "botany")) shuffle (limit 2) spread)
          ((and (state :new) (tag "medicine")) shuffle (limit 1) spread)
          ((and (state :new) (tag "astronomy")) shuffle (limit 1) spread)
          ((state :new) (sort :added :desc) (limit 10) spread)))
```

A card belongs to the first group whose filter matches it, even after that
group's limit is spent. So the last example brings in 2 botany words a day
however many you import. Cards that no group matches are not offered.

Filters, which can nest:

```emacs-lisp
(state :new)                            ; one state
(state :learning :relearning)           ; any of several states
(tag "botany")                          ; cards with this tag
(and (state :new) (tag "botany"))       ; all of these
(or (tag "botany") (tag "flower"))      ; any of these
(not (tag "paused"))                    ; not this
```

Operations:

- `shuffle` puts the cards in random order.
- `(sort FIELD DIRECTION)` sorts by `:due`, `:added`, `:last-review`,
  `:stability` or `:difficulty`, `:asc` or `:desc`. Cards without a value sort
  first in ascending order.
- `(limit N)` keeps the first `N` cards, less those the group handed out
  today.
- `spread`, as the last operation, mixes the cards evenly into the queue built
  by the groups before. Without it, they go after them.

`setopt` checks the whole order and reports the first invalid form.

### Daily Limits

`(limit N)` caps a group at `N` ratings per review day. Opening or skipping a
card does not count, restarting Emacs does not reset the count, and unused
allowance does not carry over. `N = 0` pauses the group.

A rating counts by the card's state before it, so a word first learned today
uses the `new` allowance even after it graduates. Tags are read as they are
now, so changing tags or the group order recalculates today's counts at once.

Limits suit `new` and `review`. A limit on `learning` or `relearning` also
holds back short-interval repeats.

## Scheduling

Decklet schedules cards with FSRS. Set these with `setopt` or `:custom`,
which rebuild the scheduler.

```emacs-lisp
;; Target probability of recall at review time. Higher means shorter
;; intervals and more reviews.
(setopt decklet-desired-retention 0.9)

;; Steps a new card walks through before review, as (AMOUNT UNIT) with
;; UNIT one of :sec, :minute, :hour or :day. nil skips the learning stage.
(setopt decklet-learning-steps '((10 :minute) (1 :day)))

;; Steps a lapsed card walks through before returning to review.
;; nil skips relearning.
(setopt decklet-relearning-steps '((10 :minute)))

;; FSRS weight vector (21 floats). nil uses the FSRS library defaults.
(setopt decklet-fsrs-parameters nil)
```

### Rollover Time

```emacs-lisp
;; Hour that starts a new review day. Cards due before it count toward today.
(setopt decklet-day-rollover-hour 4)
```

## Review Screen

### Hints

```emacs-lisp
;; Seconds before the hint appears. nil shows it right away.
(setopt decklet-review-hint-delay 1.5)
```

### Interval Labels

Review shows the projected interval next to each rating, such as
`Good (1d)`. To hide them:

```emacs-lisp
(setopt decklet-review-enable-interval-labels nil)
```

### Card Back

```emacs-lisp
;; Major mode of the card back buffer.
(setopt decklet-card-back-buffer-major-mode 'org-mode)

;; Marks for cards with a back, in review and in the edit table.
(setopt decklet-review-card-back-indicator "[BACK]")
(setopt decklet-edit-card-back-indicator "♦")
```

### Layout

The review screen is drawn from component functions.
`decklet-review-fixed-components` is the centered block, and
`decklet-review-floating-components` is what sits below it, such as the hint.
To hide the counters:

```emacs-lisp
(setopt decklet-review-fixed-components
        '(decklet-review-component-title
          decklet-review-component-separator
          ;; decklet-review-component-counters
          ;; decklet-review-component-separator
          decklet-review-component-daily-goal
          decklet-review-component-separator
          decklet-review-component-rates
          decklet-review-component-separator
          decklet-review-component-linebreak
          decklet-review-component-word
          decklet-review-component-linebreak
          decklet-review-component-separator))

;; Text width.
(setopt decklet-review-fill-column 50)
```

To write your own component, see
[Review UI components](extensions.md#review-ui-components).

## Adding Cards

### Add and Refresh

Adding a word that exists but was never reviewed resets its added and due time
to now. This brings a stale new card forward when new cards are sorted newest
first. Archived cards stay archived. To turn this off:

```emacs-lisp
(setopt decklet-add-and-refresh nil)
```

## Data

### Data Location

All files live under `decklet-directory` by default:

- `decklet-db-file`: the SQLite database, `decklet.sqlite`
- `decklet-review-log-file`: the review log, `review-log.jsonl`
- `decklet-backup-directory`: backups, `backups/`

To move everything, set `decklet-directory` before the package loads:

```emacs-lisp
(use-package decklet
  :custom
  (decklet-directory "~/.config/decklet"))
```

### Database

`M-x decklet-open-db-file` opens the database in `sqlite-mode`. The connection
opens when needed and closes with the last review or edit buffer.
`M-x decklet-disconnect` closes it by hand.

### Backup

Decklet backs up the database and review log when a review or edit session
starts and quits, if the database changed.

```emacs-lisp
;; nil backs up only by hand.
(setopt decklet-backup-automatic t)

;; Backups to keep. nil keeps all of them.
(setopt decklet-backup-prune-max-count 20)
```

`M-x decklet-db-backup` makes a backup now, and `M-x decklet-db-restore`
restores one you pick.

### Review Log

The review log records every rating. The database holds each card's current
state, and the log holds how it got there. Its format is in
[Writing Extensions](extensions.md#review-log).

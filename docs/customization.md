# Customization

Decklet's user options in detail. See the [README](../README.md) for the
common setup.

- [Review Order](#review-order)
- [Scheduling](#scheduling)
- [Review Screen](#review-screen)
- [Adding Cards](#adding-cards)
- [Data](#data)

## Review Order

`decklet-review-order` controls which due cards appear and in what order. Each
entry is a group `(FILTER OP...)`. `FILTER` selects cards, and the operations
run on them from left to right.

```emacs-lisp
;; By default, learning cards come first, then reviews, then newest words.
(setopt decklet-review-order
        '(((state :learning :relearning) (sort :due :asc))
          ((state :review) shuffle)
          ((state :new) (sort :added :desc))))

;; Cap daily load at 120 reviews and 10 new cards.
(setopt decklet-review-order
        '(((state :learning :relearning) (sort :due :asc))
          ((state :review) shuffle (limit 120))
          ((state :new) (sort :added :desc) (limit 10) spread)))

;; Cap new words per topic after a bulk import.
(setopt decklet-review-order
        '(((state :learning :relearning) (sort :due :asc))
          ((state :review) shuffle)
          ((and (state :new) (tag "botany")) shuffle (limit 2) spread)
          ((and (state :new) (tag "medicine")) shuffle (limit 1) spread)
          ((and (state :new) (tag "astronomy")) shuffle (limit 1) spread)
          ((state :new) (sort :added :desc) (limit 10) spread)))
```

Each due card goes to the first matching group and stays there even after that
group hits its limit. In the last example, botany cards never spill into the
catch-all `new` group. Unmatched cards are skipped.

Filters can nest:

```emacs-lisp
(state :new)                            ; one state
(state :learning :relearning)           ; any listed state
(tag "botany")                          ; has this tag
(and (state :new) (tag "botany"))       ; all match
(or (tag "botany") (tag "flower"))      ; any matches
(not (tag "paused"))                    ; negated
```

Operations:

- `shuffle` randomizes the order.
- `(sort FIELD DIRECTION)` sorts by `:due`, `:added`, `:last-review`,
  `:stability`, or `:difficulty` (`:asc` or `:desc`). Missing values come
  first in ascending order.
- `(limit N)` keeps at most `N` cards minus the number already rated from this
  group today.
- `spread` (must be last) weaves the group's cards evenly into the earlier
  groups. Without `spread`, they appear after.

`setopt` validates the whole order and reports the first invalid form.

### Daily Limits

`(limit N)` caps a group at `N` ratings per review day. Skipping a card does
not count, restarting Emacs keeps the count, and unused allowance does not
carry over. Setting `N` to `0` pauses the group.

Each rating is counted under the card's state at review time, so a new word
still counts against `new` after it moves to learning. Tag checks use each
card's current tags, so retagging or changing group order updates today's
counts immediately.

Limits are meant for `new` and `review`. Limiting `learning` or `relearning`
also blocks short-interval repeats.

## Scheduling

Decklet schedules cards with FSRS. Set these via `setopt` or `:custom` so the
scheduler rebuilds.

```emacs-lisp
;; Target recall probability at review time. Higher values mean shorter intervals.
(setopt decklet-desired-retention 0.9)

;; Learning steps as (AMOUNT UNIT), where UNIT is :sec, :minute, :hour, or :day.
;; nil skips learning.
(setopt decklet-learning-steps '((10 :minute) (1 :day)))

;; Relearning steps after a lapse. nil skips relearning.
(setopt decklet-relearning-steps '((10 :minute)))

;; 21 FSRS weights as floats. nil uses the library defaults.
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
;; Seconds before the hint appears. nil shows it immediately.
(setopt decklet-review-hint-delay 1.5)
(setopt decklet-review-hint-indicator "[HINT]")
```

### Interval Labels

Review shows the next interval on each rating button, such as `Good (1d)`. To
hide them:

```emacs-lisp
(setopt decklet-review-enable-interval-labels nil)
```

### Card Back

```emacs-lisp
;; Major mode for the card back buffer.
(setopt decklet-card-back-buffer-major-mode 'org-mode)

;; Markers for cards with a back, in review and edit mode.
(setopt decklet-review-card-back-indicator "[BACK]")
(setopt decklet-edit-card-back-indicator "♦")
```

### Layout

The review buffer renders `decklet-review-fixed-components` as a centered
block, followed by `decklet-review-floating-components` (such as the hint)
below it. For example, to hide the counters:

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

;; Wrap width for review text.
(setopt decklet-review-fill-column 50)
```

See [Review UI components](extensions.md#review-ui-components) to add your own
component.

## Adding Cards

### Add and Refresh

Re-adding an unreviewed word resets its added and due times to now, so old new
cards move to the front when sorted newest first. Archived cards stay
archived. To disable this:

```emacs-lisp
(setopt decklet-add-and-refresh nil)
```

## Data

### Data Location

All data files live under `decklet-directory`: `decklet.sqlite`,
`review-log.jsonl`, and `decklet-backup-directory` (default `"backups"`,
resolved relative to `decklet-directory`).

```emacs-lisp
(use-package decklet
  :custom
  (decklet-directory "~/.config/decklet"))
```

### Database

`M-x decklet-open-db-file` opens the database in `sqlite-mode`. Connections
open on demand and close when the last review or edit buffer closes. Use
`M-x decklet-disconnect` to close one manually.

### Backup

Decklet backs up the database and review log when review or edit mode starts
and quits, provided the database changed.

```emacs-lisp
;; nil disables automatic backups.
(setopt decklet-backup-automatic t)

;; Number of backups to keep. nil keeps all.
(setopt decklet-backup-prune-max-count 20)
```

Run `M-x decklet-db-backup` to back up now, or `M-x decklet-db-restore` to
restore a saved pair.

### Review Log

The review log stores every rating event alongside the database's current card
state. See [Review Log](extensions.md#review-log) for the file format.

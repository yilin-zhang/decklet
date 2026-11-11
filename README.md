# Decklet

Decklet is for language learners who want to quickly capture and review words
without heavy card setup.

It is built differently from many SRS tools:
- The main workflow needs no card back design. Decklet looks words up by
  opening external apps or services. You can jump out to web resources for
  pronunciation, usage, etymology, images, etc., or connect to a third-party
  API for live definitions. When a personal note helps more than a lookup,
  cards also support an optional card back.
- Decklet is built on Emacs, so it is easy to shape to your own workflow. For
  example, you can customize lookup providers and the lookup behavior, and use
  the built-in hooks for further tweaks.


## Table of Contents

- [UI Preview](#ui-preview)
  - [Review Mode](#review-mode)
  - [Edit Mode](#edit-mode)
- [Get Started](#get-started)
  - [Install](#install)
  - [Quick Start](#quick-start)
  - [Review Mode](#review-mode-1)
  - [Edit Mode](#edit-mode-1)
- [Additional Setup](#additional-setup)
  - [Refocus after Lookup](#refocus-after-lookup)
  - [Hidden Cursor](#hidden-cursor)
- [Features](#features)
  - [Browser Lookup](#browser-lookup)
  - [Hints](#hints)
  - [Tags](#tags)
  - [Card Back](#card-back)
  - [Undo](#undo)
  - [Daily Goal](#daily-goal)
  - [Edit Mode Workflow](#edit-mode-workflow)
  - [Batch Add Buffer](#batch-add-buffer)
  - [Data Location](#data-location)
- [Customization](#customization)
  - [Review Order](#review-order)
    - [Daily Limits](#daily-limits)
  - [Interval Labels](#interval-labels)
  - [Add and Refresh](#add-and-refresh)
  - [Scheduling](#scheduling)
  - [Rollover Time](#rollover-time)
  - [Database](#database)
    - [Backup](#backup)
    - [JSON Export and Import](#json-export-and-import)
  - [Review Log](#review-log)
  - [Hooks](#hooks)
  - [Review UI Components](#review-ui-components)
- [Extensions](#extensions)
- [License](#license)

## UI Preview

### Review Mode

```text
                          REVIEWING
---------------------------------------------------------------
    42 reviewed / 3 review due / 9 learning due / 120 new
---------------------------------------------------------------
                           10.00%
       █████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
---------------------------------------------------------------
[1] Again (10m)   [2] Hard (1h)   [3] Good (1d)   [4] Easy (3d)
---------------------------------------------------------------

                            lucid

---------------------------------------------------------------

                          /ˈluːsɪd/

                             ♦
```

The counter line shows the cards rated so far today, then how many review,
learning and new cards the queue will still hand out today, after any
[daily limits](#daily-limits).

### Edit Mode

```text
Word         Hint                  Back  State      Added            Last Review       Due               Stability Difficulty
----------------------------------------------------------------------------------------------------------------------------
lucid        /ˈluːsɪd/             ♦     review     2025-04-12 09:18 2025-04-20 08:02  2025-05-18 04:00  32.410    3.120
zephyr       /ˈzefər/                    learning   2025-04-03 10:31 2025-04-16 07:54  2025-04-28 04:00  12.220    4.050
candor       /ˈkændər/             ♦     review     2025-04-05 11:07 2025-04-19 21:45  2025-05-10 04:00  28.905    3.480
```

## Get Started

### Install

```emacs-lisp
;; Decklet depends on the FSRS implementation from MELPA.
(use-package fsrs
  :ensure t)

(use-package decklet
  :ensure nil
  :load-path "path/to/the/repo"
  :commands (;; Main workflow
             decklet-add-card
             decklet-add-card-batch
             decklet-review
             decklet-edit
             ;; Backups and JSON transfer
             decklet-db-backup
             decklet-db-restore
             decklet-db-export-json
             decklet-db-import-json)
  :custom
  ;; `decklet-lookup-providers` defaults to nil.
  ;; For English learners, these are some useful choices.
  (decklet-lookup-providers
   '(("Google" . "https://www.google.com/search?q=define:%s")
     ("Merriam-Webster" . "https://www.merriam-webster.com/dictionary/%s")
     ("Oxford Learner's" . "https://www.oxfordlearnersdictionaries.com/definition/english/%s")
     ("Cambridge" . "https://dictionary.cambridge.org/dictionary/english/%s")
     ("Wiktionary" . "https://en.wiktionary.org/wiki/%s")))
  (decklet-lookup-default-provider "Google")
  ;; Default is nil (disabled). When set to a number, review mode shows
  ;; a daily-goal progress bar.
  (decklet-review-daily-goal 100))
```

### Quick Start

1. Add cards:
   - Add a card: `M-x decklet-add-card`
   - Batch add cards: `M-x decklet-add-card-batch` (one word per line)
2. Start reviewing: `M-x decklet-review`
3. Maintain your deck: `M-x decklet-edit`

### Review Mode

Review mode is where you review and rate cards, as in most flashcard apps.

| Key | Action                              |
|-----|-------------------------------------|
| `1` | Rate as Again                       |
| `2` | Rate as Hard                        |
| `3` | Rate as Good                        |
| `4` | Rate as Easy                        |
| `n` | Next card / Confirm undone card     |
| `u` | Undo last rating or skip            |
| `g` | Refresh review buffer               |
| `e` | Edit current word                   |
| `H` | Edit current hint                   |
| `t` | Edit current tags                   |
| `b` | Show or edit card back              |
| `D` | Delete current card                 |
| `q` | Quit review                         |
| `l` | Look up word with default provider  |
| `L` | Look up word with selected provider |

### Edit Mode

Edit mode is for managing cards: filtering, sorting and batch operations. You
can also rate cards here, which suits targeted learning. See
[Edit Mode Workflow](#edit-mode-workflow) for ideas.

| Key   | Action                                    |
|-------|-------------------------------------------|
| `m`   | Mark card at point                        |
| `u`   | Unmark card at point                      |
| `U`   | Clear all marks                           |
| `R`   | Rate current card                         |
| `A`   | Archive/Unarchive current or marked cards |
| `D`   | Delete current or marked cards            |
| `e`   | Edit word at point                        |
| `H`   | Edit hint at point                        |
| `t`   | Edit tags; add/remove tags on marked cards |
| `. t` | Filter by tag; empty input clears filter   |
| `b`   | Show or edit card back                    |
| `. r` | Filter review cards                       |
| `. l` | Filter learning cards                     |
| `. a` | Toggle archived/all cards                 |
| `; w` | Sort by word                              |
| `; a` | Sort by added time                        |
| `; l` | Sort by last review time                  |
| `; d` | Sort by due time                          |
| `; s` | Sort by stability                         |
| `; f` | Sort by difficulty                        |
| `l`   | Look up word with default provider        |
| `L`   | Look up word with selected provider       |
| `g`   | Refresh edit buffer                       |
| `q`   | Quit edit mode                            |

## Additional Setup

### Refocus after Lookup

After a browser lookup, you can bring Emacs back to the front automatically,
so you stay in the review flow. Add a function to `decklet-lookup-hook`,
which runs after the browser opens. On macOS:

```emacs-lisp
(use-package decklet
  :hook
  (decklet-lookup
   . (lambda ()
       (start-process-shell-command
        "decklet-refocus" nil
        "osascript -e 'tell application \"Emacs\" to activate'"))))
```

On other systems, replace the shell command:

| System | Command |
|---|---|
| Linux (X11) | `wmctrl -a "Emacs"` |
| Linux (Wayland, sway) | `swaymsg '[app_id="Emacs"] focus'` |
| Windows (PowerShell) | `powershell -Command "(New-Object -ComObject WScript.Shell).AppActivate('Emacs')"` |

### Hidden Cursor

Review mode hides the cursor and turns off `hl-line-mode`. Set
`decklet-review-hide-cursor` to nil to keep your usual cursor.

Modal editing packages can bring the cursor back:

- With [Evil](https://github.com/emacs-evil/evil), turn off `evil-local-mode`
  in `decklet-review-mode`.
- With [Meow](https://github.com/meow-edit/meow), the cursor may blink the
  first time the review buffer is shown. This buffer-local override stops
  Meow from redrawing it there:

```emacs-lisp
(use-package decklet
  :hook
  (decklet-review-mode . (lambda ()
                             (setq-local meow-update-cursor-functions-alist
                                         '(((lambda () t) . ignore))))))
```

## Features

### Browser Lookup

In Decklet, browser-based lookup takes the place of flipping the card. The
current word is inserted into a website URL template and opened in your
default browser, letting you read meaning, pronunciation, usage, etymology,
images, and related results from whichever sources you prefer.

- `l` opens your default lookup provider in the browser.
- `L` lets you pick a provider, then opens it.
- `M-x decklet-switch-default-provider` changes the default used by `l`.

Providers are set with `decklet-lookup-providers`, an alist of
`(NAME . URL)` where `URL` contains one `%s` for the word, and
`decklet-lookup-default-provider`. Both are nil until you set them; see the
[Install](#install) example.

For definitions or audio inside Emacs, see [Extensions](#extensions).

### Hints

A hint is short context for a word, such as an example sentence, IPA, a
translation or a mnemonic.

In review mode, a card's hint first shows as `[HINT]` and appears after
`decklet-review-hint-delay` seconds, so your first recall attempt focuses on
the word itself. Set the delay to nil to show hints right away.

Press `H` to edit a hint in review mode, in edit mode, or at the prompt right
after adding a word. In the hint prompt, `M-j` inserts a newline.

### Tags

Cards can have multiple tags, such as `botany`, `medicine`, `astronomy`,
or `reading`. Tag names are case-sensitive and cannot contain whitespace or
colons. Tags have no scheduling effect until a
[review-order selector](#review-order) uses them.

- Press `t` in review or edit mode to replace the current card's tags. Enter
  space-separated names with completion; an empty response clears the tags.
- After adding a single card, `H` edits its hint and `t` edits its tags,
  before you answer `y`/Enter to add another card or `n` to finish.
- In edit mode, with marked rows, `t` offers to add or remove tags on all of
  them.
- `. t` filters the edit list by one tag. Empty input clears the filter.
- Batch add accepts `:tag` lines (see [Batch Add Buffer](#batch-add-buffer)).
  Re-adding an existing word merges the new tags into its existing ones.

Tags follow a card across renames and are included in backups and JSON
export.

### Card Back

The card back is an optional free-form note on a card. It stays out of the
review flow until you press `b`, so it suits longer notes such as etymology,
example sentences, mnemonics or grammar patterns.

In review mode, a `♦` below the hint area marks cards that have a back. In
edit mode, the `Back` column shows the same mark.

Press `b` in review or edit mode to open the card back. A new back opens
ready to type, and an existing one opens read-only; press `C-x C-q` to edit
it. Save with `C-x C-s`. If you close the popup with unsaved edits, Decklet
asks whether to save, discard or cancel.

The card back buffer uses `org-mode`. To use another mode:

```emacs-lisp
(setq decklet-card-back-buffer-major-mode 'markdown-mode)
```

### Undo

Press `u` during review to go back to a previously rated or skipped card.
The previous rating is highlighted. Press `1`–`4` to re-rate, or `n` to
keep the original rating and move on. Re-rating also discards any later
reviews of that card in the same session, since they were based on the old
rating.

Edit-mode rating is disabled while a review session is active.

### Daily Goal

Set `decklet-review-daily-goal` to a number to show a progress bar in review
mode. The goal only paces you. You can keep reviewing after reaching it.

The goal is separate from the `daily-limit` in [Review Order](#review-order).
The goal is a number you aim for, and the limit is a number the queue will not
exceed, so limits that add up to less than your goal leave the goal out of
reach.

`decklet-review-daily-goal-reached-hook` runs when you reach the goal, for
example to show a message or play a sound. See [Hooks](#hooks).

### Edit Mode Workflow

Edit mode lets you work outside the normal due queue. A few ideas:

1. **Re-check "well-known" words.** Filter or sort to find mature cards and
   check whether you still know them. If not, press `R` and rate `1` (Again)
   to send the card back to relearning.
2. **Learn selectively from newer cards.** Use `. l` (learning filter), sort
   by `Added`, and rate the cards that interest you with `R`.
3. **Archive long-interval cards.** Sort by `Due` and look at cards scheduled
   far ahead. If a word feels fully learned, archive it with `A`.

To archive, unarchive or delete several cards at once, mark them with `m`,
then press `A` or `D`.

### Batch Add Buffer

`M-x decklet-add-card-batch` opens a buffer for adding many words.
`C-c C-c` imports everything in one go, and `C-c C-k` cancels.

- Each line that does not start with `#` or `:` is a word.
- `#` lines add hint text to the word above.
- `:` lines add `:tag` tokens to the word above. `:botany` is stored as
  `botany`.
- Hint and tag lines can come in any order. Empty lines are ignored.

```text
rose
:botany :flower
# A fragrant garden flower.

lily
# A garden flower with large petals.
:botany :flower
```

### Data Location

- Base directory: `decklet-directory` (defaults to `~/.emacs.d/decklet/`)
- Database file: `decklet-db-file` (defaults to `decklet.sqlite` under the base directory)
- Review log: `decklet-review-log-file` (defaults to `review-log.jsonl` under the base directory)
- Backups: `decklet-backup-directory` (defaults to `backups/` under the base directory)

To move everything, set `decklet-directory` before the package loads, for
example under `:custom`:

```emacs-lisp
(use-package decklet
  :custom
  (decklet-directory "~/.config/decklet"))
```

## Customization

### Review Order

`decklet-review-order` decides which cards review mode offers and in what
order. Each entry is a step `(SOURCE SPEC)`. The source picks cards by state
(`learning`, `relearning`, `review`, `new`) and optionally by tag, and the
spec sorts, shuffles, limits or spreads them.

```emacs-lisp
;; Default: short learning steps first, then reviews, then newest-added words.
(setq decklet-review-order
      '(((learning relearning) (sort :due :asc))
        (review shuffle)
        (new (sort :added :desc))))

;; Steady general intake: at most 120 reviews and 10 new cards per day.
(setq decklet-review-order
      '(((learning relearning) (sort :due :asc))
        (review (daily-limit 120 shuffle))
        (new (spread (daily-limit 10 (sort :added :desc))))))

;; Bulk-import topic vocabulary, but introduce only a few words each day.
(setq decklet-review-order
      '(((learning relearning) (sort :due :asc))
        (review shuffle)
        (new (spread (daily-limit 10 (sort :added :desc))))
        ((new :tags "botany")
         (spread (daily-limit 2 shuffle)))
        ((new :tags "medicine")
         (spread (daily-limit 1 shuffle)))
        ((new :tags "astronomy")
         (spread (daily-limit 1 shuffle)))))
```

The last example offers at most 14 new cards per day: 10 ordinary, 2 botany,
1 medicine and 1 astronomy. A tag step owns all of its matching cards, so
importing 300 botany words still brings in only 2 a day. The plain `new`
step gets the new cards that no tag step claims. When a card matches several
tag steps, the first one owns it.

Steps place their cards in the order you write them. `spread` mixes a step's
cards evenly into the cards gathered by the steps before it, and plain steps
append.

Sources and selectors:

```emacs-lisp
new                                         ; all otherwise-unclaimed new cards
(learning relearning)                       ; shared step for two states
(new :tags "botany")                        ; one tag
(new :tags (or "botany" "flower"))           ; either tag
(new :tags (and "medicine" "suffix"))        ; both tags
(new :tags (not "paused"))                   ; lacks this tag
(learning :tags "botany")                    ; selectors work on every state
((learning relearning) :tags "botany")       ; combined states with a selector
```

Sort with `(sort FIELD ORDER)`, where `ORDER` is `:asc` or `:desc`. Every
source supports `:due` and `:added`, and review-only sources also support
`:last-review`, `:difficulty` and `:stability`.

The full grammar and the exact ownership rules are in
[Writing Extensions](docs/writing-extensions.md#review-order-reference).

#### Daily Limits

`(daily-limit N BASE)` caps a step at `N` cards per review day. Ratings count
toward the limit, while opening or skipping a card does not. Restarting Emacs
does not reset it, and unused allowance does not carry over. `N = 0` pauses
the step.

Use limits mainly for `new` and, if you like, `review`. A limit on `learning`
or `relearning` also holds back short-interval repeats once it is reached.

When a limit holds cards back, an empty queue tells you the daily limit is
reached.

### Interval Labels

By default, review mode shows projected FSRS intervals next to rating options,
for example `Again (10m)` and `Good (1d)`. To hide them:

```emacs-lisp
(setq decklet-review-enable-interval-labels nil)
```

### Add and Refresh

When you add a word that already exists but has never been reviewed, Decklet
resets its added date and due time to now, so it counts as newly added. This
brings a stale new card forward, which helps most when new cards are sorted
newest first, as in `(new (sort :added :desc))`. To turn it off:

```emacs-lisp
(setq decklet-add-and-refresh nil)
```

### Scheduling

Decklet schedules cards with FSRS. These options change how often you see a
card:

| Variable | Default | Meaning |
|---|---|---|
| `decklet-desired-retention` | `0.9` | Target probability of recall at review time. Higher means shorter intervals and more reviews; lower means longer intervals and more forgetting. |
| `decklet-learning-steps` | `((10 :minute) (1 :day))` | Short steps a new card walks through before graduating to review. Set to nil to skip the learning stage. |
| `decklet-relearning-steps` | `((10 :minute))` | Steps a lapsed card walks through before returning to review. Set to nil to disable. |
| `decklet-fsrs-parameters` | `nil` | Override for the FSRS weight vector (21 floats). Nil uses the FSRS library defaults. |

Each step is `(AMOUNT UNIT)`, where `UNIT` is `:sec`, `:minute`, `:hour`, or
`:day`. Change these with `setopt` or `:custom`, which rebuild the scheduler.
Plain `setq` after load does not.

```emacs-lisp
;; Aim a little lower than the default to cut daily review load.
(setopt decklet-desired-retention 0.85)

;; A gentler three-step learning ramp.
(setopt decklet-learning-steps '((5 :minute) (30 :minute) (1 :day)))
```

`decklet-fsrs-parameters` is usually filled in by an FSRS tuner trained on
your [review log](#review-log), such as `decklet-fsrs-tuner` in
[Extensions](#extensions).

### Rollover Time

A review day starts at the rollover hour (default 4am). Cards due before the
rollover count toward today.

```emacs-lisp
;; Start a new review day at 2am.
(setq decklet-day-rollover-hour 2)
```

### Database

Decklet keeps all card data in one SQLite file (`decklet-db-file`).
`M-x decklet-open-db-file` opens it in `sqlite-mode`. The connection opens
when needed and closes when you quit the last review or edit buffer.
`M-x decklet-disconnect` closes it by hand.

#### Backup

- Decklet backs up when a review or edit session starts and quits, and only
  when the database has changed. Set `decklet-backup-automatic` to nil to
  back up only by hand.
- Each backup holds the database and the review log, so a restore brings back
  both together.
- Decklet keeps the newest `decklet-backup-prune-max-count` backups (default
  20) and deletes older ones. Set it to nil to keep all of them.

`M-x decklet-db-backup` makes a backup now, and `M-x decklet-db-restore`
restores one you pick from a list, newest first.

#### JSON Export and Import

`M-x decklet-db-export-json` writes the deck to a JSON file for backup,
inspection, migration or analysis. `M-x decklet-db-import-json` reads the same
format, which is useful for moving FSRS data in from another tool.

```json
[
  {
    "word": "lucid",
    "added_date": "2025-04-12T09:18:00-07:00",
    "last_review": "2025-04-20T08:02:00-07:00",
    "due": "2025-05-18T04:00:00-07:00",
    "archived_at": null,
    "state": "review",
    "step": 0,
    "stability": 32.41,
    "difficulty": 3.12,
    "hint": "/ˈluːsɪd/",
    "tags": ["reading"],
    "back": "From Latin *lucidus* (light, bright). Think: a lucid dream is one where the light of awareness shines through."
  }
]
```

When a word already exists, the import asks whether to overwrite or skip it.
How each field behaves on overwrite is described in
[Writing Extensions](docs/writing-extensions.md#json-import-fields).

### Review Log

Besides the database, Decklet keeps a log of every rating in
`decklet-review-log-file` (`review-log.jsonl` under `decklet-directory`). The
database holds each card's current state, and the log holds how it got there.
An FSRS tuner can fit parameters to your memory from this history. The log is
included in every backup. Its format is described in
[Writing Extensions](docs/writing-extensions.md#review-log).

### Hooks

Decklet runs these hooks:

- `decklet-review-start-hook`: runs when a review session starts.
- `decklet-review-quit-hook`: runs when review mode exits.
- `decklet-review-next-card-hook`: runs after moving to the next card.
- `decklet-review-daily-goal-reached-hook`: runs when a rating completes the daily goal.
- `decklet-edit-start-hook`: runs when the edit buffer opens.
- `decklet-edit-quit-hook`: runs when the edit buffer exits.
- `decklet-lookup-hook`: runs after browser lookup opens.

For example, to add sound effects to review:

```emacs-lisp
(defun my/decklet-play-sound (path)
  (start-process "decklet-sound" nil "afplay" (expand-file-name path)))

(use-package decklet
  :hook
  (decklet-review-next-card . (lambda () (my/decklet-play-sound "~/.emacs.d/custom/decklet-next-word.mp3")))
  (decklet-review-daily-goal-reached . (lambda () (my/decklet-play-sound "~/.emacs.d/custom/decklet-goal-reached.mp3")))
  (decklet-lookup . (lambda () (my/decklet-play-sound "~/.emacs.d/custom/decklet-lookup-word.mp3"))))
```

Hooks for card events (added, deleted, renamed, rated) are described in
[Writing Extensions](docs/writing-extensions.md#lifecycle-hooks).

### Review UI Components

The review screen is built from component functions in two lists.
`decklet-review-fixed-components` holds the main centered block (title,
counters, options, word), and `decklet-review-floating-components` holds what
sits below it (the hint and the card back mark).
`decklet-review-fill-column` sets the text width.

To hide the counters:

```emacs-lisp
(setq decklet-review-fixed-components
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
```

To change the text width:

```emacs-lisp
(setq decklet-review-fill-column 56)
```

## Extensions

Optional features live in the separate
[`decklet-extensions`](https://github.com/yilin-zhang/decklet-extensions)
repo, each as its own package. Among them:

- `decklet-calendar`: shows upcoming due counts on the Emacs calendar.
- `decklet-import`: imports saved words from a Kindle or Kobo.
- `decklet-sound`, `decklet-tts-edge`, `decklet-tts-kokoro`: pronunciation
  audio.
- `decklet-images`: an image per card.
- `decklet-stats`: per-word review history and a review heatmap.
- `decklet-fsrs-tuner`: tunes FSRS parameters from your review log.

To write your own, see [Writing Extensions](docs/writing-extensions.md).

## License

GNU General Public License v3.0. See [LICENSE](./LICENSE) for details.

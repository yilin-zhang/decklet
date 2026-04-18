# Decklet 🃏

Decklet is for language learners who want to quickly capture and review words
without heavy card setup.

It is built differently from many SRS tools:
- The primary workflow does not require designing a card back. Instead, Decklet
  provides a flexible lookup approach by opening external apps or services.
  You can jump out to web resources for pronunciation, usage, etymology, images,
  etc., or connect to a third-party API for live definitions. For cases
  where a personal note is more useful than an external lookup, cards also
  support an optional card back.
- Decklet is built on Emacs, so it is easy to shape to your own workflow. For
  example, you can customize lookup providers and the lookup behavior, and fully
  utilize the built-in hooks for further tweaks.


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
  - [Card Back](#card-back)
  - [Undo](#undo)
  - [Daily Goal](#daily-goal)
  - [Edit Mode Workflow](#edit-mode-workflow)
  - [Calendar Mode](#calendar-mode)
  - [Import from e-reader](#import-from-e-reader)
  - [Data Location](#data-location)
- [Customization](#customization)
  - [Review Order](#review-order)
  - [Interval Labels](#interval-labels)
  - [Add and Refresh](#add-and-refresh)
  - [Rollover Time](#rollover-time)
  - [Database](#database)
  - [Hooks](#hooks)
  - [Review UI Components](#review-ui-components)
- [Writing Extensions](#writing-extensions)
- [Testing and CI](#testing-and-ci)
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

                           [BACK]
```

### Edit Mode

```text
Word         Hint                  Back  State      Added            Last Review       Due               Stability Difficulty
----------------------------------------------------------------------------------------------------------------------------
lucid        /ˈluːsɪd/             *     review     2025-04-12 09:18 2025-04-20 08:02  2025-05-18 04:00  32.410    3.120
zephyr       /ˈzefər/                    learning   2025-04-03 10:31 2025-04-16 07:54  2025-04-28 04:00  12.220    4.050
candor       /ˈkændər/             *     review     2025-04-05 11:07 2025-04-19 21:45  2025-05-10 04:00  28.905    3.480
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
             decklet-db-import-json
             ;; Import from e-book (optional)
             decklet-import-kindle
             decklet-import-kobo)
  :hook
  ;; If you would like to turn the calendar into a review load heatmap:
  (calendar-load . decklet-calendar-mode)
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

Review mode is the main mode for card review, where you can review and rate
cards just like most flashcard apps.

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
| `t` | Edit current hint                   |
| `b` | Show or edit card back              |
| `D` | Delete current card                 |
| `q` | Quit review                         |
| `l` | Look up word with default provider  |
| `L` | Look up word with selected provider |
| `f` | Show definition popup               |
| `s` | Play pronunciation audio            |

### Edit Mode

Edit mode is the alternative mode for card management, filtering, sorting, and
batch operations. Like review mode, you can also review and rate cards in edit
mode, which makes it perfect for targeted learning.

See [Edit Mode Workflow](#edit-mode-workflow) for more information.

| Key   | Action                                    |
|-------|-------------------------------------------|
| `m`   | Mark card at point                        |
| `u`   | Unmark card at point                      |
| `U`   | Clear all marks                           |
| `R`   | Rate current card                         |
| `A`   | Archive/Unarchive current or marked cards |
| `D`   | Delete current or marked cards            |
| `e`   | Edit word at point                        |
| `t`   | Edit hint at point                        |
| `b`   | Show or edit card back                    |
| `+`   | Quick add card                            |
| `/ r` | Filter review cards                       |
| `/ l` | Filter learning cards                     |
| `/ a` | Toggle archived/all cards                 |
| `; w` | Sort by word                              |
| `; a` | Sort by added time                        |
| `; l` | Sort by last review time                  |
| `; d` | Sort by due time                          |
| `; s` | Sort by stability                         |
| `; f` | Sort by difficulty                        |
| `l`   | Look up word with default provider        |
| `L`   | Look up word with selected provider       |
| `f`   | Show definition popup                     |
| `s`   | Play pronunciation audio                  |

## Additional Setup

### Refocus after Lookup

It is recommended to focus back to Emacs after browser lookup with a CLI
command. This helps you return to the review flow without manually switching
focus. You can achieve this by adding a hook function to
`decklet-lookup-hook`, which runs after opening up the browser.

macOS example:

```emacs-lisp
(use-package decklet
  :hook
  (decklet-lookup
   . (lambda ()
       (start-process-shell-command
        "decklet-refocus" nil
        "osascript -e 'tell application \"Emacs\" to activate'"))))
```

Linux (X11) example:

```emacs-lisp
(use-package decklet
  :hook
  (decklet-lookup
   . (lambda ()
       (start-process-shell-command
        "decklet-refocus" nil
        "wmctrl -a \"Emacs\""))))
```

Linux (Wayland, sway) example:

```emacs-lisp
(use-package decklet
  :hook
  (decklet-lookup
   . (lambda ()
       (start-process-shell-command
        "decklet-refocus" nil
        "swaymsg '[app_id=\"Emacs\"] focus'"))))
```

Windows (PowerShell) example:

```emacs-lisp
(use-package decklet
  :hook
  (decklet-lookup
   . (lambda ()
       (start-process-shell-command
        "decklet-refocus" nil
        "powershell -Command \"(New-Object -ComObject WScript.Shell).AppActivate('Emacs')\""))))
```

### Hidden Cursor

In `decklet-review-mode`, the cursor is invisible and `hl-line-mode` is
disabled by default. If you prefer Decklet not to override the default cursor
and highlight-line behaviors, set `decklet-review-hide-cursor` to nil.

Modal editing plugins typically don't play well with the default cursor hiding
behavior. You may need an additional setup to make it work.

If you use [Evil](https://github.com/emacs-evil/evil), you may need to turn off
`evil-local-mode` inside `decklet-review-mode`, otherwise Evil keeps refreshing
the cursor and the hidden-cursor effect will not hold. This is a practical
workaround rather than an officially tested configuration.

If you use [Meow](https://github.com/meow-edit/meow), the cursor may blink the
first time the review buffer is shown, until the next buffer refresh. It is
because its global `window-state-change-functions` hook updates the cursor
whenever the selected window changes, and its default cursor update logic treats
a nil cursor as a signal to restore the default box cursor.

You can use this buffer-local override so Meow keeps working elsewhere but stops
overriding the review buffer's hidden cursor:

```emacs-lisp
(with-eval-after-load 'meow
  (add-hook 'decklet-review-mode-hook
            (lambda ()
              (setq-local meow-update-cursor-functions-alist
                          '(((lambda () t) . ignore))))))
```

Or with `use-package`:

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

In-Emacs definition popups and audio playback are intentionally out of
scope for the core package — they are trivially built on top of the public
API and hooks (see [Writing Extensions](#writing-extensions)).

#### Lookup Providers

`decklet-lookup-providers` and `decklet-lookup-default-provider` are `nil`
by default. If you press `l`/`L` before setting providers, Decklet will
show a message asking you to configure them.

- `decklet-lookup-providers`: alist of `(NAME . URL)`. `URL` must include
  one `%s` placeholder for the word.
- `decklet-lookup-default-provider`: provider name used by `decklet-lookup`.

Example:

```emacs-lisp
(setq decklet-lookup-providers
      '(("Google" . "https://www.google.com/search?q=define:%s")
        ("Merriam-Webster" . "https://www.merriam-webster.com/dictionary/%s")
        ("Oxford Learner's" . "https://www.oxfordlearnersdictionaries.com/definition/english/%s")
        ("Cambridge" . "https://dictionary.cambridge.org/dictionary/english/%s")
        ("Wiktionary" . "https://en.wiktionary.org/wiki/%s")))
(setq decklet-lookup-default-provider "Google")
```

### Hints

Hints allow you to add useful context around a word (example sentence, IPA,
translation, mnemonic, synonyms, collocations, etc.), so you can remember the
word in real usage instead of memorizing it in isolation.

In review mode, if a card has a hint, Decklet first shows a `[HINT]`
placeholder, then reveals the hint after `decklet-review-hint-delay`. The
delay is intentional: it reduces the chance of identifying the word from
surrounding context too early, so your first recall attempt still focuses on the
word itself.

If this behavior is not what you want, you can set `decklet-review-hint-delay`
to nil to disable it.

`t` is the universal key for hint editing:
- You can edit hints with `t` in both review mode and edit mode.
- During add flow, after adding a new word, you can press `t` at the follow-up
  prompt.

Note: In minibuffer hint input, you can use `M-j` to insert a newline for
multi-line hints.

### Card Back

Card back is an optional free-form note attached to a card. Unlike hints, which
are shown inline during review after a short delay, the card back is kept out of
the review flow and accessed on demand with `b`. This makes it a good place for
longer or richer notes — etymology, example sentences, mnemonics, grammar
patterns, or anything you want to record but do not want shown automatically
during every review.

In review mode, if a card has a back, a `[BACK]` indicator appears below the
hint area as a reminder that extra content is available.

In edit mode, the `Back` column shows `*` for cards that have a back.

Key bindings (available in both review and edit modes):

- `b`: open the card back popup. If the card already has a back, the buffer
  is read-only — press `q` to close. If the card has no back yet, the buffer
  is editable — type the content and save with `C-x C-s`.

  To modify an existing card back, open it with `b` and toggle the buffer
  editable with `M-x read-only-mode` (or `C-x C-q`), edit as usual, and save
  with `C-x C-s`.

The card back buffer uses `org-mode` by default. You can change the major mode
with `decklet-card-back-buffer-major-mode`:

```emacs-lisp
;; Use Markdown mode for card backs (requires markdown-mode to be installed).
(setq decklet-card-back-buffer-major-mode 'markdown-mode)
```

### Undo

Press `u` during review to go back to a previously rated or skipped card.
The previous rating is highlighted. Press `1`–`4` to re-rate, or `n` to
keep the original rating and move on.

Edit-mode rating is disabled while a review session is active.

### Daily Goal

When `decklet-review-daily-goal` is set to an integer number, review mode
shows a progress bar with current progress percentage. This is useful if you
want a stable daily target instead of reviewing indefinitely or being
under-motivated.

Note that it is only a pacing indicator. Decklet does not enforce a hard
cap. You can continue reviewing and learning new cards after the goal is
reached.

You can also do some automation around this signal through hooks. For example,
`decklet-review-daily-goal-reached-hook` can trigger a check-in message,
play a sound, or run your own logging function for habit tracking.
See [Hooks](#hooks) below.

### Edit Mode Workflow

Edit mode is useful when you want to work outside the normal due queue.

Decklet does not dictate how you should use edit mode, but here are a few
workflow ideas:

1. Re-check "well-known" words: Use filters/sorting to find cards that look
   mature, then quickly verify whether you still recognize them. If not, rate
   with `R` and choose `1` (Again) to push the card back into relearning queue.
2. Learn selectively from newer cards: Use `/ l` (learning filter), then sort by
   `Added` to focus on recently added words. Now you can use `R` to selectively
   rate cards that interest you.
3. Archive long-interval cards: Sort by `Due` and inspect cards scheduled far in
   the future. If a word feels fully internalized, archive it with `A` to keep
   the active deck cleaner.

For batch archive/unarchive, mark multiple cards with `m`, then press `A` once
to apply the action to all marked rows.

Same thing applies to card deletion. Press `D` to delete the current card at
point or mark multiple cards with `m` then press `D` to delete all marked cards.

### Calendar Mode

When `decklet-calendar-mode` is enabled, your calendar becomes a heatmap of
upcoming review load.

- Dates with due cards are highlighted automatically.
- Highlight intensity is based on due count thresholds
  (`decklet-calendar-thresholds`).
- Due counts are computed with your rollover setting
  (`decklet-day-rollover-hour`), so "today" follows your review-day boundary.
- Moving across dates in Calendar shows the due-card count for the selected day.

To avoid conflict with your current settings, it's an opt-in feature. See
[Install](#install) on how to set it up.

### Import from e-reader

Decklet import buffers support both plain word lines and hint lines. During
confirmation (`C-c C-c`), Decklet parses the buffer into cards and hints.

In batch/import buffers, each non-empty non-`#` line starts a new word block.
Lines starting with `#` are treated as hint lines and attached to the most
recent word.

Rules:

- Empty lines and whitespace-only lines are ignored.
- One word line can have multiple `#` hint lines.
- Hint lines are joined with newlines.

Example:

```text
lucid
# She gave a *lucid* explanation of the model.
# /ˈluːsɪd/
zephyr
# A warm *zephyr* drifted through the room.
# /ˈzefər/
```

If you use Kindle Vocabulary Builder:

1. Copy `vocab.db` from your Kindle device to your computer.
2. Run `M-x decklet-import-kindle` and select that `vocab.db` file.
3. Review and edit the imported words in the temporary buffer, then confirm with
   `C-c C-c`.
4. When prompted, optionally clear the Kindle `vocab.db` to avoid re-importing
   the same words next time.
5. Copy the updated `vocab.db` back to your Kindle if you chose to clear it.

By default, Decklet also imports Kindle usage sentences as hint lines. If you
want to disable that behavior, set `decklet-import-kindle-usage` to nil.

If you use Kobo:

1. Copy `KoboReader.sqlite` from your Kobo device to your computer.
2. Run `M-x decklet-import-kobo` and select that `KoboReader.sqlite` file.
3. Review and edit the imported words in the temporary buffer, then confirm with
   `C-c C-c`.
4. When prompted, optionally clear the `WordList` rows to avoid re-importing
   the same words next time.
5. Copy the updated `KoboReader.sqlite` back to your device if you chose to
   clear it.

You can also operate directly on the on-device database file. However, clearing
imported words is irreversible, so proceed at your own risk.

### Data Location

- Base directory: `decklet-directory` (defaults to `~/.emacs.d/decklet/`)
- Database file: `decklet-db-file` (defaults to `decklet.sqlite` under the base directory)
- Backups: `decklet-backup-directory` (defaults to `backups/` under the base directory)

If you want to change `decklet-directory` and all the paths derived from it,
you should set this variable before the package is loaded. If you use
`use-package`, you can either place it under `:init`, or preferably under `:custom`.

```emacs-lisp
(use-package decklet
  :custom
  (decklet-directory "~/.config/decklet"))
```

## Customization

### Review Order

`decklet-review-order` lets you control the queue shape. For example: finish
learning cards first, mix learning and review together, or prioritize difficult
review cards.

Examples:

```emacs-lisp
;; Default review order
;; 1) finish due learning/relearning cards first (earliest due first)
;; 2) then review cards in random order
;; 3) finally show new cards, newest first
(setq decklet-review-order
      '((:sort :due :asc :learning)
        (:shuffle :review)
        (:sort :added :desc :new)))

;; Mix learning + review together, then shuffle them.
(setq decklet-review-order
      '((:shuffle (:learning :review))
        (:sort :added :desc :new)))

;; Focus on tough review cards first.
(setq decklet-review-order
      '((:sort :difficulty :desc :review)
        (:sort :due :asc :learning)
        (:sort :added :desc :new)))
```

Syntax:
- `(:shuffle TARGETS)`: Shuffle cards from the selected target groups.
- `(:sort FIELD ORDER TARGETS)`: Sort cards from target groups by one field and order.

Fields:
- `:due`: Sort by next due time.
- `:added`: Sort by card creation time.
- `:last-review`: Sort by the last review timestamp.
- `:difficulty`: Sort by FSRS difficulty value.
- `:stability`: Sort by FSRS stability value.

Orders:
- `:asc`: Smallest/earliest value first.
- `:desc`: Largest/latest value first.

Targets:
- `:learning`: Cards in learning or relearning.
- `:review`: Cards in normal review state.
- `:new`: Cards not reviewed yet.

### Interval Labels

By default, review mode shows projected FSRS intervals next to rating options,
for example `Again (10m)` and `Good (1d)`.

You can disable these labels if you find them distracting or prefer a cleaner UI.

```emacs-lisp
(setq decklet-review-enable-interval-labels nil)
```

### Add and Refresh

`decklet-add-and-refresh` controls what happens when you add a word that
already exists but is still new (unreviewed).

- When non-nil (default), re-adding that word refreshes its `added-date` and
  `due` to now, so it is treated as newly added again.
- When nil, re-adding an existing new word does not refresh timestamps.

```emacs-lisp
;; Disable timestamp refresh when re-adding existing new words.
(setq decklet-add-and-refresh nil)
```

This feature is mainly for bringing stale new cards forward. It is most useful
when new cards are sorted by added time in descending order (e.g. `'(:sort
:added :desc :new)`).

For example, you might import a large chunk of words, then revisit one of them a
few months later. Refreshing that card helps surface it sooner so you can review
it while the context is still fresh.

### Rollover Time

Daily pacing uses a rollover time (default 4am). Cards due before the rollover
count toward today.

```emacs-lisp
;; Start a new review day at 2am.
(setq decklet-day-rollover-hour 2)
```

### Database

Decklet stores all card data in a single SQLite file
(`decklet-db-file`). You can use `decklet-open-db-file`, which uses
`sqlite-mode-open-file` internally, to open the SQLite file.

#### Backup

Backup behavior:

- Backups are automatically triggered on review/edit session start and quit.
- A backup is only created when the DB file has changed since the latest
  snapshot.
- Backup files are timestamped and stored in `decklet-backup-directory`.
- Old backups are pruned by retention/count rules.

Prune settings:

- `decklet-backup-retain-days`: keep backups newer than this many days.
- `decklet-backup-prune-min-count`: start pruning only after this minimum
  number of backups is reached.
- `decklet-backup-prune-max-count`: optional hard cap on backup count.
- `decklet-backup-prune-confirm`: whether to ask before pruning.

You can also manually back up or restore to a previous snapshot:

- `decklet-db-backup`: create a backup snapshot.
- `decklet-db-restore`: restore from a selected backup snapshot.

#### JSON Export and Import

`decklet-db-export-json` allows you to export the database to a JSON file for
backup, inspection, migration, or external analysis.

JSON item format:

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
    "back": "From Latin *lucidus* (light, bright). Think: a lucid dream is one where the light of awareness shines through."
  }
]
```

`decklet-db-import-json` is useful when you want to migrate FSRS metadata from
another tool or from a transformed export file. The importer reads the same
schema used by the export function, as shown above.

### Hooks

Decklet provides several session hooks for customization:

- `decklet-review-start-hook`: runs when a review session starts.
- `decklet-review-quit-hook`: runs when review mode exits.
- `decklet-review-next-card-hook`: runs after moving to the next card.
- `decklet-review-daily-goal-reached-hook`: runs when a rating completes the daily goal.
- `decklet-edit-start-hook`: runs when the edit buffer opens.
- `decklet-edit-quit-hook`: runs when the edit buffer exits.
- `decklet-lookup-hook`: runs after browser lookup opens.

For card-level lifecycle events (added/deleted/renamed/rated/etc.), see
[Writing Extensions](#writing-extensions).

Gamification with sound effects is a good example of hook usage. Here's an example:

```emacs-lisp
(defun my/decklet-play-sound (path)
  (start-process "decklet-sound" nil "afplay" (expand-file-name path)))

(use-package decklet
  :hook
  (decklet-review-next-card . (lambda () (my/decklet-play-sound "~/.emacs.d/custom/decklet-next-word.mp3")))
  (decklet-review-daily-goal-reached . (lambda () (my/decklet-play-sound "~/.emacs.d/custom/decklet-goal-reached.mp3")))
  (decklet-lookup . (lambda () (my/decklet-play-sound "~/.emacs.d/custom/decklet-lookup-word.mp3"))))
```

### Review UI Components

Review mode UI is assembled from component functions.

- `decklet-review-fixed-components`: components in the main centered block
  (title, counters, options, word, separators, etc.).
- `decklet-review-floating-components`: components appended below the fixed
  block (default: hint area followed by the card back indicator).

In short:
- Fixed components form the main review layout and are always rendered.
- Floating components sit below the fixed block and can update independently
  (for example, the hint area after the hint delay). The built-in
  `decklet-review-component-card-back-indicator` shows `[BACK]` when the
  current card has a card back.

`decklet-review-fill-column` controls the max text width used by review UI
rendering. If your window is very wide or very narrow, adjusting this can make
the layout look better.

Each component is a function that takes no arguments and returns a string. You
can write your own and add it to either list. Use `decklet-center-text` or
`decklet-fill-and-center-text` to center the output.

Example: remove the counter component from the fixed layout.

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

Example: customize text width.

```emacs-lisp
(setq decklet-review-fill-column 56)
```

## Writing Extensions

Decklet exposes a small public API and a set of card lifecycle hooks so
you can build sidecar packages (audio, images, definitions, annotations,
analytics, ...) without touching Decklet internals.

### Public API

#### Reading cards

| Function | Returns |
|---|---|
| `(decklet-card-exists-p CARD-ID)` | non-nil if `CARD-ID` is in the deck |
| `(decklet-get-card CARD-ID)` | plist `(:card-id :word :hint :back :meta)` or nil |
| `(decklet-get-card-hint CARD-ID)` | hint string or nil |
| `(decklet-get-card-back CARD-ID)` | card back content or nil |
| `(decklet-get-card-meta CARD-ID)` | `decklet-card-meta` struct or nil |
| `(decklet-card-word-by-id CARD-ID)` | current word string or nil |
| `(decklet-card-id-for-word WORD)` | card id or nil |
| `(decklet-list-words &optional FILTER)` | list of words; FILTER is `all`, `review`, `learning`, or `archived` |

#### Mutating cards

| Function | Effect |
|---|---|
| `(decklet-set-card-hint CARD-ID HINT)` | update hint; fires field-updated hook |
| `(decklet-set-card-back CARD-ID CONTENT)` | update card back; fires field-updated hook |
| `(decklet-rename-card CARD-ID NEW-WORD)` | rename a card's word; fires renamed hook |
| `(decklet-delete-card CARD-ID)` | delete a card; fires deleted hook |
| `(decklet-archive-card CARD-ID)` / `(decklet-unarchive-card CARD-ID)` | fire archived/unarchived hooks |
| `(decklet-rate-card CARD-ID GRADE &optional PRIOR-GRADE)` | grade a card; fires rated hook |

#### Context helpers

- `decklet-current-card-id` — the card id currently displayed in review
  (nil outside review).
- `(decklet-prompt-word &optional PROMPT)` — resolve the word from an
  active region, the current review word, the word on the current edit
  line, or the minibuffer.

### Lifecycle hooks

All card lifecycle hooks are abnormal hooks that take a single
argument: a non-empty list of per-card event plists.  Bulk operations
(imports, batch add) fire the hook once with all events; single-card
operations fire it once with a one-element list.  Every event plist
carries `:card-id`; richer events carry the extra keys shown below.

| Hook | Per-event plist keys | Fires when |
|---|---|---|
| `decklet-cards-added-functions` | `:card-id` | a new card is stored (including imports) |
| `decklet-cards-deleted-functions` | `:card-id`, `:card` (pre-delete plist snapshot) | a card is removed from the deck |
| `decklet-cards-renamed-functions` | `:card-id`, `:old-word`, `:new-word` | a card's word key changes |
| `decklet-cards-archived-functions` | `:card-id` | a card is archived |
| `decklet-cards-unarchived-functions` | `:card-id` | a card is unarchived |
| `decklet-cards-field-updated-functions` | `:card-id`, `:field` (`hint`, `back`, or an extension-defined symbol such as `image`) | hint/back changes, or extension-owned sidecar changes |
| `decklet-cards-rated-functions` | `:card-id`, `:old-meta`, `:grade`, `:new-meta`, `:prior-grade` | a card is rated in review or edit mode |

Consumers iterate over the events:

```emacs-lisp
(defun my/on-cards-deleted (events)
  (dolist (event events)
    (let ((word (plist-get (plist-get event :card) :word)))
      ...)))

(add-hook 'decklet-cards-deleted-functions #'my/on-cards-deleted)
```

#### About the rated hook

The `decklet-cards-rated-functions` hook fires for every completed
grading action, in both review and edit modes.

- `:prior-grade` is nil for fresh ratings.
- When the user undoes a rating and re-rates with a different grade
  within the same session, `:prior-grade` is the grade being replaced.
  Extensions that track per-grade statistics should decrement the
  prior-grade counter to compensate for the original event.
- Undo alone does not fire this hook (no DB change).
- Confirming an undone rating (`n` on an undone card) does not fire
  the hook either — the original event already reflects the final state.

### Example: per-word image sidecar

A complete example of a sidecar that stores a PNG per word in a folder,
keeps it in sync with the deck, and shows an `[IMG]` indicator in the
review UI:

```emacs-lisp
(defvar my/decklet-image-dir "~/decklet-images/"
  "Directory where per-word PNG files live.")

(defun my/decklet-image-path (word)
  (expand-file-name (concat word ".png") my/decklet-image-dir))

(defun my/decklet-image-delete (events)
  (dolist (event events)
    (let ((path (my/decklet-image-path
                 (plist-get (plist-get event :card) :word))))
      (when (file-exists-p path) (delete-file path)))))

(defun my/decklet-image-rename (events)
  (dolist (event events)
    (let ((old (my/decklet-image-path (plist-get event :old-word)))
          (new (my/decklet-image-path (plist-get event :new-word))))
      (when (file-exists-p old)
        (rename-file old new t)))))

(defun my/decklet-image-indicator ()
  "Review UI component showing [IMG] when the current word has an image."
  (when-let ((word (and decklet-current-card-id
                        (decklet-card-word-by-id decklet-current-card-id))))
    (when (file-exists-p (my/decklet-image-path word))
      (decklet-center-text
       (propertize "[IMG]" 'face 'decklet-review-card-back-indicator-face)))))

(add-hook 'decklet-cards-deleted-functions #'my/decklet-image-delete)
(add-hook 'decklet-cards-renamed-functions #'my/decklet-image-rename)
(add-to-list 'decklet-review-floating-components #'my/decklet-image-indicator)
```

No drift patrol needed: the sidecar is kept in sync automatically
because the core broadcasts the events. Calls to `decklet-set-card-*`
from extensions also trigger review/edit UI refreshes via the
field-updated hook, so you don't need to manage refresh yourself.

## Testing and CI

Decklet keeps local checks and CI aligned through one entrypoint:

- Run everything locally: `./scripts/check-all.sh`

This script runs checks in order:

1. Parentheses check
2. Indentation check
3. Byte-compile
4. Remove generated `.elc`
5. Checkdoc
6. Package lint
7. ERT tests

Individual scripts are available under `scripts/`:

- `./scripts/check-checkdoc.sh`
- `./scripts/check-package-lint.sh`
- `./scripts/check-ert.sh`

Dependency notes for checks:

- `check-deps.sh` resolves `fsrs.el` for test/compile checks (local file first,
  then cache/download as needed, pinned to a fixed commit).
- `check-package-lint.sh` fetches `package-lint` source at run time, pinned to
  a fixed commit.

CI runs the same command (`./scripts/check-all.sh`) in GitHub Actions.

## License

GNU General Public License v3.0. See [LICENSE](./LICENSE) for details.

# DeckLite 🃏

DeckLite is for language learners who want to quickly capture and review words
without heavy card setup.

It is built differently from many SRS tools:
- There is no need to design a full card back. Instead, DeckLite provides a
  flexible lookup approach by leveraging external apps or services. You can jump
  out to web resources for pronunciation, usage, etymology, images, etc., or
  connect to a third-party API for on-the-fly retrieval.
- DeckLite is built on Emacs, so it is easy to shape to your own workflow. For
  example, you can customize lookup providers and the define behavior, and fully
  utilize the built-in hooks for further tweaks.

DeckLite intentionally stays focused and provides a curated feature set. See
[Project Scope](#project-scope) for details.

## Table of Contents

- [UI Preview](#ui-preview)
  - [Review Mode](#review-mode)
  - [Edit Mode](#edit-mode)
- [Get Started](#get-started)
  - [Install](#install)
  - [Quick Start](#quick-start)
  - [Review Mode](#review-mode-1)
  - [Edit Mode](#edit-mode-1)
- [Features](#features)
  - [Dictionary](#dictionary)
  - [Hints](#hints)
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
  - [Dictionary Configuration](#dictionary-configuration)
  - [Refocus after Lookup](#refocus-after-lookup)
  - [Database](#database)
  - [Hooks](#hooks)
  - [Review UI Components](#review-ui-components)
  - [Hidden Cursor](#hidden-cursor)
- [Testing and CI](#testing-and-ci)
- [Project Scope](#project-scope)
- [License](#license)

## UI Preview

### Review Mode

```text
                        REVIEWING
------------------------------------------------------------
  42 reviewed / 3 review due / 9 learning due / 120 new
------------------------------------------------------------
                         10.00%
     █████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
------------------------------------------------------------
                     [1] Again (10m)
                     [2] Hard   (1h)
                     [3] Good   (1d)
                     [4] Easy   (3d)
------------------------------------------------------------

                        mnemosyne

------------------------------------------------------------

                       /nɪˈmɑːsəni/
```

### Edit Mode

```text
Word         Hint                  Added            Last Review       Due               State      Stability Difficulty
---------------------------------------------------------------------------------------------------------------------
mnemosyne    /nɪˈmɑːsəni/          2025-04-12 09:18 2025-04-20 08:02  2025-05-18 04:00  review     32.410    3.120
athena       /əˈθiːnə/             2025-04-03 10:31 2025-04-16 07:54  2025-04-28 04:00  learning   12.220    4.050
euphrosyne   /juːˈfrɑːzəni/        2025-04-05 11:07 2025-04-19 21:45  2025-05-10 04:00  review     28.905    3.480
```

## Get Started

### Install

```emacs-lisp
;; DeckLite depends on the FSRS implementation from MELPA.
(use-package fsrs
  :ensure t)

(use-package decklite
  :ensure nil
  :load-path "path/to/the/repo"
  :commands (;; Main workflow
             decklite-add-card
             decklite-add-card-batch
             decklite-review
             decklite-edit
             ;; Backups and JSON transfer
             decklite-db-backup
             decklite-db-restore
             decklite-db-export-json
             decklite-db-import-json
             ;; Import from e-book (optional)
             decklite-import-kindle
             decklite-import-kobo)
  :hook
  ;; If you would like to turn the calendar into a review load heatmap:
  (calendar-load . decklite-calendar-mode)
  :custom
  ;; Default is nil (disabled). When set to a number, review mode shows
  ;; a daily-goal progress bar.
  (decklite-review-daily-goal 100))
```

Lookup refocus is optional but highly recommended. It can be configured via
`decklite-lookup-hook`. See [Refocus after Lookup](#refocus-after-lookup) for
details.

If you use modal editing, you may need extra configuration. See [Hidden
Cursor](#hidden-cursor) for details.

### Quick Start

1. Add cards:
   - Add a card: `M-x decklite-add-card`
   - Batch add cards: `M-x decklite-add-card-batch` (one word per line)
2. Start reviewing: `M-x decklite-review`
3. Maintain your deck: `M-x decklite-edit`

### Review Mode

Review mode is the main mode for card review, where you can review and rate
cards just like most flashcard apps.

| Key | Action                              |
|-----|-------------------------------------|
| `1` | Rate as Again                       |
| `2` | Rate as Hard                        |
| `3` | Rate as Good                        |
| `4` | Rate as Easy                        |
| `n` | Next card                           |
| `g` | Refresh review buffer               |
| `e` | Edit current word                   |
| `t` | Edit current hint                   |
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

## Features

### Dictionary

In DeckLite, dictionary lookup is equivalent to flipping the card.

There are three built-in lookup approaches: browser-based lookup (`lookup`),
in-Emacs dictionary (`define`), and pronunciation audio playback (`speak`).

- `lookup`: DeckLite inserts the word into a website URL so you can read
  meaning, pronunciation, usage, etymology, images, and related results. (In
  the config, these websites are called `lookup providers`.)
  - `l` opens your browser and goes to your default dictionary/search website.
  - `L` lets you choose a dictionary/search website, then opens it.
- `define` (`f`): shows a definition popup inside Emacs. By default, this uses
  DictionaryAPI (best for English). For other languages, you will likely want to
  plug in your own define function.
- `speak` (`s`): plays pronunciation audio for the word. By default, audio is
  fetched from DictionaryAPI (best for English). For other languages, you will
  likely want to plug in your own define function.

All three are customizable. See [Dictionary
Configuration](#dictionary-configuration) below for customization.

### Hints

Hints allow you to add useful context around a word (example sentence, IPA,
translation, mnemonic, synonyms, collocations, etc.), so you can remember the
word in real usage instead of memorizing it in isolation.

In review mode, if a card has a hint, DeckLite first shows a `[HINT]`
placeholder, then reveals the hint after `decklite-review-hint-delay`. The
delay is intentional: it reduces the chance of identifying the word from
surrounding context too early, so your first recall attempt still focuses on the
word itself.

If this behavior is not what you want, you can set `decklite-review-hint-delay`
to nil to disable it.

`t` is the universal key for hint editing:
- You can edit hints with `t` in both review mode and edit mode.
- During add flow, after adding a new word, you can press `t` at the follow-up
  prompt.

A friendly note: In minibuffer hint input, you can use `M-j` to insert a newline
for multi-line hints.

### Daily Goal

When `decklite-review-daily-goal` is set to an integer number, review mode
shows a progress bar with current progress percentage. This is useful if you
want a stable daily target instead of reviewing indefinitely or being
under-motivated.

Note that it is only a pacing indicator. DeckLite does not enforce a hard
cap. You can continue reviewing and learning new cards after the goal is
reached.

You can also do some automation around this signal through hooks. For example,
`decklite-review-daily-goal-reached-hook` can trigger a check-in message,
play a sound, or run your own logging function for habit tracking.
See [Hooks](#hooks) below.

### Edit Mode Workflow

Edit mode is useful when you want selective learning instead of only following
the default due queue.

DeckLite does not dictate how you should use edit mode, but here are a few
workflow ideas based on my daily usage:

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

When `decklite-calendar-mode` is enabled, your calendar becomes a heatmap of
upcoming review load.

- Dates with due cards are highlighted automatically.
- Highlight intensity is based on due count thresholds
  (`decklite-calendar-thresholds`).
- Due counts are computed with your rollover setting
  (`decklite-day-rollover-hour`), so "today" follows your review-day boundary.
- Moving across dates in Calendar shows the due-card count for the selected day.

To avoid conflict with your current settings, it's an opt-in feature. See
[Install](#install) on how to set it up.

### Import from e-reader

If you use Kindle Vocabulary Builder:

1. Copy `vocab.db` from your Kindle device to your computer.
2. Run `M-x decklite-import-kindle` and select that `vocab.db` file.
3. Review and edit the imported words in the temporary buffer, then confirm with
   `C-c C-c`.
4. When prompted, optionally clear the Kindle `vocab.db` to avoid re-importing
   the same words next time.
5. Copy the updated `vocab.db` back to your Kindle if you chose to clear it.

If you use Kobo:

1. Copy `KoboReader.sqlite` from your Kobo device to your computer.
2. Run `M-x decklite-import-kobo` and select that `KoboReader.sqlite` file.
3. Review and edit the imported words in the temporary buffer, then confirm with
   `C-c C-c`.
4. When prompted, optionally clear the `WordList` rows to avoid re-importing
   the same words next time.
5. Copy the updated `KoboReader.sqlite` back to your device if you chose to
   clear it.

You can also operate directly on the on-device database file. However, clearing
imported words is irreversible, so proceed at your own risk.

### Data Location

- Base directory: `decklite-directory` (defaults to `~/.emacs.d/decklite/`)
- Database file: `decklite-db-file` (defaults to `decklite.sqlite` under the base directory)
- Backups: `decklite-backup-directory` (defaults to `backups/` under the base directory)

If you want to change `decklite-directory` and all the paths derived from it,
you should set this variable before the package is loaded. If you use
`use-package`, you can either place it under `:init`, or more preferred, under
`:custom`.

```emacs-lisp
(use-package decklite
  :custom
  (decklite-directory "~/.config/decklite"))
```

## Customization

### Review Order

`decklite-review-order` lets you control the queue shape. For example: finish
learning cards first, mix learning and review together, or prioritize difficult
review cards.

Examples:

```emacs-lisp
;; Default review order
;; 1) finish due learning/relearning cards first (earliest due first)
;; 2) then review cards in random order
;; 3) finally show new cards, newest first
(setq decklite-review-order
      '((:sort :due :asc :learning)
        (:shuffle :review)
        (:sort :added :desc :new)))

;; Mix learning + review together, then shuffle them.
(setq decklite-review-order
      '((:shuffle (:learning :review))
        (:sort :added :desc :new)))

;; Focus on tough review cards first.
(setq decklite-review-order
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
(setq decklite-review-enable-interval-labels nil)
```

### Add and Refresh

`decklite-add-and-refresh` controls what happens when you add a word that
already exists but is still new (unreviewed).

- When non-nil (default), re-adding that word refreshes its `added-date` and
  `due` to now, so it is treated as newly added again.
- When nil, re-adding an existing new word does not refresh timestamps.

```emacs-lisp
;; Disable timestamp refresh when re-adding existing new words.
(setq decklite-add-and-refresh nil)
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
(setq decklite-day-rollover-hour 2)
```

### Dictionary Configuration

You can customize browser-based lookup by configuring providers.

- `decklite-lookup-providers`: list of `(NAME . URL)` providers. `URL` must
  include one `%s` placeholder.
- `decklite-lookup-default-provider`: provider name used by `decklite-lookup`.

Example: add a preferred provider.

```emacs-lisp
;; Add "Youdao" for English-to-Chinese translation
(add-to-list 'decklite-lookup-providers '("Youdao" . "https://www.youdao.com/result?word=%s&lang=en"))
;; Use "Youdao" as default provider that will be triggered by `decklite-lookup'
(setq decklite-lookup-default-provider "Youdao")
```

For in-Emacs popup definitions and pronunciation audio, customize these two
functions:

- `decklite-dictionary-define-function`: Returns a string that will be
  displayed in the popup buffer.
- `decklite-dictionary-audio-function`: Return a local audio file path to be
  played.

```emacs-lisp
(setq decklite-dictionary-define-function
      (lambda (word)
        (format "Custom definition for: %s" word)))
(setq decklite-dictionary-audio-function
      (lambda (word)
        "/path/to/word.mp3"))
```

Cache clearing:

- Use `M-x decklite-clear-api-cache` to clear the in-memory dictionary caches.
- Use `M-x decklite-clear-audio-cache` to clear the on-disk audio caches.

By default, DeckLite calls `decklite-clear-api-cache` when `decklite-edit-quit`
or `decklite-review-quit` is called.

### Refocus after Lookup

It is recommended to focus back to Emacs after browser lookup with a CLI
command. This helps you return to the review flow without manually switching
focus. You can achieve this by adding a hook function to
`decklite-lookup-hook`, which runs after opening up the browser.

macOS example:

```emacs-lisp
(use-package decklite
  :hook
  (decklite-lookup
   . (lambda ()
       (start-process-shell-command
        "decklite-refocus" nil
        "osascript -e 'tell application \"Emacs\" to activate'"))))
```

Linux (X11) example:

```emacs-lisp
(use-package decklite
  :hook
  (decklite-lookup
   . (lambda ()
       (start-process-shell-command
        "decklite-refocus" nil
        "wmctrl -a \"Emacs\""))))
```

Linux (Wayland, sway) example:

```emacs-lisp
(use-package decklite
  :hook
  (decklite-lookup
   . (lambda ()
       (start-process-shell-command
        "decklite-refocus" nil
        "swaymsg '[app_id=\"Emacs\"] focus'"))))
```

Windows (PowerShell) example:

```emacs-lisp
(use-package decklite
  :hook
  (decklite-lookup
   . (lambda ()
       (start-process-shell-command
        "decklite-refocus" nil
        "powershell -Command \"(New-Object -ComObject WScript.Shell).AppActivate('Emacs')\""))))
```

Make sure the command-line tool used in your command is installed.

### Database

DeckLite stores all card data in a single SQLite file
(`decklite-db-file`). You can use `decklite-open-db-file`, which uses
`sqlite-mode-open-file` internally, to open the SQLite file.

#### Backup

Backup behavior:

- Backups are automatically triggered on review/edit session start and quit.
- A backup is only created when the DB file has changed since the latest
  snapshot.
- Backup files are timestamped and stored in `decklite-backup-directory`.
- Old backups are pruned by retention/count rules.

Prune settings:

- `decklite-backup-retain-days`: keep backups newer than this many days.
- `decklite-backup-prune-min-count`: start pruning only after this minimum
  number of backups is reached.
- `decklite-backup-prune-max-count`: optional hard cap on backup count.
- `decklite-backup-prune-confirm`: whether to ask before pruning.

You can also manually back up or restore to a previous snapshot:

- `decklite-db-backup`: create a backup snapshot.
- `decklite-db-restore`: restore from a selected backup snapshot.

#### JSON Export and Import

`decklite-db-export-json` allows you to export the database to a JSON file for
backup, inspection, migration, or external analysis.

JSON item format:

```json
[
  {
    "word": "mnemosyne",
    "added_date": "2025-04-12T09:18:00-07:00",
    "last_review": "2025-04-20T08:02:00-07:00",
    "due": "2025-05-18T04:00:00-07:00",
    "archived_at": null,
    "state": "review",
    "step": 0,
    "stability": 32.41,
    "difficulty": 3.12,
    "hint": "/nɪˈmɑːsəni/"
  }
]
```

`decklite-db-import-json` is useful when you want to migrate FSRS metadata from
another tool or from a transformed export file. The importer reads the same
schema used by the export function, as shown above.

### Hooks

DeckLite provides several hooks for users to customize:

- `decklite-review-start-hook`: runs when `decklite-review` starts a review session.
- `decklite-review-quit-hook`: runs when `decklite-review-quit` exits review mode.
- `decklite-review-next-card-hook`: runs after moving to the next review card.
- `decklite-review-daily-goal-reached-hook`: runs when a rating changes goal status from not reached to reached.
- `decklite-edit-start-hook`: runs when `decklite-edit` opens the edit buffer.
- `decklite-edit-quit-hook`: runs when `decklite-edit-quit` exits the edit buffer.
- `decklite-lookup-hook`: runs after `decklite-lookup` opens browser lookup.
- `decklite-define-hook`: runs after `decklite-define` prepares definition content.

Gamification with sound effects is a good example of hook usage, and I highly
recommend setting it up to make the review process fun and enjoyable. Here's
an example:

```emacs-lisp
(defun my/decklite-play-sound (path)
  (start-process "decklite-sound" nil "afplay" (expand-file-name path)))

(use-package decklite
  :hook
  (decklite-review-next-card . (lambda () (my/decklite-play-sound "~/.emacs.d/custom/decklite-next-word.mp3")))
  (decklite-review-daily-goal-reached . (lambda () (my/decklite-play-sound "~/.emacs.d/custom/decklite-goal-reached.mp3")))
  (decklite-lookup . (lambda () (my/decklite-play-sound "~/.emacs.d/custom/decklite-lookup-word.mp3")))
  (decklite-define . (lambda () (my/decklite-play-sound "~/.emacs.d/custom/decklite-lookup-word.mp3"))))
```

### Review UI Components

Review mode UI is assembled from component functions.

- `decklite-review-fixed-components`: components in the main centered block
  (title, counters, options, word, separators, etc.).
- `decklite-review-floating-components`: components appended below the fixed
  block (default is the hint area).

In short:
- Fixed components are what you always want in the main review layout.
- Floating components are extra parts that may appear later (for example after
  hint delay).

`decklite-review-fill-column` controls the max text width used by review UI
rendering. If your window is very wide or very narrow, adjusting this can make
the layout look better.

Each component is just a function that takes no argument and returns a string
with one or multiple lines, which means you can easily design your own component
and plug it in. You might want to use `decklite-center-text` or
`decklite-fill-and-center-text` to center your text for better display.

Example: remove the counter component from the fixed layout.

```emacs-lisp
(setq decklite-review-fixed-components
      '(decklite-review-component-title
        decklite-review-component-separator
        ;; decklite-review-component-counters
        ;; decklite-review-component-separator
        decklite-review-component-daily-goal
        decklite-review-component-separator
        decklite-review-component-rates
        decklite-review-component-separator
        decklite-review-component-linebreak
        decklite-review-component-word
        decklite-review-component-linebreak
        decklite-review-component-separator))
```

Example: customize text width.

```emacs-lisp
(setq decklite-review-fill-column 56)
```

### Hidden Cursor

In `decklite-review-mode`, the cursor is invisible and `hl-line-mode` is
disabled by default. If you prefer DeckLite not to override the default cursor
and highlight-line behaviors, set `decklite-review-hide-cursor` to nil.

Modal editing plugins typically don't play well with the default cursor hiding
behavior. You may need an additional setup to make it work.

If you use [Evil](https://github.com/emacs-evil/evil), you might need to turn
off `evil-local-mode` inside `decklite-review-mode`, otherwise Evil keeps
refreshing the cursor and the hidden-cursor effect will not hold. I do not
personally use Evil, so please treat this as a practical workaround rather than
an official recommendation.

If you use [Meow](https://github.com/meow-edit/meow), the cursor may blink the
first time the review buffer is shown, until the next buffer refresh. It is
because its global `window-state-change-functions` hook updates the cursor
whenever the selected window changes, and its default cursor update logic treats
a nil cursor as a signal to restore the default box cursor.

You can use this buffer-local override so Meow keeps working elsewhere but stops
overriding the review buffer's hidden cursor:

```emacs-lisp
(with-eval-after-load 'meow
  (add-hook 'decklite-review-mode-hook
            (lambda ()
              (setq-local meow-update-cursor-functions-alist
                          '(((lambda () t) . ignore))))))
```

Or with `use-package`:

```emacs-lisp
(use-package decklite
  :hook
  (decklite-review-mode . (lambda ()
                             (setq-local meow-update-cursor-functions-alist
                                         '(((lambda () t) . ignore))))))
```

## Testing and CI

DeckLite keeps local checks and CI aligned through one entrypoint:

- Run everything locally: `./scripts/check-all.sh`

This script runs checks in order:

1. Parentheses check
2. Byte-compile
3. Remove generated `.elc`
4. Checkdoc
5. Package lint
6. ERT tests

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

## Project Scope

DeckLite is not trying to become an Emacs version of Anki. Its scope is
intentionally focused on:

- improving the workflow of quick card capture and review without a full card
  back
- providing extension points for advanced needs (hooks, functions, etc.), while
  leaving less common features to user extensions

New features can still be added, but only when they are useful, reasonable, and
consistent with this scope. Features that are too complex for this direction
are unlikely to be included.

Examples that are currently out of scope:

- heavy statistics dashboards
- single-card rollback/undo
- multiple decks
- per-card review history UI

If you need extra analytics, `decklite-db-export-json` is available, so you can
build your own reports.

If you need something outside this scope, extensions and forks are very welcome.

## License

GNU General Public License v3.0. See [LICENSE](./LICENSE) for details.

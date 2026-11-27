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
  - [Scheduling](#scheduling)
  - [Hooks](#hooks)
  - [Backup](#backup)
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

                           [BACK]
```

### Edit Mode

```text
Word         Hint                  Tags            Back  State      Added            Last Review       Due               Stability Difficulty
---------------------------------------------------------------------------------------------------------------------------------------------
lucid        /ˈluːsɪd/             reading         ♦     review     2025-04-12 09:18 2025-04-20 08:02  2025-05-18 04:00  32.410    3.120
zephyr       /ˈzefər/              nature                learning   2025-04-03 10:31 2025-04-16 07:54  2025-04-28 04:00  12.220    4.050
candor       /ˈkændər/             reading         ♦     review     2025-04-05 11:07 2025-04-19 21:45  2025-05-10 04:00  28.905    3.480
```

## Get Started

### Install

```emacs-lisp
;; Decklet depends on the FSRS implementation from MELPA.
(use-package fsrs
  :ensure t)

(use-package decklet
  :vc (:url "https://github.com/yilin-zhang/decklet" :rev :newest)
  :commands (;; Main workflow
             decklet-add-card
             decklet-add-card-batch
             decklet-review
             decklet-edit
             ;; Backups
             decklet-db-backup
             decklet-db-restore)
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

To bring Emacs back to the front after a browser lookup, add a function to
`decklet-lookup-hook`. On another system than macOS, swap in the command from
the comments.

```emacs-lisp
(use-package decklet
  :hook
  (decklet-lookup
   . (lambda ()
       (start-process
        "decklet-refocus" nil
        ;; Linux (X11, needs wmctrl):
        ;; "wmctrl" "-a" "Emacs"
        ;; Linux (Wayland, sway):
        ;; "swaymsg" "[app_id=\"Emacs\"] focus"
        ;; Windows:
        ;; "powershell" "-Command" "(New-Object -ComObject WScript.Shell).AppActivate('Emacs')"
        ;; macOS:
        "osascript" "-e" "tell application \"Emacs\" to activate"))))
```

Review mode hides the cursor and turns off `hl-line-mode`. Modal editing
packages can bring the cursor back:

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

| Key   | Action                                     |
|-------|--------------------------------------------|
| `m`   | Mark card at point                         |
| `u`   | Unmark card at point                       |
| `U`   | Clear all marks                            |
| `R`   | Rate current card                          |
| `A`   | Archive/Unarchive current or marked cards  |
| `D`   | Delete current or marked cards             |
| `e`   | Edit word at point                         |
| `H`   | Edit hint at point                         |
| `t`   | Edit tags; add/remove tags on marked cards |
| `. t` | Filter by tag; empty input clears filter   |
| `b`   | Show or edit card back                     |
| `. r` | Filter review cards                        |
| `. l` | Filter learning cards                      |
| `. a` | Toggle archived/all cards                  |
| `; w` | Sort by word                               |
| `; a` | Sort by added time                         |
| `; l` | Sort by last review time                   |
| `; d` | Sort by due time                           |
| `; s` | Sort by stability                          |
| `; f` | Sort by difficulty                         |
| `l`   | Look up word with default provider         |
| `L`   | Look up word with selected provider        |
| `g`   | Refresh edit buffer                        |
| `q`   | Quit edit mode                             |

## Features

### Browser Lookup

Lookup takes the place of flipping the card. `l` opens the current word in
your default provider, and `L` lets you pick one. Providers are URL templates
in `decklet-lookup-providers` (see [Install](#install)), and
`M-x decklet-switch-default-provider` changes the default.

### Hints

A hint is short context for a word, such as an example sentence, IPA or a
translation. In review it appears after a short delay, so you try to recall
the word first. Press `H` to edit it, and `M-j` in the prompt for a newline.

### Tags

Tags group cards by topic, such as `botany` or `reading`. Press `t` to edit a
card's tags, or the tags of all marked cards in edit mode, and `. t` to filter
the edit list by tag. Tags affect scheduling only through a
[review-order filter](docs/customization.md#review-order).

### Card Back

The card back is an optional note for longer content, such as etymology or
grammar patterns. Press `b` to open it. An existing back opens read-only.
Press `C-x C-q` to edit it and `C-x C-s` to save.

### Undo

Press `u` in review to go back to the previous card. Press `1`–`4` to re-rate
it, or `n` to keep the original rating. After rating the last due card, Decklet
asks before quitting so you can stay on that card and re-rate it if needed.

### Daily Goal

```emacs-lisp
;; Show a progress bar toward 100 reviews a day. nil (the default) hides it.
(setopt decklet-review-daily-goal 100)
```

The goal only paces you and does not cap the queue. To cap it, use a
[daily limit](docs/customization.md#daily-limits).

### Edit Mode Workflow

Edit mode works outside the due queue. A few ideas:

- **Re-check mature cards.** Sort by stability, and press `R` then `1` on any
  word you have forgotten.
- **Learn selectively.** Filter learning cards with `. l`, sort by `Added`,
  and rate the ones you want with `R`.
- **Archive learned words.** Sort by `Due` and press `A` on words you know
  for good.

Mark cards with `m` to archive or delete several at once.

### Batch Add Buffer

`M-x decklet-add-card-batch` opens a buffer with one word per line. `#` lines
add a hint and `:` lines add tags to the word above. Existing words keep their
hint and merge new tags. `C-c C-c` imports, and `C-c C-k` cancels.

```text
rose
:botany :flower
# A fragrant garden flower.

lily
# A garden flower with large petals.
:botany :flower
```

### Data Location

Decklet keeps its data in `decklet-directory` (`~/.emacs.d/decklet/` by
default). To move it, set the option before the package loads:

```emacs-lisp
(use-package decklet
  :custom
  (decklet-directory "~/.config/decklet"))
```

## Customization

This section covers the options most people change. Every option is described
in the [customization guide](docs/customization.md).

### Review Order

`decklet-review-order` decides which cards review mode offers and in what
order. Each entry is a group `(FILTER OP...)`. The filter picks cards, and
the operations run on them from left to right.

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
```

Groups can also filter by tag, cap new cards per topic, and mix cards into the
queue. See [Review Order](docs/customization.md#review-order) in the
customization guide.

### Scheduling

Decklet schedules cards with FSRS. The desired retention sets how often you
see a card:

```emacs-lisp
;; Target probability of recall at review time.
(setopt decklet-desired-retention 0.9)
```

For learning steps and FSRS parameters, see
[Scheduling](docs/customization.md#scheduling) in the customization guide.

### Hooks

Decklet runs these hooks. They take no arguments.

- `decklet-review-start-hook`: runs when a review session starts.
- `decklet-review-quit-hook`: runs when review mode exits.
- `decklet-review-next-card-hook`: runs after selecting the next card and before rendering the review buffer.
- `decklet-review-daily-goal-reached-hook`: runs when a rating completes the daily goal.
- `decklet-edit-start-hook`: runs when the edit buffer opens.
- `decklet-edit-quit-hook`: runs when the edit buffer exits.
- `decklet-lookup-hook`: runs after browser lookup opens.

For example, to add sound effects to review:

```emacs-lisp
(defun my/decklet-play-sound (path)
  (start-process "my-decklet-sound" nil "afplay" (expand-file-name path)))

(use-package decklet
  :hook
  (decklet-review-next-card . (lambda () (my/decklet-play-sound "~/.emacs.d/custom/decklet-next-word.mp3")))
  (decklet-review-daily-goal-reached . (lambda () (my/decklet-play-sound "~/.emacs.d/custom/decklet-goal-reached.mp3")))
  (decklet-lookup . (lambda () (my/decklet-play-sound "~/.emacs.d/custom/decklet-lookup-word.mp3"))))
```

Hooks for card events (added, deleted, renamed, rated) are described in
[Writing Extensions](docs/extensions.md#lifecycle-hooks).

### Backup

- Decklet backs up when a review or edit session starts and quits, and only
  when the database has changed.
- Each backup holds the database and the review log, so a restore brings back
  both together.
- Decklet keeps the newest 20 backups and deletes older ones.

`M-x decklet-db-backup` makes a backup now, and `M-x decklet-db-restore`
restores one you pick from a list, newest first. Backup options are in
[Backup](docs/customization.md#backup) in the customization guide.

## Extensions

Optional features, such as pronunciation audio, images and review
statistics, live in the separate
[`decklet-extensions`](https://github.com/yilin-zhang/decklet-extensions)
repo.

To write your own, see [Writing Extensions](docs/extensions.md).

## License

GNU General Public License v3.0. See [LICENSE](./LICENSE) for details.

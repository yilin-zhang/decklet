# Writing Extensions

This document is for people who build on Decklet: extension authors, tools
that read Decklet's data, and anyone who wants the exact rules behind a
feature. For everyday use, see the [README](../README.md).

Decklet exposes a small public API and a set of card lifecycle hooks, so you
can build sidecar packages (audio, images, definitions, annotations,
analytics) without touching Decklet internals. The packages in
[`decklet-extensions`](https://github.com/yilin-zhang/decklet-extensions) are
all built this way and are good worked examples.

- [Public API](#public-api)
- [Lifecycle hooks](#lifecycle-hooks)
- [Example: per-card image sidecar](#example-per-card-image-sidecar)
- [Review Log](#review-log)
- [Review order reference](#review-order-reference)
- [JSON import fields](#json-import-fields)
- [Testing and CI](#testing-and-ci)

## Public API

### Reading cards

| Function | Returns |
|---|---|
| `(decklet-card-exists-p CARD-ID)` | non-nil if `CARD-ID` is in the deck |
| `(decklet-get-card CARD-ID)` | plist `(:card-id :word :hint :back :tags :meta)` or nil |
| `(decklet-require-card CARD-ID)` | same as above, but signals a `user-error` when the card is missing |
| `(decklet-get-card-hint CARD-ID)` | hint string or nil |
| `(decklet-get-card-back CARD-ID)` | card back content or nil |
| `(decklet-get-card-tags CARD-ID)` | sorted tag strings or nil |
| `(decklet-list-tags)` | all tag names, sorted and unique |
| `(decklet-get-card-meta CARD-ID)` | `decklet-card-meta` struct or nil |
| `(decklet-get-card-word CARD-ID)` | current word string or nil |
| `(decklet-get-card-id-by-word WORD)` | card id or nil |
| `(decklet-list-words &optional FILTER)` | list of words; FILTER is `all` (default), `review`, `learning`, or `archived` |
| `(decklet-db-due-counts-by-date DAY-START CUTOFF)` | plist `(:rows :overdue)`; `:rows` is a list of `(DATE-STRING COUNT)` between the two time values, `:overdue` counts cards due before `DAY-START` |

### Mutating cards

| Function | Effect |
|---|---|
| `(decklet-set-card-hint CARD-ID HINT)` | update hint; fires field-updated hook |
| `(decklet-set-card-back CARD-ID CONTENT)` | update card back; fires field-updated hook |
| `(decklet-set-card-tags CARD-ID TAGS)` | replace tags; fires field-updated event with `:field tags` when changed |
| `(decklet-add-card-tags CARD-ID TAGS)` | add tags, keeping existing ones |
| `(decklet-remove-card-tags CARD-ID TAGS)` | remove only the specified tags |
| `(decklet-set-card-word CARD-ID NEW-WORD)` | rename a card's word; fires renamed hook |
| `(decklet-delete-card CARD-ID)` | delete a card; fires deleted hook |
| `(decklet-archive-card CARD-ID)` / `(decklet-unarchive-card CARD-ID)` | fire archived/unarchived hooks |
| `(decklet-rate-card CARD-ID GRADE &optional PRIOR-GRADE)` | grade a card; fires rated hook |

Calls to `decklet-set-card-*` also refresh the review and edit buffers
through the field-updated hook, so extensions do not manage refresh
themselves.

### Tag matching and daily history

- `(decklet-validate-tag-selector SELECTOR)` checks the selector grammar.
- `(decklet-tags-match-p TAGS SELECTOR)` matches a validated selector against
  tag strings without querying the database.
- `(decklet-review-log-daily-card-states &optional TIME)` returns distinct
  `(CARD-ID . STATE)` pairs for valid ratings in that review day, excluding
  voided records. `STATE` is the pre-rating FSRS keyword (`:new`, etc.);
  only the review-order configuration uses plain state symbols. Extensions
  can combine these pairs with current card tags for their own statistics.
- `(decklet-review-log-daily-state-counts &optional TIME)` returns aggregate
  per-state counts.

### Context helpers

- `decklet-current-card-id`: the card id currently displayed in review
  (nil outside review).
- `(decklet-prompt-word &optional PROMPT)`: resolve the word from an
  active region, the current review word, the word on the current edit
  line, or the minibuffer.

### Per-card files

Extensions that keep a file per card (images, audio) should name it by card
id:

- `(decklet-card-sidecar-file DIRECTORY CARD-ID EXTENSION)`: the path
  `DIRECTORY/CARD-ID.EXTENSION`, whether or not it exists.

The id survives renames, so files need no migration when a word changes. Words
are unsafe as file names. `Polish` and `polish` are two cards, but a
case-insensitive file system (macOS's default) folds them into one file.

### Session buffers

If your extension opens its own popup or side buffer that belongs to
the Decklet session (like the built-in card-back popup), call
`(decklet-db-acquire-session-buffer)` once during that buffer's setup.
Session buffers keep the shared SQLite connection open while they
live. Quitting the last review/edit buffer closes them first (each may
prompt to save), `decklet-disconnect` closes them explicitly, and a
backup restore refuses to run while any is open. Querying the deck
from one-shot commands outside a session needs no special handling.

`decklet-db-acquire-session-buffer` returns a disposer that releases
the lease. If the buffer lives exactly as long as its use of the DB,
you can ignore the disposer, because killing the buffer releases the
lease. If the buffer can outlive it, say with a minor mode the user
can switch off, keep the disposer and call it when you let go.
Otherwise the connection stays open with nothing holding it. For
example:

```elisp
(defvar-local my-ext--release-session nil)

(define-minor-mode my-ext-mode
  "..."
  (if my-ext-mode
      (unless my-ext--release-session
        (setq my-ext--release-session (decklet-db-acquire-session-buffer)))
    (when my-ext--release-session
      (funcall my-ext--release-session)
      (setq my-ext--release-session nil))))
```

The disposer is idempotent and stays safe once the buffer is dead, so
the mode-off and kill-buffer paths can both run without coordination.
`(decklet-db-register-session-buffer)` is the same call with the disposer
discarded, for buffers whose lease should last as long as they do.

Use `decklet-db-pre-disconnect-hook` only for last-chance cleanup of
sidecar resources that should go away when Decklet fully disconnects.

`decklet-db-pre-connect-hook` runs right before Decklet opens the
SQLite connection, once per connection. A function on it may signal an
error (usually a `user-error`) to refuse the connection. The error
reaches whichever command needed the database, and nothing is opened.
This guards every entry point at once (review, edit, adding cards,
import/export), so prefer it over advising individual commands.

### Faces

Define faces with plain `defface` and get colors through `:inherit`.
`:inherit` is resolved when the face is realized, so it follows the
active theme. A `face-attribute` call in a backquoted spec is evaluated
once at load time and freezes whatever palette was active then.

Decklet's shared `decklet-color-*` faces are made for this. Each names a
color role and carries a single foreground inherited from the
`ansi-color` palette. Inherit from those and layer on your own weight or
height:

```emacs-lisp
(defface my/decklet-indicator-face
  '((t :inherit decklet-color-state-review :weight bold))
  "Face for my extension's review indicator."
  :group 'my-decklet-extension)
```

If you inherit straight from an `ansi-color` face, add
`:background reset`. Those faces set `:background` to the same color as
`:foreground`, which renders as a solid block.

### Review UI components

Each entry in `decklet-review-fixed-components` and
`decklet-review-floating-components` is a function that takes no arguments
and returns a string. You can write your own and add it to either list. Use
`decklet-center-text` or `decklet-fill-and-center-text` to center the output.

### Edit-mode columns

`decklet-edit-sidecar-columns` lets an extension add its own columns to the
edit table, inserted after the built-in `Back` column. Each entry is a plist:

- `:name`: column header string
- `:width`: `tabulated-list` column width
- `:value`: function of one ROW plist, returning a display cell or nil

```emacs-lisp
(add-to-list 'decklet-edit-sidecar-columns
             (list :name "Img"
                   :width 4
                   :value (lambda (row)
                            (if (file-exists-p
                                 (my/decklet-image-path (plist-get row :card-id)))
                                "♦"
                              ""))))
```

### Backing up auxiliary files

If your extension keeps files next to the database, they can ride along in
Decklet's backup rotation. Add a function to
`decklet-db-post-backup-functions`, an abnormal hook called with `BACKUP-DIR`
and `TIMESTAMP` after a successful backup, and have it call
`decklet-backup-auxiliary-file`. That copies a file into the snapshot with the
same naming scheme and retention policy as the core:

```emacs-lisp
(defvar my/decklet-notes-file "~/decklet-notes.json")

(defun my/decklet-backup-notes (backup-dir timestamp)
  (when (file-exists-p my/decklet-notes-file)
    (decklet-backup-auxiliary-file my/decklet-notes-file backup-dir timestamp)))

(add-hook 'decklet-db-post-backup-functions #'my/decklet-backup-notes)
```

## Lifecycle hooks

All card lifecycle hooks are abnormal hooks that take a single
argument, a non-empty list of per-card event plists. Bulk operations
(imports, batch add) fire the hook once with all events, and single-card
operations fire it once with a one-element list. Every event plist
carries `:card-id`, and richer events carry the extra keys shown below.

| Hook | Per-event plist keys | Fires when |
|---|---|---|
| `decklet-cards-added-functions` | `:card-id` | a new card is stored (including imports) |
| `decklet-cards-deleted-functions` | `:card-id`, `:card` (pre-delete plist snapshot) | a card is removed from the deck |
| `decklet-cards-renamed-functions` | `:card-id`, `:old-word`, `:new-word` | a card's word key changes |
| `decklet-cards-archived-functions` | `:card-id` | a card is archived |
| `decklet-cards-unarchived-functions` | `:card-id` | a card is unarchived |
| `decklet-cards-field-updated-functions` | `:card-id`, `:field` (`hint`, `back`, `tags`, `import` for bulk JSON imports, or an extension-defined symbol such as `image`) | hint/back/tag changes, JSON-import overwrites, or extension-owned sidecar changes |
| `decklet-cards-rated-functions` | `:card-id`, `:old-meta`, `:grade`, `:new-meta`, `:prior-grade` | a card is rated in review or edit mode |

Consumers iterate over the events:

```emacs-lisp
(defun my/on-cards-deleted (events)
  (dolist (event events)
    (let ((word (plist-get (plist-get event :card) :word)))
      ...)))

(add-hook 'decklet-cards-deleted-functions #'my/on-cards-deleted)
```

### About the rated hook

The `decklet-cards-rated-functions` hook fires for every completed
grading action, in both review and edit modes.

- `:prior-grade` is nil for fresh ratings.
- When the user undoes a rating and re-rates with a different grade
  within the same session, `:prior-grade` is the grade being replaced.
  Extensions that track per-grade statistics should decrement the
  prior-grade counter to compensate for the original event.
- A re-rate also discards the same card's later reviews in that session.
  No event is fired for those. Consumers that need exact per-grade totals
  should rebuild them from the review log, which voids them.
- Undo alone does not fire this hook (no DB change).
- Confirming an undone rating (`n` on an undone card) does not fire
  the hook either, because the original event already reflects the final state.

## Example: per-card image sidecar

A complete example of a sidecar that stores a PNG per card in a folder,
keeps it in sync with the deck, and shows an `[IMG]` indicator in the
review UI:

```emacs-lisp
(defvar my/decklet-image-dir "~/decklet-images/"
  "Directory where per-card PNG files live.")

(defun my/decklet-image-path (card-id)
  (decklet-card-sidecar-file my/decklet-image-dir card-id "png"))

(defun my/decklet-image-delete (events)
  (dolist (event events)
    (let ((path (my/decklet-image-path (plist-get event :card-id))))
      (when (file-exists-p path) (delete-file path)))))

(defun my/decklet-image-indicator ()
  "Review UI component showing [IMG] when the current card has an image."
  (when (and decklet-current-card-id
             (file-exists-p (my/decklet-image-path decklet-current-card-id)))
    (decklet-center-text
     (propertize "[IMG]" 'face 'decklet-review-card-back-indicator-face))))

(add-hook 'decklet-cards-deleted-functions #'my/decklet-image-delete)
(add-to-list 'decklet-review-floating-components #'my/decklet-image-indicator)
```

Because files are keyed by card id, a rename needs no handling. A
sidecar whose content depends on the word itself (pronunciation audio, say)
would also subscribe to `decklet-cards-renamed-functions` and discard or
regenerate the file there.

## Review Log

Decklet keeps an append-only log of every review event at
`decklet-review-log-file`. The file is JSONL, with one JSON object per line.
Decklet writes a rating record before updating the card in SQLite. If the
database update fails, it appends a `void` record to retire that rating, so a
rating never lands in the database without a log record. The JSONL file and
the SQLite database are still two files, so the pair is not written
atomically.

Three event kinds are written:

| `kind` | Fields | Meaning |
|---|---|---|
| `rated` | `id`, `card_id`, `t`, `word`, `grade`, `pre_state`, `pre_stability`, `pre_difficulty`, `post_state`, `post_stability`, `post_difficulty`, `elapsed_days` | A card was graded. |
| `void` | `voids`, `t` | Nullifies an earlier `rated` record by its `id`. |
| `rename` | `card_id`, `old`, `new`, `t` | A card's word changed. |

Consumer notes:

- Skip any `rated` record whose `id` appears as the `voids` target of a `void`
  event. Voids are written when you undo a rating and re-grade it differently
  within one session.
- Group by `card_id`. It is stable across renames, so optimizers can ignore
  `rename` events. Those exist for tools that want to reconstruct the word as
  it was at rating time.
- Deletions are not logged. Ratings of deleted cards stay in the log, since
  they are still valid training data.
- Treat the file as append-only. Decklet core has no API for reading single
  records, so read the file directly.

Tuner code should apply new FSRS weights with
`(decklet-set-fsrs-parameters PARAMS)`, which routes through the option's
`:set` handler and invalidates the cached scheduler.

## Review order reference

The README covers everyday `decklet-review-order` settings. This section
gives the full grammar and the exact ownership and quota rules.

```text
STEP   := (SOURCE SPEC)
SOURCE := STATES | (STATES :tags SELECTOR)
STATES := STATE | (STATE ...)
STATE  := learning | relearning | review | new
SPEC   := SIZED | (spread SIZED)
SIZED  := BASE | (daily-limit N BASE)
BASE   := shuffle | (sort FIELD ORDER)
SELECTOR := "tag" | (or SELECTOR ...) | (and SELECTOR ...) | (not SELECTOR)
```

`and` and `or` require at least one expression, and `not` requires exactly
one. Expressions may nest, for example `(and "botany" (not "paused"))`.
Sorting uses `:asc` or `:desc`. Every source supports `:due` and `:added`,
and review-only sources also support `:last-review`, `:difficulty`, and
`:stability`. A combined-state step has one shared daily allowance.

### Ownership

Ownership is decided for the whole deck before any step selects cards:

1. A matching tag-selector step takes priority over a plain fallback step,
   regardless of their positions in the configuration.
2. When multiple tag selectors match the same card's state and tags, the
   first matching selector owns it. A card tagged both `botany` and `medicine`
   belongs only to the first matching step, including for quota accounting.
   If that step is full or paused, the card does not spill into later steps
   or the fallback.
3. Each state allows at most one fallback step. States may appear in multiple
   tag-selector steps. Cards matched by neither a selector nor a fallback
   are not offered.
4. Ownership applies within the selected states. A `(new :tags "botany")`
   rule leaves botany cards in the ordinary `review` step.

After ownership is assigned, each step sorts or shuffles its cards, takes its
remaining daily allowance, and places the result in configuration order.
`spread` inserts evenly through everything preceding steps have gathered;
otherwise the step appends. It cannot be the first step. If preceding steps
produce no cards, its own cards are still offered. It does not shuffle
globally, and it keeps no fixed ratio once the other groups run out. Unused
slots in one step are not transferred to another.

### Daily limit accounting

`(daily-limit N BASE)` selects at most `N` minus today's consumption.
Consumption counts distinct (card id, pre-rating state) pairs from valid
ratings in the current review day. Opening or skipping a card consumes
nothing. Undo alone leaves the rating in place, and re-rating replaces the
previous record through the log's void mechanism.

To allocate consumption to steps, Decklet uses each rated card's current tags
and the current selector priority. Changing tags or reordering selectors
recalculates today's quotas immediately. If a corrected group is already over
its limit, it offers no more cards today, and completed ratings stay intact.
Tag edits append no review-log events. The rating's pre-state still comes
from the log, so a word first learned today counts as `new` consumption even
after it graduates to `review`. Deleted cards have no current tags and count
as untagged.

Missing or unreadable logs grant the full allowance. An unwritable log
prevents a rating from being committed.

The review counters and the queue share one plan, so refreshing counters
does not reshuffle unchanged candidates. Deleting a card removes only that
card from the pending queue. Tag changes rebuild the pending queue, while the
displayed card and undo history stay available. Day and review-order changes
are picked up when advancing to the next card.

## JSON import fields

`decklet-db-import-json` reads the schema that `decklet-db-export-json`
writes. When an import overwrites an existing card:

- `hint` and `back`: a missing key keeps the existing value. `null` or a
  blank string clears it.
- `tags`: a missing key keeps the existing tags. `["botany", "flower"]`
  replaces them, and `[]` clears them.

Timestamps may be any ISO 8601 date-time, with or without a UTC offset. They
are stored converted to UTC (`2025-04-12T16:18:00Z`), the form Decklet
itself writes. Two records with the same word in one file are rejected.

## Testing and CI

Run every check locally with `./scripts/check-all.sh`. CI runs the same
script in GitHub Actions. It runs, in order:

1. Parentheses check
2. Indentation check
3. Byte-compile, with warnings treated as errors
4. Remove generated `.elc`
5. Checkdoc
6. Package lint and ERT tests

Individual scripts live under `scripts/`, such as `check-checkdoc.sh`,
`check-package-lint.sh` and `check-ert.sh`. `check-deps.sh` resolves
`fsrs.el` for the compile and test steps (a local file first, then a cache or
download pinned to a fixed commit), and `check-package-lint.sh` fetches
`package-lint` pinned to a fixed commit.

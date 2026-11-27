# Writing Extensions

For extension authors and tools that read Decklet's data. Extensions use the
public API and card lifecycle hooks below, without touching Decklet internals.
The packages in
[`decklet-extensions`](https://github.com/yilin-zhang/decklet-extensions) are
worked examples.

- [Public API](#public-api)
- [Lifecycle hooks](#lifecycle-hooks)
- [Example: per-card image sidecar](#example-per-card-image-sidecar)
- [Review Log](#review-log)
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
| `(decklet-list-words &optional FILTER)` | list of words; FILTER is `all` (default, active non-archived cards), `review`, `learning`, or `archived` |
| `(decklet-db-due-counts-by-date DAY-START CUTOFF)` | plist `(:rows :overdue)`; `:rows` is a list of `(DATE-STRING COUNT)` between the two time values, `:overdue` counts cards due before `DAY-START` |
| `(decklet-review-log-ratings-since CUTOFF)` | `rated` log records at or after the time `CUTOFF`, newest first, without voided ones; each is a plist with the fields listed under [Review log](#review-log) |

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
| `(decklet-archive-card CARD-ID)` / `(decklet-unarchive-card CARD-ID)` | archive or unarchive; fire hooks when state changes |
| `(decklet-rate-card CARD-ID GRADE &optional PRIOR-GRADE)` | grade a card; fires rated hook |
| `(decklet-set-fsrs-parameters PARAMS)` | install FSRS weights and drop the cached scheduler |

The review and edit buffers refresh themselves through the field-updated hook.

### Context helpers

- `decklet-current-card-id` is the card shown in review, or nil.
- `(decklet-prompt-word &optional PROMPT)` takes the word from the region, the
  review card, the edit line or the minibuffer.

### Per-card files and data paths

Paths are resolved against `decklet-directory` at call time, so changing
`decklet-directory` (for example in a multi-deck switcher) moves every file
together. Store relative paths in extension `defcustom` options (such as
`"images"` or `"audio-cache/my-tts"`) and resolve them with
`(expand-file-name my-dir decklet-directory)` on use.

Core exposes `(decklet-db-file)` and `(decklet-review-log-file)` for the
active database and review-log paths, and `(decklet-session-active-p)` to test
whether a session buffer or DB connection is currently open.

Name per-card files by card id with
`(decklet-card-sidecar-file DIRECTORY CARD-ID EXTENSION)`, which returns
`DIRECTORY/CARD-ID.EXTENSION`. The id survives renames. Words make poor file
names, because `Polish` and `polish` are two cards but one file on a
case-insensitive file system.

### Connection

The review and edit buffers hold the SQLite connection while they live. Other
code that calls the API opens it when needed. Wrap one-shot commands outside a
session in `(decklet-with-db BODY...)`, which disconnects afterward when no
session buffer is open and shares the connection across nested calls:

```emacs-lisp
(decklet-with-db
  (when-let* ((card-id (decklet-get-card-id-by-word word)))
    (decklet-get-card-hint card-id)))
```

- `decklet-db-pre-connect-hook` runs before each connection opens. Signal an
  error, usually a `user-error`, to refuse it. This guards every command that
  needs the database.
- `decklet-db-pre-disconnect-hook` runs before the connection closes, including
  at the end of a one-shot `decklet-with-db` outside a session. Use it for
  locks or DB caches. Long-lived helper processes that should stay warm across
  one-shot commands should stop on `decklet-review-quit-hook` /
  `decklet-edit-quit-hook` and an idle timer.

### Faces

Take colors through `:inherit`, so faces follow the theme. The
`decklet-color-*` faces each carry one foreground for a color role:

```emacs-lisp
(defface my/decklet-indicator-face
  '((t :inherit decklet-color-state-review :weight bold))
  "Face for my extension's review indicator."
  :group 'my-decklet-extension)
```

When inheriting an `ansi-color` face directly, add `:background reset`.
Those faces set the background to the foreground color.

### Review UI components

Each entry in `decklet-review-fixed-components` and
`decklet-review-floating-components` is a function of no arguments that
returns a string, a list of strings, or nil. The review screen centers a
string as one block and each string of a list on its own line.
`decklet-fill-text` wraps text into such a list.

An entry can also be a list of functions, joined on one line.
`decklet-review-component-space` between them adds a space only when both
sides show something:

```emacs-lisp
(decklet-review-component-card-back-indicator
 decklet-review-component-space
 my/decklet-custom-indicator)
```

### Edit-mode columns

Each entry of `decklet-edit-sidecar-columns` adds a column after `Back`:

```emacs-lisp
(add-to-list 'decklet-edit-sidecar-columns
             (list :name "Img"          ; header
                   :width 4             ; tabulated-list width
                   :value (lambda (row) ; ROW plist to a cell or nil
                            (if (file-exists-p
                                 (my/decklet-image-path (plist-get row :card-id)))
                                "♦"
                              ""))))
```

## Lifecycle hooks

Each hook takes one argument, a list of per-card event plists. Batch add fires
once with all events; edit-mode bulk actions fire per card. Every event has
`:card-id`, plus the keys below. Subscriber errors are caught and reported as
warnings. UI hooks are listed in the [README](../README.md#hooks).

| Hook | Extra keys | Fires when |
|---|---|---|
| `decklet-cards-added-functions` | | a card is stored |
| `decklet-cards-deleted-functions` | `:card` (plist before deletion) | a card is removed |
| `decklet-cards-renamed-functions` | `:old-word`, `:new-word` | a card's word changes |
| `decklet-cards-archived-functions` | | a card is archived |
| `decklet-cards-unarchived-functions` | | a card is unarchived |
| `decklet-cards-field-updated-functions` | `:field` (`hint`, `back`, `tags`, `added-date`, or your own symbol such as `image`) | a field or sidecar changes |
| `decklet-cards-rated-functions` | `:old-meta`, `:grade`, `:new-meta`, `:prior-grade` | a card is rated in review or edit mode |

To notify review and edit buffers when an extension updates its own sidecar,
call `(decklet-fire-one-card-event 'decklet-cards-field-updated-functions :card-id card-id :field 'image)`.

```emacs-lisp
(defun my/on-cards-deleted (events)
  (dolist (event events)
    (let ((word (plist-get (plist-get event :card) :word)))
      ...)))

(add-hook 'decklet-cards-deleted-functions #'my/on-cards-deleted)
```

### About the rated hook

- `:prior-grade` is the grade being replaced when the user undoes and re-rates
  in the same session, and nil otherwise. Per-grade counters should subtract
  it.
- A re-rate also discards the card's later reviews in that session, without an
  event. For exact totals, rebuild from the review log.
- Undo alone, and confirming an undone rating with `n`, fire nothing.

## Example: per-card image sidecar

Stores a PNG per card, deletes it with the card, and shows `[IMG]` in review:

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
    (propertize "[IMG]" 'face 'decklet-review-card-back-indicator-face)))

(add-hook 'decklet-cards-deleted-functions #'my/decklet-image-delete)
(add-to-list 'decklet-review-floating-components #'my/decklet-image-indicator)
```

A sidecar whose content depends on the word, such as pronunciation audio,
also needs `decklet-cards-renamed-functions`.

## Review Log

`(decklet-review-log-file)` returns the path to the append-only JSONL file,
one event per line. Read it directly. A rating is logged before the card is
updated in SQLite, and a failed update appends a `void`, so the database never
holds a rating the log lacks.

| `kind` | Fields | Meaning |
|---|---|---|
| `rated` | `id`, `card_id`, `t`, `word`, `grade`, `pre_state`, `pre_effective_state`, `pre_stability`, `pre_difficulty`, `post_state`, `post_stability`, `post_difficulty`, `elapsed_days` | A card was graded. |
| `void` | `voids`, `t` | Cancels the `rated` record whose `id` is `voids`. |
| `rename` | `card_id`, `old`, `new`, `t` | A card's word changed. |

- Skip voided `rated` records.
- Prefer `pre_effective_state`. `pre_state` cannot tell a new card from one in
  learning.
- Group by `card_id`, which survives renames. `rename` events only matter for
  recovering the word at rating time.
- Deletions are not logged, so ratings of deleted cards stay.

## Testing and CI

`./scripts/check-all.sh` runs every check, and CI runs the same script:
parentheses, indentation, byte-compile with warnings as errors, checkdoc,
package-lint and ERT. Each step has its own script under `scripts/`.
`check-deps.sh` resolves `fsrs.el` at a pinned commit, from a local file, a
cache or a download.

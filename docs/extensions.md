# Writing Extensions

Reference for Decklet extensions and external tools. Stick to the public API
and hooks below. See
[`decklet-extensions`](https://github.com/yilin-zhang/decklet-extensions) for
real examples.

- [Public API](#public-api)
- [Lifecycle hooks](#lifecycle-hooks)
- [Example: per-card image sidecar](#example-per-card-image-sidecar)
- [Review Log](#review-log)
- [Testing and CI](#testing-and-ci)

## Public API

### Reading cards

| Function | Returns |
|---|---|
| `(decklet-card-exists-p CARD-ID)` | non-nil if `CARD-ID` exists |
| `(decklet-get-card CARD-ID)` | plist `(:card-id :word :hint :back :tags :meta)` or nil |
| `(decklet-require-card CARD-ID)` | same as `decklet-get-card`, or signals `user-error` if missing |
| `(decklet-get-card-hint CARD-ID)` | hint string or nil |
| `(decklet-get-card-back CARD-ID)` | card back string or nil |
| `(decklet-get-card-tags CARD-ID)` | sorted list of tag strings or nil |
| `(decklet-list-tags)` | all tags, sorted and unique |
| `(decklet-get-card-meta CARD-ID)` | `decklet-card-meta` struct or nil |
| `(decklet-get-card-word CARD-ID)` | word string or nil |
| `(decklet-get-card-id-by-word WORD)` | card id or nil |
| `(decklet-list-words &optional FILTER)` | words matching `all` (default, active cards), `review`, `learning`, or `archived` |
| `(decklet-db-due-counts-by-date DAY-START CUTOFF)` | plist `(:rows :overdue)`; `:rows` is `((DATE-STRING COUNT) ...)` in range, `:overdue` counts cards due before `DAY-START` |
| `(decklet-review-log-ratings-since CUTOFF)` | non-voided `rated` records at or after `CUTOFF`, newest first; fields match [Review Log](#review-log) |

### Mutating cards

| Function | Effect |
|---|---|
| `(decklet-set-card-hint CARD-ID HINT)` | update hint; fires field-updated hook |
| `(decklet-set-card-back CARD-ID CONTENT)` | update card back; fires field-updated hook |
| `(decklet-set-card-tags CARD-ID TAGS)` | replace tags; fires field-updated hook with `:field tags` if changed |
| `(decklet-add-card-tags CARD-ID TAGS)` | add tags, keeping existing ones |
| `(decklet-remove-card-tags CARD-ID TAGS)` | remove matching tags |
| `(decklet-set-card-word CARD-ID NEW-WORD)` | rename word; fires renamed hook |
| `(decklet-delete-card CARD-ID)` | delete card; fires deleted hook |
| `(decklet-archive-card CARD-ID)` / `(decklet-unarchive-card CARD-ID)` | archive or unarchive; fires hook if state changes |
| `(decklet-rate-card CARD-ID GRADE &optional PRIOR-GRADE)` | grade card; fires rated hook |
| `(decklet-set-fsrs-parameters PARAMS)` | set FSRS weights and rebuild scheduler |

Review and edit buffers refresh automatically via the field-updated hook.

### Context helpers

- `decklet-current-card-id` holds the active review card id, or nil.
- `(decklet-prompt-word &optional PROMPT)` picks a word from the region,
  review card, edit row, or minibuffer.

### Per-card files and data paths

Resolve paths against `decklet-directory` on use so switching decks moves all
files together. Store relative paths in extension options (such as `"images"`
or `"audio/my-tts"`) and expand them with
`(expand-file-name my-dir decklet-directory)`.

Use `(decklet-db-file)` and `(decklet-review-log-file)` for the active data
files, and `(decklet-session-active-p)` to check if a session or DB connection
is open.

Use `(decklet-card-sidecar-file DIRECTORY CARD-ID EXTENSION)` to build
`DIRECTORY/CARD-ID.EXTENSION`. Keying by card id survives renames and avoids
collisions like `Polish` vs `polish` on case-insensitive file systems.

### Connection

Review and edit buffers keep the SQLite connection open while alive. For
one-shot commands outside a session, wrap DB calls in
`(decklet-with-db BODY...)`. It shares an open connection when nested and
closes it afterward if no session buffer is open:

```emacs-lisp
(decklet-with-db
  (when-let* ((card-id (decklet-get-card-id-by-word word)))
    (decklet-get-card-hint card-id)))
```

- `decklet-db-pre-connect-hook` runs before opening a connection. Signal an
  error (usually `user-error`) to block access.
- `decklet-db-pre-disconnect-hook` runs before closing a connection, including
  after a one-shot `decklet-with-db`. Use it to release locks or drop caches.
  For long-lived helper processes, stop them on `decklet-review-quit-hook`,
  `decklet-edit-quit-hook`, or an idle timer.

### Faces

Inherit from `decklet-color-*` faces so colors follow the active theme:

```emacs-lisp
(defface my/decklet-indicator-face
  '((t :inherit decklet-color-state-review :weight bold))
  "Face for my extension's review indicator."
  :group 'my-decklet-extension)
```

If you inherit an `ansi-color` face directly, add `:background reset` because
those faces set both foreground and background.

### Review UI components

Entries in `decklet-review-fixed-components` and
`decklet-review-floating-components` are zero-argument functions returning a
string, a list of strings, or nil. A single string is centered as one block;
elements of a list are centered on separate lines (`decklet-fill-text` wraps
text into this shape).

An entry can also be a list of functions rendered on one line. Put
`decklet-review-component-space` between them to insert a space only when both
neighbors are non-empty:

```emacs-lisp
(decklet-review-component-card-back-indicator
 decklet-review-component-space
 my/decklet-custom-indicator)
```

### Edit-mode columns

Add entries to `decklet-edit-sidecar-columns` to insert columns after `Back`:

```emacs-lisp
(add-to-list 'decklet-edit-sidecar-columns
             (list :name "Img"          ; header
                   :width 4             ; column width
                   :value (lambda (row) ; ROW plist -> cell string or nil
                            (if (file-exists-p
                                 (my/decklet-image-path (plist-get row :card-id)))
                                "♦"
                              ""))))
```

## Lifecycle hooks

Each hook passes a list of event plists. Batch add fires once with all cards;
edit-mode bulk actions fire per card. Every event includes `:card-id` plus the
keys below. Errors in subscribers are caught and logged as warnings. For UI
hooks, see the [README](../README.md#hooks).

| Hook | Extra keys | Fires when |
|---|---|---|
| `decklet-cards-added-functions` | | a card is added |
| `decklet-cards-deleted-functions` | `:card` (plist before deletion) | a card is deleted |
| `decklet-cards-renamed-functions` | `:old-word`, `:new-word` | a card is renamed |
| `decklet-cards-archived-functions` | | a card is archived |
| `decklet-cards-unarchived-functions` | | a card is unarchived |
| `decklet-cards-field-updated-functions` | `:field` (`hint`, `back`, `tags`, `added-date`, or a custom symbol) | a field or sidecar changes |
| `decklet-cards-rated-functions` | `:old-meta`, `:grade`, `:new-meta`, `:prior-grade` | a card is rated |

Notify review and edit buffers after updating your own sidecar with
`(decklet-fire-one-card-event 'decklet-cards-field-updated-functions :card-id card-id :field 'image)`.

```emacs-lisp
(defun my/on-cards-deleted (events)
  (dolist (event events)
    (let ((word (plist-get (plist-get event :card) :word)))
      ...)))

(add-hook 'decklet-cards-deleted-functions #'my/on-cards-deleted)
```

### Rated hook notes

- `:prior-grade` is set when undoing and re-rating in the same session, and
  nil otherwise. Per-grade counters should subtract it.
- Re-rating also drops later reviews of that card in the same session without
  firing an event. Rebuild from the review log for exact totals.
- Plain undo and confirming with `n` do not fire the hook.

## Example: per-card image sidecar

Stores a PNG per card under `decklet-directory`, deletes it with the card, and
shows `[IMG]` during review:

```emacs-lisp
(defcustom my/decklet-image-dir "images"
  "Directory for per-card PNG files, relative to `decklet-directory'."
  :type 'directory
  :group 'decklet)

(defun my/decklet-image-path (card-id)
  (decklet-card-sidecar-file
   (expand-file-name my/decklet-image-dir decklet-directory)
   card-id "png"))

(defun my/decklet-image-delete (events)
  (dolist (event events)
    (delete-file (my/decklet-image-path (plist-get event :card-id)))))

(defun my/decklet-image-indicator ()
  "Show [IMG] when the current review card has an image."
  (when (and decklet-current-card-id
             (file-exists-p (my/decklet-image-path decklet-current-card-id)))
    (propertize "[IMG]" 'face 'decklet-review-card-back-indicator-face)))

(add-hook 'decklet-cards-deleted-functions #'my/decklet-image-delete)
(add-to-list 'decklet-review-floating-components #'my/decklet-image-indicator)
```

For word-dependent sidecars such as pronunciation audio, hook
`decklet-cards-renamed-functions` too.

## Review Log

`(decklet-review-log-file)` returns the path to the append-only JSONL log, one
event per line. Ratings are appended before updating SQLite; if the database
write fails, a `void` record cancels the entry so the log stays consistent
with the database.

| `kind` | Fields | Meaning |
|---|---|---|
| `rated` | `id`, `card_id`, `t`, `word`, `grade`, `pre_state`, `pre_effective_state`, `pre_stability`, `pre_difficulty`, `post_state`, `post_stability`, `post_difficulty`, `elapsed_days` | Card was graded. |
| `void` | `voids`, `t` | Cancels the `rated` record with `id = voids`. |
| `rename` | `card_id`, `old`, `new`, `t` | Card was renamed. |

- Ignore `rated` records referenced by a `void`.
- Use `pre_effective_state` to distinguish new cards from learning cards.
- Group history by `card_id` (it survives renames). `rename` records are only
  needed to reconstruct past word spelling.
- Deletions are not logged, so past ratings of deleted cards remain.

## Testing and CI

Run `./scripts/check-all.sh` to execute the full CI suite (parentheses,
indentation, byte-compile with warnings as errors, checkdoc, package-lint, and
ERT). Individual scripts live under `scripts/`, and `check-deps.sh` resolves
`fsrs.el` from a local file, cache, or download.

---
summary: Card CRUD operations, batch add, card-back popup, and word resolution shared by review and edit modes
---

# Spec: Deck Operations

## File

`decklet-deck.el` — business logic layer between UI modules and the DB/scheduler.

## Card operations

### Add card

`decklet-add-card(word)` (interactive, autoloaded):
1. Normalize word.
2. Check if card exists and whether it's new.
3. If exists and not new (or `decklet-add-and-refresh` is nil): skip with message.
4. Otherwise: create `decklet-card-meta` with current timestamp, upsert to DB.
5. Prompt for next action (add another, add hint).

`decklet-add-and-refresh` (defcustom, default t): when non-nil, re-adding an
unreviewed word resets its timestamps.

### Rate card

`decklet-rate-card(word, grade)`:
1. Read card row from DB.
2. Convert row to `decklet-card-meta`.
3. Call `decklet--update-card-with-grade` (FSRS scheduling).
4. Write updated meta to DB.
5. Refresh counters.

### Rename word

`decklet-rename-word(old-word, new-word)`:
1. Update word in DB.
2. Update `decklet-current-word` if it matches.
3. Update `decklet-last-added-word` if it matches.
4. Substitute in `decklet-due-words` list.
5. Call `decklet-review--revlog-rename` via `fboundp` guard.
6. Return normalized new word.

### Delete card

`decklet-delete-card(word)`:
1. Delete from DB.
2. Remove from `decklet-due-words`.
3. Call `decklet-review--revlog-delete` via `fboundp` guard.
4. Refresh counters.

### Archive / unarchive

- `decklet-archive-card(word)`: sets `archived_at` timestamp, removes from
  `decklet-due-words`.
- `decklet-unarchive-card(word)`: clears `archived_at`.

### Update hint

`decklet-update-card-hint(word, hint)`: validates card exists, writes hint to DB.

## Batch add

`decklet-add-card-batch` (interactive, autoloaded):
- Opens a buffer in `decklet-add-card-batch-mode` (derived from `text-mode`).
- Lines starting with `#` are hint lines attached to the preceding word.
- `C-c C-c` confirms: parses words and hints, adds each card, calls on-confirm
  callback.
- `C-c C-k` cancels.

Parsing via `decklet--batch-collect-cards`: returns plists with `:word` and
optional `:hint`. Multiple `#` lines are joined with newlines.

## Card-back popup

`decklet-card-back--open(word, read-only-p, callback)`:
- Creates a buffer `*Decklet Card Back: WORD*`.
- Uses `decklet-card-back-buffer-major-mode` (default `org-mode`).
- Two separate minor modes depending on `read-only-p`:

### Read-only view (`decklet-card-back-view-mode`)

Enabled when the popup is opened as read-only (e.g. `b` in review/edit).

| Key | Action |
|---|---|
| `q` | Close window and kill buffer |

### Editable view (`decklet-card-back-edit-mode`)

Enabled when the popup is opened for editing (e.g. `B` in review/edit).

| Key | Action |
|---|---|
| `C-c C-c` | Save card back to DB, close window |
| `C-c C-k` | Cancel and close |

There is no keybinding to switch between the two modes.

All card-back buffers are killed on DB disconnect via
`decklet-db-pre-disconnect-hook`.

## Word resolution

`decklet--resolve-word(word, prompt)`:
- If word is provided, use it directly.
- If region is active, use region text.
- In review mode: use `decklet-current-word`.
- In edit mode: use word at point (tabulated-list ID).
- Otherwise: prompt with word-at-point as default.

## Global state

| Variable | Purpose |
|---|---|
| `decklet-current-word` | Word being reviewed (nil outside review) |
| `decklet-last-added-word` | Most recently added word (for hint follow-up) |
| `decklet-due-words` | List of words due for review |

## Counters

`decklet--refresh-counter` calls `decklet-db--counts` and sets
`decklet--counter` plist:
- `:reviewed` — cards reviewed since day-start
- `:due-review` — review cards due by next day-start
- `:due-learning` — learning cards due by current time
- `:new` — never-reviewed cards

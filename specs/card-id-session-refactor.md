---
summary: Refactor review and edit session state to use stable card_id identity instead of mutable word keys.
---

# Card ID Session Refactor

## Goal

Make `card_id` the internal identity for review and edit session state so that renaming a word becomes an ordinary field update instead of a state migration event.

This refactor should remove most rename-specific synchronization logic from runtime state while preserving user-facing behavior.

## Constraints

- Prefer reading fresh card data from SQLite over caching full card plists.
- Runtime state should keep only `card_id` and the minimum additional data needed for correctness.
- Public and internal mutation hooks should become id-first.
- `decklet-card-renamed-functions` is the main exception: it should carry `(CARD-ID OLD-WORD NEW-WORD)`.
- User-visible messages and logs should still include words where appropriate.
- Historical logs should keep both stable identity and word snapshot when that history matters.

## Non-Goals

- Do not remove words from the database model or UI.
- Do not replace every public API that takes a word in one step.
- Do not introduce a long-lived in-memory card cache for review or edit.
- Do not break existing review-log semantics.

## Current Problems

### Mutable identity in review state

Review state still treats `word` as the live identity:

- `decklet-current-word`
- `decklet-due-words`
- review trail entries with `:word`

As a result, rename has to patch active session state:

- `decklet-deck.el`: `decklet-rename-word` rewrites `decklet-current-word` and `decklet-due-words`
- `decklet-review.el`: `decklet-review--trail-rename` rewrites trail entries

This is fragile because rename is acting as both a field update and an identity migration.

### Mutable identity in edit state

Edit mode also uses `word` as row identity:

- `tabulated-list` entry id is the word
- marks are keyed by word
- overlays are keyed by word
- bulk operations resolve survivors and positions by word

This means rename can invalidate row identity, marks, and selection state even though the underlying card is still the same object.

### Hook payloads are word-first

Most lifecycle hooks currently expose only words, so downstream consumers are encouraged to treat words as object identity.

### DB layer already has stable identity but does not expose it well

The database schema already uses `card_id` as the primary key, and review log already records `card_id`, but most runtime operations still query and mutate by word.

## Design Principles

1. `card_id` is the only stable in-session identity.
2. `word` is a mutable field used for display, prompts, and logs.
3. Read from the DB when current card content is needed.
4. Keep transitional compatibility layers thin and temporary.
5. Migrate review first, then edit, then hooks.
6. Do not duplicate mutable display fields in trail or session state when they can be reloaded by id.

## Target State

### Review state

Replace word-based review session state with id-based state:

- `decklet-current-card-id`
- `decklet-due-card-ids`

Review trail entries should store at least:

```elisp
(:card-id <integer>
 :grade <integer-or-nil>
 :pre-meta <decklet-card-meta>
 :log-id <integer-or-nil>)
```

Notes:

- `:card-id` is the identity.
- When current card content is needed, reload by `card_id`.

### Edit state

Change edit row identity and mark bookkeeping to use `card_id`:

- `tabulated-list` entry id becomes `card_id`
- `decklet-edit--marked` keys become `card_id`
- `decklet-edit--mark-overlays` keys become `card_id`
- survivor lookup and row restoration operate on `card_id`

Displayed columns still show word, hint, and other mutable fields from each row.

### Hooks

Move mutation hooks to id-first payloads.

Target signatures:

- `decklet-card-added-functions`: `(CARD-ID)`
- `decklet-card-deleted-functions`: `(CARD-ID)`
- `decklet-card-archived-functions`: `(CARD-ID)`
- `decklet-card-unarchived-functions`: `(CARD-ID)`
- `decklet-card-field-updated-functions`: `(CARD-ID FIELD)`
- `decklet-card-rated-functions`: `(CARD-ID OLD-META GRADE NEW-META PRIOR-GRADE)`
- `decklet-card-renamed-functions`: `(CARD-ID OLD-WORD NEW-WORD)`

The rename hook remains special because some consumers may need both the stable identity and the before/after surface value.

## Required DB and Deck APIs

### New DB helpers

Add id-based primitives to `decklet-db.el`:

- `decklet-db--select-card-by-id`
- `decklet-db--select-card-word-by-id`
- `decklet-db--delete-card-by-id`
- `decklet-db--archive-card-by-id`
- `decklet-db--unarchive-card-by-id`
- `decklet-db--update-hint-by-id`
- `decklet-db--update-back-by-id`
- `decklet-db--select-due-card-ids`
- `decklet-db--update-word-by-id`

Keep existing word-based helpers temporarily for compatibility and interactive entry points.

### New deck helpers

Add thin wrappers in `decklet-deck.el`:

- `decklet-get-card-by-id`
- `decklet-get-card-meta-by-id`
- `decklet-card-word-by-id`
- `decklet-card-exists-by-id-p`
- `decklet-rate-card-by-id`
- `decklet-delete-card-by-id`
- `decklet-archive-card-by-id`
- `decklet-unarchive-card-by-id`
- `decklet-set-card-hint-by-id`
- `decklet-set-card-back-by-id`
- `decklet-rename-card-by-id`

The word-based APIs can remain as convenience wrappers initially, but internal review/edit code should move to the id-based variants.

## Migration Plan

### Phase 1: Add id-based DB and deck primitives

This phase should not change UI behavior.

Tasks:

- Add DB selectors and mutators that operate by `card_id`
- Add deck-level wrappers
- Add tests for id-based selectors, rename, delete, archive, and field updates

Exit criteria:

- All current word-based behavior still works
- New id-based helpers are available for review/edit migration

### Phase 2: Migrate review session state to card_id

This is the highest-value phase because it removes rename-driven session rewriting.

Tasks:

- Introduce `decklet-current-card-id`
- Introduce `decklet-due-card-ids`
- Change `decklet--refresh-due-words` into an id-based due queue loader
- Update review rendering to load current card by id
- Update skip/undo/rerate trail entries to use `:card-id`
- Change delete/undo handling to check existence by id
- Remove trail rename rewriting
- Remove queue/current-card rewrite logic from rename path

Notes:

- Do not add a persistent review-card cache.
- Rendering can call `decklet-get-card-by-id` or an equivalent single-query helper each time.

Exit criteria:

- Renaming the current review card does not require rewriting current session state
- Renaming a queued card does not require rewriting the due queue
- Undo continues to work after rename and delete

### Phase 3: Migrate edit row identity to card_id

Tasks:

- Change tabulated-list entry id from word to `card_id`
- Replace `decklet-edit--word-at-point` with `decklet-edit--card-id-at-point`
- Resolve display word from row data or DB when needed
- Rekey marks and overlays by `card_id`
- Update bulk delete/archive/survivor logic to use id lists
- Update edit commands to call id-based deck helpers

Notes:

- Any helper whose real purpose is “target current row” should move to id-based naming.
- Any helper that needs the visible word should explicitly load or derive it.

Exit criteria:

- Row selection and marks survive rename naturally
- Bulk operations no longer depend on mutable word identity

### Phase 4: Convert hooks to id-first payloads

Tasks:

- Change internal hook emitters to send id-first payloads
- Update review/edit subscribers to use ids
- Update tests for hook payload shapes

Compatibility options:

- Option A: break and update all internal consumers in one step
- Option B: temporarily emit both legacy and new hooks

Recommended approach:

- Use Option B if any external extension compatibility matters
- Use Option A if this repo is still the only real consumer

### Phase 5: Remove obsolete word-identity glue

Expected deletions after migration:

- queue rewrite inside `decklet-rename-word`
- current-word rewrite inside `decklet-rename-word`
- `decklet-review--trail-rename`
- edit-state assumptions that row id equals word

## Proposed Variable Changes

### New variables

- `decklet-current-card-id`
- `decklet-due-card-ids`

### Transitional compatibility variables

If needed during migration only:

- keep `decklet-current-word` as a derived compatibility layer in selected command paths
- keep `decklet-due-words` only until all internal review logic stops reading it

Recommendation:

- do not try to keep both representations authoritative
- pick one source of truth per phase

## Rendering and Fresh Reads

Review rendering should load the current card by id at render time.

Preferred pattern:

- state stores `card_id`
- render calls one DB/deck helper to fetch `:word`, `:meta`, `:hint`, `:back`
- trail stores only `card_id` plus the minimal undo metadata needed to replay or replace a rating

Avoid:

- a mirrored in-memory plist that multiple mutation paths must keep in sync
- caching fields like word/hint/back across rename/edit/delete flows
- storing `word` in trail entries just for convenience messages

The DB is already local SQLite, so correctness is more important than avoiding a small read.

## Rename Behavior After Refactor

After review/edit migrate to `card_id` identity:

- rename no longer rewrites current session state
- rename no longer rewrites due queue entries
- rename no longer rewrites trail identity
- rename no longer forces edit marks to rekey

What still changes:

- displayed word on next refresh/render
- rename event log
- any consumer that stores sidecar data by word must still respond to rename explicitly

## Testing Strategy

### New tests to add during migration

Review:

- current review card survives rename without state rewrite
- queued due card survives rename without queue rewrite
- undo after rename still resolves the same card by id
- delete removes trail entries by `card_id`

Edit:

- row mark survives rename when row id is `card_id`
- bulk archive/delete uses marked `card_id`s
- survivor lookup and restore still work when visible word changes

Hooks:

- each mutation hook emits the expected id-first payload
- rename hook emits `(CARD-ID OLD-WORD NEW-WORD)`

### Tests likely to simplify

Some tests currently exist only because word-based identity requires synchronization. Those tests should either disappear or become simpler once review/edit stop patching words through live session state.

## Main Risks

1. Partial migration with two sources of truth

If both word-based and id-based state stay writable for too long, the refactor will become more complex than the current design.

2. Hook payload churn

If external consumers exist, id-first hook conversion needs a compatibility story.

3. Edit helper naming confusion

Helpers like `decklet-edit--word-at-point` become misleading once row id is `card_id`.

4. Review command paths still assuming words

Commands that show messages, prompt for rename, or open card back still need the visible word, but they should derive it from `card_id` instead of owning it as session identity.

## Recommended Implementation Order

1. Add id-based DB helpers
2. Add id-based deck helpers
3. Migrate review session state to `card_id`
4. Delete review rename-sync code
5. Migrate edit row identity and mark bookkeeping to `card_id`
6. Convert hooks to id-first payloads
7. Remove obsolete word-based synchronization code

## Expected Payoff

After the refactor:

- rename becomes cheap and local
- review undo state becomes simpler
- edit row identity becomes stable
- lifecycle hooks become more generally useful
- future features can rely on stable identity instead of mutable display text

#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
FSRS_DIR="$(./scripts/check-deps.sh)"

emacs --batch -L "$FSRS_DIR" -L . -L tests \
  -l tests/decklet-test-helpers.el \
  -l tests/decklet-db-test.el \
  -l tests/decklet-review-test.el \
  -l tests/decklet-edit-test.el \
  -l tests/decklet-calendar-test.el \
  -l tests/decklet-import-test.el \
  -l tests/decklet-deck-test.el \
  -l tests/decklet-backup-test.el \
  -l tests/decklet-review-log-test.el \
  -l tests/decklet-scheduler-test.el \
  -f ert-run-tests-batch-and-exit

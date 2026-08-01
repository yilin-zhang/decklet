#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
FSRS_DIR="$(./scripts/check-deps.sh)"

echo "[1/6] Check parentheses"
emacs --batch -Q -l scripts/decklet-check.el -f decklet-check-parens

echo "[2/6] Check indentation"
./scripts/check-indent.sh

echo "[3/6] Byte compile"
emacs --batch -L "$FSRS_DIR" -L . -f batch-byte-compile decklet.el

echo "[4/6] Remove generated .elc"
find . -name '*.elc' -delete

echo "[5/6] Checkdoc"
./scripts/check-checkdoc.sh

echo "[6/6] Package lint + tests"
./scripts/check-package-lint.sh
./scripts/check-ert.sh

echo "All checks passed."

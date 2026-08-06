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
# Compile every source file, not just the entrypoint: `require' loads the
# other files as source, so compiling decklet.el alone never byte-compiles
# them and their warnings go unseen.  `byte-compile-error-on-warn' then makes
# those warnings fail the build — without it `batch-byte-compile' exits 0 and
# CI stays green on real defects (e.g. a macro used before its definition,
# which breaks only once the package is installed and compiled).
emacs --batch -L "$FSRS_DIR" -L . \
      --eval '(setq byte-compile-error-on-warn t)' \
      -f batch-byte-compile decklet*.el

echo "[4/6] Remove generated .elc"
find . -name '*.elc' -delete

echo "[5/6] Checkdoc"
./scripts/check-checkdoc.sh

echo "[6/6] Package lint + tests"
./scripts/check-package-lint.sh
./scripts/check-ert.sh

echo "All checks passed."

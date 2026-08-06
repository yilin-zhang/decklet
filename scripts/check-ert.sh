#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
FSRS_DIR="$(./scripts/check-deps.sh)"

TEST_LOAD_ARGS=()
while IFS= read -r file; do
  TEST_LOAD_ARGS+=(-l "$file")
done < <(git ls-files 'tests/*-test.el')

if [[ ${#TEST_LOAD_ARGS[@]} -eq 0 ]]; then
  echo "Error: no tracked ERT test files found" >&2
  exit 1
fi

emacs --batch -Q -L "$FSRS_DIR" -L . -L tests \
  -l tests/decklet-test-helpers.el \
  "${TEST_LOAD_ARGS[@]}" \
  -f ert-run-tests-batch-and-exit

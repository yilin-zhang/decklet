#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ "${1:-}" == "--fix" ]]; then
  export DECKLET_FIX_INDENT=1
fi

emacs --batch -Q -l scripts/decklet-check.el -f decklet-check-indent

#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

emacs --batch -Q -l scripts/decklet-check.el -f decklet-check-checkdoc

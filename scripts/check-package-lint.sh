#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_LINT_GIT_URL="https://github.com/purcell/package-lint.git"
PACKAGE_LINT_COMMIT="1c37329703a507fa357302cf6fc29d4f2fe631a8"
CACHE_DIR="$REPO_ROOT/scripts/.cache"
PACKAGE_LINT_DIR="$CACHE_DIR/package-lint/$PACKAGE_LINT_COMMIT"
PACKAGE_USER_DIR="$CACHE_DIR/package-lint-elpa"
LOCAL_PACKAGE_LINT_DIR="$REPO_ROOT/package-lint"

if [[ ! -f "$PACKAGE_LINT_DIR/package-lint.el" ]] && \
   command -v git >/dev/null 2>&1; then
  mkdir -p "$PACKAGE_LINT_DIR"
  git init "$PACKAGE_LINT_DIR" >/dev/null 2>&1 || true
  git -C "$PACKAGE_LINT_DIR" remote add origin "$PACKAGE_LINT_GIT_URL" >/dev/null 2>&1 || true
  git -C "$PACKAGE_LINT_DIR" fetch --depth 1 origin "$PACKAGE_LINT_COMMIT" >/dev/null 2>&1 || true
  git -C "$PACKAGE_LINT_DIR" checkout --detach FETCH_HEAD >/dev/null 2>&1 || true
fi

if [[ ! -f "$PACKAGE_LINT_DIR/package-lint.el" ]]; then
  if [[ -d "$LOCAL_PACKAGE_LINT_DIR" ]]; then
    PACKAGE_LINT_DIR="$LOCAL_PACKAGE_LINT_DIR"
  else
    echo "Error: failed to fetch package-lint source and no local fallback exists" >&2
    exit 1
  fi
fi

cd "$REPO_ROOT"
PACKAGE_FILES=()
while IFS= read -r file; do
  PACKAGE_FILES+=("$file")
done < <(git ls-files ':(top,glob)decklet*.el')

if [[ ${#PACKAGE_FILES[@]} -eq 0 ]]; then
  echo "Error: no tracked Decklet package files found" >&2
  exit 1
fi

# package-lint initializes package.el internally.  Keep that initialization
# in a persistent, isolated cache so later checks can also run offline.
mkdir -p "$PACKAGE_USER_DIR"
DECKLET_PACKAGE_USER_DIR="$PACKAGE_USER_DIR" \
emacs --batch -Q \
  --eval '(setq package-user-dir (getenv "DECKLET_PACKAGE_USER_DIR"))' \
  -L . \
  -L "$PACKAGE_LINT_DIR" \
  -l "$PACKAGE_LINT_DIR/package-lint.el" \
  -l scripts/decklet-check.el \
  -f decklet-check-configure-package-lint \
  -f package-lint-batch-and-exit \
  "${PACKAGE_FILES[@]}"

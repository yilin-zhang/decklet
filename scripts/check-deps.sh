#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="$REPO_ROOT/scripts/.cache"
FSRS_BRANCH="fix/learning-relearning-again-stability"
CACHE_FSRS_DIR="$CACHE_DIR/fsrs/${FSRS_BRANCH//\//-}"
CACHE_FSRS="$CACHE_FSRS_DIR/fsrs.el"
LOCAL_FSRS="$REPO_ROOT/fsrs.el"

if [[ -f "$LOCAL_FSRS" ]]; then
  printf '%s\n' "$REPO_ROOT"
  exit 0
fi

if [[ -s "$CACHE_FSRS" ]]; then
  printf '%s\n' "$CACHE_FSRS_DIR"
  exit 0
fi

mkdir -p "$CACHE_FSRS_DIR"
FSRS_URLS=(
  "https://raw.githubusercontent.com/yilin-zhang/lisp-fsrs/refs/heads/$FSRS_BRANCH/fsrs.el"
)

for url in "${FSRS_URLS[@]}"; do
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$CACHE_FSRS" 2>/dev/null || true
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$CACHE_FSRS" "$url" 2>/dev/null || true
  fi

  if [[ -s "$CACHE_FSRS" ]]; then
    printf '%s\n' "$CACHE_FSRS_DIR"
    exit 0
  fi
done

echo "Error: unable to resolve fsrs.el (missing local file and download failed)" >&2
exit 1

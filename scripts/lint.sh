#!/usr/bin/env bash
# Lint (default) or format (--fix) Relay's Swift sources with the swift-format bundled in the
# active Xcode toolchain. Config: .swift-format at the repo root.
#
#   scripts/lint.sh            report findings (exit 0 even with findings)
#   scripts/lint.sh --strict   findings are errors (exit 1) — what CI runs
#   scripts/lint.sh --fix      rewrite files in place
set -euo pipefail
cd "$(dirname "$0")/.."

mode="lint"
strict=()
for arg in "$@"; do
  case "$arg" in
    --fix) mode="format" ;;
    --strict) strict=(--strict) ;;
    *)
      echo "usage: scripts/lint.sh [--fix] [--strict]" >&2
      exit 2
      ;;
  esac
done

if ! xcrun --find swift-format >/dev/null 2>&1; then
  echo "error: swift-format not found in the active Xcode toolchain (Xcode 16+ required; check: xcode-select -p)" >&2
  exit 1
fi

paths=()
for p in Relay RelayHook RelayTests RelayUITests; do
  if [[ -d "$p" ]]; then
    paths+=("$p")
  fi
done

if [[ "$mode" == "format" ]]; then
  xcrun swift-format format --in-place --recursive --parallel "${paths[@]}"
else
  xcrun swift-format lint --recursive --parallel ${strict[@]+"${strict[@]}"} "${paths[@]}"
fi

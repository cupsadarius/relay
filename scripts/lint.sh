#!/usr/bin/env bash
# Lint (default) or format (--fix) Relay's Swift sources with the swift-format bundled in the
# active Xcode toolchain. Config: .swift-format at the repo root.
#
#   scripts/lint.sh            report findings (exit 0 even with findings)
#   scripts/lint.sh --strict   findings are errors (exit 1) — what CI runs
#   scripts/lint.sh --fix      rewrite files in place
#
# Exit codes: 0 clean (or findings without --strict), 1 findings under --strict OR a swift-format
# parse/I-O error (e.g. a file it can't read) — either way this script's exit code is whatever
# swift-format returned, so a real tooling failure is never mistaken for "no findings". 2 bad
# usage (unknown flag, or --fix combined with --strict).
set -euo pipefail
cd "$(dirname "$0")/.."

mode="lint"
fix_requested=0
strict_requested=0
strict=()
for arg in "$@"; do
  case "$arg" in
    --fix) mode="format"; fix_requested=1 ;;
    --strict) strict=(--strict); strict_requested=1 ;;
    *)
      echo "usage: scripts/lint.sh [--fix] [--strict]" >&2
      exit 2
      ;;
  esac
done

if [[ "$fix_requested" -eq 1 && "$strict_requested" -eq 1 ]]; then
  echo "usage: --fix and --strict are mutually exclusive (--fix rewrites files; --strict only changes lint's exit code)" >&2
  exit 2
fi

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

if [[ ${#paths[@]} -eq 0 ]]; then
  echo "error: none of Relay, RelayHook, RelayTests, RelayUITests exist here; run scripts/lint.sh from the repo root" >&2
  exit 1
fi

if [[ "$mode" == "format" ]]; then
  xcrun swift-format format --in-place --recursive --parallel "${paths[@]}"
else
  xcrun swift-format lint --recursive --parallel ${strict[@]+"${strict[@]}"} "${paths[@]}"
fi

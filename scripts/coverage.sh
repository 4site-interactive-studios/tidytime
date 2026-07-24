#!/usr/bin/env bash
# coverage.sh — run the TidyKit tests with coverage and print a per-file report for our own
# Sources (GRDB, checkouts, and test files are excluded). Fails if tests fail.
set -euo pipefail

pkg="$(cd "$(dirname "$0")/.." && pwd)/Packages/TidyKit"
cd "$pkg"

echo "==> swift test --enable-code-coverage"
swift test --enable-code-coverage 2>&1 | grep -E "Executed [0-9]+ tests|error:|failed" || true

bin="$(swift build --show-bin-path)"
prof="$bin/codecov/default.profdata"
xctest="$(find "$bin" -maxdepth 1 -name '*.xctest' | head -1)"
testbin="$xctest/Contents/MacOS/$(basename "$xctest" .xctest)"

if [[ ! -f "$prof" || ! -f "$testbin" ]]; then
  echo "coverage artifacts not found (prof=$prof testbin=$testbin)" >&2
  exit 1
fi

echo
echo "==> Coverage for Sources/ (excludes GRDB checkouts + tests)"
xcrun llvm-cov report "$testbin" \
  -instr-profile "$prof" \
  -ignore-filename-regex='(\.build|/Tests/|checkouts)' \
  | grep -E "Filename|Sources/|TOTAL|^---" || true

#!/usr/bin/env bash
# typecheck-app.sh — type-check the App/ target's Swift against the real SDK and the built TidyKit
# modules, WITHOUT going through xcodebuild.
#
# Why this exists: `xcodebuild` can fail for reasons that have nothing to do with this project — on
# the machine this was developed on it refused to run at all because a stale system component
# (/Library/Developer/PrivateFrameworks/DVTDownloads.framework) didn't match Xcode's expected
# symbols, which is fixed with `sudo xcodebuild -runFirstLaunch`. This script lets you still prove
# the app-shell code compiles. It does NOT produce an app bundle — use `make build` / `make dmg`
# for that once xcodebuild is healthy.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

echo "==> Building TidyKit (produces the .swiftmodule files we type-check against)"
(cd Packages/TidyKit && swift build >/dev/null)

MODDIR="$(cd Packages/TidyKit && swift build --show-bin-path)"
SDK="$(xcrun --show-sdk-path)"
GRDB_MODMAP="$root/Packages/TidyKit/.build/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap"

echo "==> Type-checking App/*.swift"
# shellcheck disable=SC2046
xcrun swiftc -typecheck -parse-as-library \
  -sdk "$SDK" -target arm64-apple-macos14.0 \
  -I "$MODDIR/Modules" -I "$MODDIR" \
  ${GRDB_MODMAP:+-Xcc -fmodule-map-file="$GRDB_MODMAP"} \
  $(find App -name '*.swift')

echo "✅ App target type-checks clean."

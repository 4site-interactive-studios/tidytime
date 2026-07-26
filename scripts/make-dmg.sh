#!/usr/bin/env bash
# make-dmg.sh — build TidyTime in Release and package it as a distributable .dmg.
#
# Prerequisites: `Local.xcconfig` with your DEVELOPMENT_TEAM (a free Apple ID "Personal Team" is
# enough). The signature must be STABLE or macOS silently revokes Accessibility/Automation grants
# on every rebuild — guardrail G7, see docs/build/signing-and-tcc.md.
#
# The result is NOT notarized (that needs a paid Apple Developer account), so on first launch macOS
# will refuse it with "unidentified developer". Right-click the app → Open (once), or:
#   xattr -d com.apple.quarantine /Applications/TidyTime.app
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

CONFIG="${CONFIG:-Release}"
DERIVED="$root/.build/dd-dmg"
DIST="$root/dist"
APP_NAME="TidyTime"
VOL_NAME="$APP_NAME"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

SIGNED=1
if [[ ! -f "$root/Local.xcconfig" ]]; then
  if [[ "${ALLOW_UNSIGNED:-0}" == "1" ]]; then
    SIGNED=0
    APP_NAME="TidyTime"          # same product name; the dmg is renamed below
    cat >&2 <<'WARN'
============================ UNSIGNED PREVIEW BUILD ============================
Local.xcconfig is missing, and ALLOW_UNSIGNED=1 was set, so this builds WITHOUT a
stable signing identity.

Use this ONLY to look at the app. Do NOT rely on it day to day:
macOS ties Accessibility/Automation grants to the code signature, so every
rebuild silently REVOKES whatever you granted (guardrail G7) — the app will
appear to "randomly stop working".

For a build you can actually live with:
  cp Local.xcconfig.example Local.xcconfig   # then set DEVELOPMENT_TEAM
  make dmg
================================================================================
WARN
  else
    echo "error: Local.xcconfig not found." >&2
    echo "       cp Local.xcconfig.example Local.xcconfig  and set DEVELOPMENT_TEAM." >&2
    echo "       Without a stable signing identity, TCC grants are revoked on each rebuild (G7)." >&2
    echo "       To build an unsigned PREVIEW anyway:  ALLOW_UNSIGNED=1 make dmg" >&2
    exit 1
  fi
fi

echo "==> Regenerating the Xcode project"
command -v xcodegen >/dev/null 2>&1 || { echo "error: xcodegen not installed (run: make bootstrap)" >&2; exit 1; }
xcodegen generate

echo "==> Building $APP_NAME ($CONFIG)"
if [[ "$SIGNED" == "1" ]]; then
  xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" build
else
  xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build
fi

APP="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "error: built app not found at $APP" >&2; exit 1; }

echo "==> Verifying the signature (stability matters more than validity here)"
codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^\(Authority\|TeamIdentifier\|Identifier\)/  &/p' || true

echo "==> Staging"
mkdir -p "$DIST"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating the disk image"
DMG_NAME="$APP_NAME"
[[ "$SIGNED" == "1" ]] || DMG_NAME="$APP_NAME-UNSIGNED-PREVIEW"
rm -f "$DIST/$DMG_NAME.dmg"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$DMG_NAME.dmg" >/dev/null

echo
echo "Done: $DIST/$DMG_NAME.dmg"
echo
if [[ "$SIGNED" == "1" ]]; then
  echo "Install:  open the dmg, drag $APP_NAME to Applications."
else
  echo "UNSIGNED PREVIEW — look at it, but don't grant permissions and rely on them (G7)."
fi
echo "First launch is blocked by Gatekeeper (unnotarized): right-click the app -> Open, or run"
echo "  xattr -d com.apple.quarantine /Applications/$APP_NAME.app"
echo "Then grant Accessibility + Automation — see docs/permissions-setup.md."

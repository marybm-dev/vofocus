#!/usr/bin/env bash
# Gives the installed runner app an icon and the name "VOFocus Runner".
#
# The app on the device or Simulator, VOFocusRunner-Runner.app, is Xcode's generic
# XCTRunner app copied for the VOFocusRunner test bundle, and Xcode has no setting for
# its icon or name. So after build-for-testing this compiles Icons/Runner.xcassets into
# a copy of it, sets the display name, re-signs the copy with the identity Xcode used,
# and swaps it in. It's cosmetic: if any step fails, the app stays as Xcode built it.
#
#   scripts/brand-runner.sh <path to VOFocusRunner-Runner.app> <iphoneos|iphonesimulator>
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?path to VOFocusRunner-Runner.app required}"
PLATFORM="${2:?iphoneos or iphonesimulator required}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

COPY="$WORK/VOFocusRunner-Runner.app"
cp -R "$APP" "$COPY"
PLIST="$COPY/Info.plist"

xcrun actool Icons/Runner.xcassets --compile "$COPY" --platform "$PLATFORM" \
  --minimum-deployment-target 27.0 --target-device iphone --app-icon AppIcon \
  --output-partial-info-plist "$WORK/icon.plist" > /dev/null

# Replace rather than merge, so running this again on a patched app works.
for key in CFBundleIcons 'CFBundleIcons~ipad' CFBundleDisplayName; do
  /usr/libexec/PlistBuddy -c "Delete :$key" "$PLIST" 2> /dev/null || true
done
/usr/libexec/PlistBuddy -c "Merge $WORK/icon.plist" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string VOFocus Runner" "$PLIST"

# Sign with the certificate Xcode signed with (by its SHA-1, so two certificates with
# the same name can't be confused), or ad hoc if Xcode signed ad hoc (Simulator).
IDENTITY="-"
if codesign -d --extract-certificates="$WORK/cert" "$APP" 2> /dev/null && [[ -f "$WORK/cert0" ]]; then
  IDENTITY=$(openssl x509 -inform DER -in "$WORK/cert0" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
fi
codesign --force --sign "$IDENTITY" --preserve-metadata=identifier,entitlements,flags \
  --generate-entitlement-der "$COPY" 2> /dev/null
codesign --verify --strict "$COPY"

rm -rf "$APP"
mv "$COPY" "$APP"

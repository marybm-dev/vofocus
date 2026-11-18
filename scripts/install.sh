#!/usr/bin/env bash
# Builds vofocus and vofocus-mcp and installs them with the runner's files:
#
#   <prefix>/bin/vofocus, <prefix>/bin/vofocus-mcp
#   <prefix>/share/vofocus/   the Xcode project, Runner/ and the scripts that build and
#                             start the runner (read-only; builds go to
#                             ~/Library/Caches/vofocus)
#
# The Homebrew formula runs this, so it's also how to try an install locally:
#
#   scripts/install.sh /tmp/vofocus-prefix
#   /tmp/vofocus-prefix/bin/vofocus --version
#
# Needs Xcode 27 and XcodeGen (to generate the project once, here, so installs don't
# need XcodeGen). SWIFT_BUILD_FLAGS adds swift build flags (Homebrew passes
# --disable-sandbox).
set -euo pipefail
cd "$(dirname "$0")/.."

PREFIX="${1:?install prefix required, such as /opt/homebrew/opt/vofocus}"
SHARE="$PREFIX/share/vofocus"

# shellcheck disable=SC2086 # SWIFT_BUILD_FLAGS is a list of flags.
swift build -c release --package-path Host ${SWIFT_BUILD_FLAGS:-}
BIN_DIR=$(swift build -c release --package-path Host --show-bin-path ${SWIFT_BUILD_FLAGS:-})

command -v xcodegen > /dev/null || { echo "Install XcodeGen first: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet

mkdir -p "$PREFIX/bin" "$SHARE/Config" "$SHARE/scripts"
install -m 755 "$BIN_DIR/vofocus" "$BIN_DIR/vofocus-mcp" "$PREFIX/bin/"

# Everything the VOFocusRunner scheme needs, plus the demo app and spike targets the
# project also references. Never Config/Local.xcconfig: it holds the developer's own
# signing settings (installed users have `vofocus setup` instead).
for item in project.yml VOFocus.xcodeproj Runner DemoApp SpikeUITests Icons LICENSE NOTICE; do
  rm -rf "${SHARE:?}/$item"
  cp -R "$item" "$SHARE/"
done
install -m 644 Config/Project.xcconfig "$SHARE/Config/"
install -m 755 scripts/runner.sh scripts/brand-runner.sh "$SHARE/scripts/"
install -m 644 scripts/lib.sh "$SHARE/scripts/"
# User state Xcode may have left in the generated project.
rm -rf "$SHARE/VOFocus.xcodeproj/xcuserdata" "$SHARE/VOFocus.xcodeproj/project.xcworkspace/xcuserdata"

echo "Installed vofocus $("$PREFIX/bin/vofocus" --version) to $PREFIX"

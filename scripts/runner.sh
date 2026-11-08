#!/usr/bin/env bash
# Builds and starts the VOFocus runner. It serves HTTP on localhost:$PORT until it
# receives POST /shutdown (or this script is stopped).
#
#   scripts/runner.sh                     # iOS 27 Simulator (iPhone 18 Pro), port 8740
#   PORT=9000 SIM_NAME="iPhone Air" scripts/runner.sh
#
# Physical devices aren't supported yet: the Mac can't reach the device's port
# without USB port forwarding, which is next on the list.
set -euo pipefail
cd "$(dirname "$0")/.."

. scripts/lib.sh
PORT="${PORT:-8740}"
DESTINATION=$(sim_destination)
UDID=${DESTINATION##*id=}
DERIVED="build/DerivedData"

mkdir -p build
xcodegen generate --quiet

# VoiceOver can get stuck in a state only a Simulator restart clears (see
# Runner.startSession), so start every runner on a freshly booted Simulator.
# FRESH_SIM=0 skips this.
if [[ "${FRESH_SIM:-1}" == "1" ]]; then
  echo "Restarting Simulator $SIM_NAME ($UDID)..."
  xcrun simctl shutdown "$UDID" 2>/dev/null || true
  xcrun simctl boot "$UDID"
  xcrun simctl bootstatus "$UDID" -b > /dev/null
fi
echo "Building runner..."
xcodebuild build-for-testing -project VOFocus.xcodeproj -scheme VOFocusRunner \
  -destination "$DESTINATION" -derivedDataPath "$DERIVED" -quiet

echo "Starting runner on port $PORT (log: build/runner.log)"
# TEST_RUNNER_-prefixed variables are passed to the test process without the prefix.
TEST_RUNNER_VOFOCUS_PORT="$PORT" xcodebuild test-without-building \
  -project VOFocus.xcodeproj -scheme VOFocusRunner \
  -destination "$DESTINATION" -derivedDataPath "$DERIVED" \
  -only-testing:VOFocusRunner/RunnerTests/testRunServer 2>&1 \
  | tee build/runner.log | grep --line-buffered -E "VOFOCUS|error:"

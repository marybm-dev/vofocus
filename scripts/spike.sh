#!/usr/bin/env bash
# Runs the XCUIVoiceOverService feasibility spike and prints what VoiceOver said.
#
#   scripts/spike.sh                      # iOS 27 Simulator (default)
#   scripts/spike.sh --device "<name>"    # physical device (needs Config/Local.xcconfig)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPER_DIR:=/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR
SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"

if [[ "${1:-}" == "--device" ]]; then
  DESTINATION="platform=iOS,name=${2:?device name required}"
else
  DESTINATION="platform=iOS Simulator,name=${SIM_NAME},OS=27.0"
fi

xcodegen generate --quiet
RESULT="build/spike-$(date +%Y%m%d-%H%M%S).xcresult"
mkdir -p build

set +e
xcodebuild test \
  -project VOFocus.xcodeproj -scheme DemoApp \
  -destination "$DESTINATION" \
  -only-testing:SpikeUITests \
  -resultBundlePath "$RESULT" 2>&1 | tee build/spike.log | grep -E "VOSPIKE|Test Case .*(passed|failed)|error:"
STATUS=${PIPESTATUS[0]}
set -e

echo
echo "Full log: build/spike.log"
echo "Result bundle: $RESULT"
exit "$STATUS"

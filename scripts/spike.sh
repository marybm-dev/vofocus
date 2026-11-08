#!/usr/bin/env bash
# Runs the XCUIVoiceOverService feasibility spike and prints what VoiceOver said.
#
#   scripts/spike.sh                          # iOS 27 Simulator (default: iPhone 18 Pro)
#   scripts/spike.sh --device "<name or UDID>"  # physical device (needs Config/Local.xcconfig)
set -euo pipefail
cd "$(dirname "$0")/.."

. scripts/lib.sh

if [[ "${1:-}" == "--device" ]]; then
  DESTINATION=$(device_destination "${2:?device name or UDID required}")
else
  DESTINATION=$(sim_destination)
fi

xcodegen generate --quiet
RESULT="build/spike-$(date +%Y%m%d-%H%M%S).xcresult"
mkdir -p build

set +e
xcodebuild test \
  -project VOFocus.xcodeproj -scheme DemoApp \
  -destination "$DESTINATION" -allowProvisioningUpdates \
  -only-testing:SpikeUITests \
  -resultBundlePath "$RESULT" 2>&1 | tee build/spike.log | grep -E "VOSPIKE|Test Case .*(passed|failed)|error:"
STATUS=${PIPESTATUS[0]}
set -e

echo
echo "Full log: build/spike.log"
echo "Result bundle: $RESULT"
exit "$STATUS"

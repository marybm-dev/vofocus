#!/usr/bin/env bash
# Builds the demo app and runs vofocus with DEMO_BUNDLE_ID and DEMO_APP set, so the
# scenarios in scenarios/demo can find it.
#
#   scripts/demo.sh run scenarios/demo
#   scripts/demo.sh run scenarios/demo --device <UDID or name>
#   scripts/demo.sh record scenarios/demo/static-order.yml --write
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

DEVICE=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[$i]}" == "--device" ]] && DEVICE="${args[$((i + 1))]:-}"
done

generate_project
if [[ -n "$DEVICE" ]]; then
  DESTINATION=$(device_destination "$DEVICE")
  PRODUCTS="build/DerivedData-device/Build/Products/Debug-iphoneos"
  DERIVED="build/DerivedData-device"
else
  DESTINATION=$(sim_destination)
  PRODUCTS="build/DerivedData/Build/Products/Debug-iphonesimulator"
  DERIVED="build/DerivedData"
fi
echo "Building the demo app..." >&2
xcodebuild build -project VOFocus.xcodeproj -scheme DemoApp -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" -allowProvisioningUpdates -quiet ${SIGNING_ARGS[@]+"${SIGNING_ARGS[@]}"} >&2

# The bundle prefix from Config/Project.xcconfig, overridden by Config/Local.xcconfig and
# then by `vofocus setup`'s signing.xcconfig when they exist (they don't on CI machines).
PREFIX=""
for config in Config/Project.xcconfig Config/Local.xcconfig "$SIGNING_CONFIG"; do
  [[ -f "$config" ]] || continue
  value=$(sed -n 's/^VOFOCUS_BUNDLE_PREFIX *= *//p' "$config")
  [[ -n "$value" ]] && PREFIX="$value"
done
export DEMO_BUNDLE_ID="$PREFIX.DemoApp"
export DEMO_APP="$PWD/$PRODUCTS/DemoApp.app"

swift build -c release --package-path Host --product vofocus > /dev/null
exec Host/.build/release/vofocus "$@"

#!/usr/bin/env bash
# Builds and starts the VOFocus runner. It serves HTTP on localhost:$PORT until it
# receives POST /shutdown (or this script is stopped).
#
# Every request needs the header "Authorization: Bearer <token>". Each run makes a new
# token and saves it to $VOFOCUS_BUILD_DIR/runner-$PORT.token (readable only by you);
# set VOFOCUS_TOKEN to choose one instead.
#
# Stop it with POST /shutdown (or Ctrl-C, a kill or a hangup to this script, which send
# it), so the runner turns VoiceOver off. Killing xcodebuild directly leaves VoiceOver on.
#
# VOFOCUS_BRAND=0 skips giving the runner app its icon and name, which re-signs it.
#
# VOFOCUS_BUILD_DIR is where the build, logs and tokens go: build/ in a checkout by
# default. An installed vofocus sets it to ~/Library/Caches/vofocus, since the
# installed files are read-only.
#
#   scripts/runner.sh                       # iOS 27 Simulator (iPhone 18 Pro), port 8740
#   PORT=9000 SIM_NAME="iPhone Air" scripts/runner.sh
#   scripts/runner.sh --device <UDID or name>  # a connected device
#
# On a device, the runner is reached over the CoreDevice tunnel (the encrypted link
# Xcode keeps with a paired device, over the cable or Wi-Fi), and listens on that
# address only; the script prints it. The device must be unlocked with Settings > Developer > Enable
# UI Automation turned on.
set -euo pipefail
cd "$(dirname "$0")/.."

. scripts/lib.sh
PORT="${PORT:-8740}"
DEVICE=""
if [[ "${1:-}" == "--device" ]]; then
  DEVICE="${2:?device name or UDID required}"
fi

BUILD="${VOFOCUS_BUILD_DIR:-$PWD/build}"
mkdir -p "$BUILD"
generate_project

if [[ -n "$DEVICE" ]]; then
  DESTINATION=$(device_destination "$DEVICE")
  DERIVED="$BUILD/DerivedData-device"
  BASE_URL=$(device_base_url "$DEVICE")
else
  DESTINATION=$(sim_destination)
  UDID=${DESTINATION##*id=}
  DERIVED="$BUILD/DerivedData"
  BASE_URL="http://localhost:$PORT"
fi

# VoiceOver can get stuck in a state only a Simulator restart clears on iOS 27.0 (see
# Runner.startSession), so start every Simulator runner on a freshly booted
# Simulator. FRESH_SIM=0 skips this.
if [[ -z "$DEVICE" && "${FRESH_SIM:-1}" == "1" ]]; then
  echo "Restarting Simulator $SIM_NAME ($UDID)..."
  xcrun simctl shutdown "$UDID" 2>/dev/null || true
  xcrun simctl boot "$UDID"
  xcrun simctl bootstatus "$UDID" -b > /dev/null
fi
echo "Building runner..."
xcodebuild build-for-testing -project VOFocus.xcodeproj -scheme VOFocusRunner \
  -destination "$DESTINATION" -derivedDataPath "$DERIVED" -allowProvisioningUpdates -quiet \
  ${SIGNING_ARGS[@]+"${SIGNING_ARGS[@]}"}

# Cosmetic: the runner app's home screen icon and name. This re-signs the app Xcode
# built (see brand-runner.sh); VOFOCUS_BRAND=0 skips it and leaves Xcode's app as is.
PLATFORM=$([[ -n "$DEVICE" ]] && echo iphoneos || echo iphonesimulator)
if [[ "${VOFOCUS_BRAND:-1}" != "0" ]]; then
  scripts/brand-runner.sh "$DERIVED/Build/Products/Debug-$PLATFORM/VOFocusRunner-Runner.app" "$PLATFORM" \
    || echo "Couldn't add the runner's icon; starting it without one." >&2
fi

TOKEN="${VOFOCUS_TOKEN:-$(openssl rand -hex 32)}"
TOKEN_FILE="$BUILD/runner-$PORT.token"
(umask 077 && printf '%s' "$TOKEN" > "$TOKEN_FILE")

# Keep the previous run's log: when a runner dies (for example exit 65 mid-request),
# the reason is in its log, and the next start would otherwise overwrite it.
[[ -f "$BUILD/runner.log" ]] && mv "$BUILD/runner.log" "$BUILD/runner.previous.log"

echo "Starting runner at $BASE_URL (token: $TOKEN_FILE, log: $BUILD/runner.log)"
# TEST_RUNNER_-prefixed variables are passed to the test process without the prefix.
LISTEN_ADDRESS=""
if [[ -n "$DEVICE" ]]; then
  LISTEN_ADDRESS=${BASE_URL#http://[}
  LISTEN_ADDRESS=${LISTEN_ADDRESS%%]*}
fi
# Run the runner as a background job, which job control puts in its own process
# group: Ctrl-C in a terminal then reaches only this script, not xcodebuild, so the
# script can stop the runner properly (below).
set -m
TEST_RUNNER_VOFOCUS_PORT="$PORT" TEST_RUNNER_VOFOCUS_TOKEN="$TOKEN" \
  TEST_RUNNER_VOFOCUS_LISTEN_ADDRESS="$LISTEN_ADDRESS" xcodebuild test-without-building \
  -project VOFocus.xcodeproj -scheme VOFocusRunner \
  -destination "$DESTINATION" -derivedDataPath "$DERIVED" \
  -only-testing:VOFocusRunner/RunnerTests/testRunServer 2>&1 \
  | tee "$BUILD/runner.log" | grep --line-buffered -E "VOFOCUS|error:" &

# On Ctrl-C, a kill or a hangup, ask the runner to shut down: it turns VoiceOver off as
# it stops. Killing it instead would leave VoiceOver on, and on a device only the
# runner can turn it off. If it hasn't exited after 30 s, stop it anyway.
stop_runner() {
  trap - INT TERM HUP
  if jobs %1 > /dev/null 2>&1; then
    echo "Stopping the runner (turning VoiceOver off)..." >&2
    curl -s -m 10 -X POST -H "Authorization: Bearer $TOKEN" "$BASE_URL/shutdown" > /dev/null || true
    for _ in $(seq 60); do
      jobs %1 > /dev/null 2>&1 || return 0
      [[ -z "$(jobs -r %1 2> /dev/null)" ]] && return 0
      sleep 0.5
    done
    kill %1 2> /dev/null || true
  fi
}
trap 'stop_runner; exit 130' INT
trap 'stop_runner; exit 143' TERM HUP
wait %1

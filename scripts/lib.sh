# Shared helpers for the VOFocus scripts. Source it: . "$(dirname "$0")/lib.sh"
#
# Settings (environment):
#   DEVELOPER_DIR  Xcode to use (default: the one xcode-select points to)
#   SIM_NAME       Simulator name (default "iPhone 18 Pro"); the newest iOS 27 runtime
#                  that has a Simulator with this name is used

SIM_NAME="${SIM_NAME:-iPhone 18 Pro}"

# Prints the UDID of SIM_NAME on the newest available iOS 27 runtime.
sim_udid() {
  xcrun simctl list devices available -j | jq -r --arg n "$SIM_NAME" '
    .devices | to_entries
    | map(select(.key | test("SimRuntime\\.iOS-27")))
    | sort_by(.key | capture("iOS-(?<v>[0-9-]+)").v | split("-") | map(tonumber? // 0)) | reverse
    | map(.value[] | select(.name == $n) | .udid) | first // empty'
}

# Prints an xcodebuild -destination for the Simulator, or exits with a message.
sim_destination() {
  local udid
  udid=$(sim_udid)
  if [[ -z "$udid" ]]; then
    echo "No available iOS 27 Simulator named \"$SIM_NAME\". Set SIM_NAME to one of:" >&2
    xcrun simctl list devices available | grep -E "iPhone" | sed 's/^/  /' >&2
    exit 1
  fi
  echo "platform=iOS Simulator,id=$udid"
}

# Prints an xcodebuild -destination for a physical device given its name or UDID.
device_destination() {
  if [[ "$1" =~ ^[0-9A-Fa-f-]{20,}$ ]]; then
    echo "platform=iOS,id=$1"
  else
    echo "platform=iOS,name=$1"
  fi
}

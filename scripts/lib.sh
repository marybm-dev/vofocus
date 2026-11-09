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

# Prints the CoreDevice tunnel address of a connected device (name or UDID). The Mac
# reaches the runner on the device at http://[address]:PORT over the cable.
device_tunnel_ip() {
  local json
  json=$(mktemp -t vofocus-device)
  if ! xcrun devicectl device info details --device "$1" --json-output "$json" > /dev/null 2>&1; then
    rm -f "$json"
    echo "Can't reach device \"$1\". Is it connected, unlocked and trusted?" >&2
    return 1
  fi
  jq -r '.result.connectionProperties.tunnelIPAddress // empty' "$json"
  rm -f "$json"
}

# Prints the runner's base URL for a device.
device_base_url() {
  local ip
  ip=$(device_tunnel_ip "$1") || return 1
  [[ -n "$ip" ]] || { echo "Device \"$1\" has no tunnel address yet." >&2; return 1; }
  echo "http://[$ip]:${PORT:-8740}"
}

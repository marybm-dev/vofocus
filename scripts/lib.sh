# Shared helpers for the VOFocus scripts. Source it: . "$(dirname "$0")/lib.sh"
#
# Settings (environment):
#   DEVELOPER_DIR  Xcode to use (default: the one xcode-select points to)
#   SIM_NAME       Simulator name (default "iPhone 18 Pro"); the newest iOS 27 runtime
#                  that has a Simulator with this name is used

SIM_NAME="${SIM_NAME:-iPhone 18 Pro}"

# Device signing saved by `vofocus setup`, passed to xcodebuild when it exists. It wins
# over Config/Local.xcconfig, which is for working in a checkout.
SIGNING_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/vofocus/signing.xcconfig"
SIGNING_ARGS=()
[[ -f "$SIGNING_CONFIG" ]] && SIGNING_ARGS=(-xcconfig "$SIGNING_CONFIG")

# Generates VOFocus.xcodeproj from project.yml in a git checkout, where the sources
# change. An installed copy comes with the project generated and needs no XcodeGen.
generate_project() {
  [[ -d .git || ! -d VOFocus.xcodeproj ]] || return 0
  if ! command -v xcodegen > /dev/null; then
    echo "XcodeGen generates the Xcode project; install it with: brew install xcodegen" >&2
    return 1
  fi
  xcodegen generate --quiet
}

# Prints the UDID of SIM_NAME on the newest available iOS 27 runtime. Reads simctl's
# text listing ("-- iOS 27.2 --" headers, "    iPhone 18 Pro (UDID) (Shutdown)" rows)
# so the scripts need nothing beyond what macOS and Xcode provide.
sim_udid() {
  xcrun simctl list devices available | awk -v name="$SIM_NAME" '
    /^-- iOS 27/ { split($3, v, "."); version = v[1] * 10000 + v[2] * 100 + v[3]; ios27 = 1; next }
    /^-- / { ios27 = 0; next }
    ios27 {
      row = $0
      sub(/^ +/, "", row)
      if (index(row, name " (") == 1 && version > best) {
        best = version
        udid = substr(row, length(name) + 3, 36)
      }
    }
    END { print udid }'
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
  plutil -extract result.connectionProperties.tunnelIPAddress raw -o - "$json" 2>/dev/null || true
  rm -f "$json"
}

# Prints the runner's base URL for a device.
device_base_url() {
  local ip
  ip=$(device_tunnel_ip "$1") || return 1
  [[ -n "$ip" ]] || { echo "Device \"$1\" has no tunnel address yet." >&2; return 1; }
  echo "http://[$ip]:${PORT:-8740}"
}

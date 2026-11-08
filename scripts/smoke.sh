#!/usr/bin/env bash
# Repeats the spike's checks through a running runner's HTTP API, against the demo app.
#
#   scripts/runner.sh &          # in another terminal, or in the background
#   scripts/smoke.sh
set -euo pipefail
cd "$(dirname "$0")/.."

. scripts/lib.sh
PORT="${PORT:-8740}"
DESTINATION=$(sim_destination)
UDID=${DESTINATION##*id=}
BASE="http://localhost:$PORT"

PREFIX=$(grep -h "^VOFOCUS_BUNDLE_PREFIX" Config/Project.xcconfig Config/Local.xcconfig 2>/dev/null \
  | tail -1 | sed 's/.*= *//')
BUNDLE_ID="${BUNDLE_ID:-$PREFIX.DemoApp}"

echo "== Installing demo app ($BUNDLE_ID)"
xcodebuild build -project VOFocus.xcodeproj -scheme DemoApp \
  -destination "$DESTINATION" \
  -derivedDataPath build/DerivedData -quiet
xcrun simctl install "$UDID" build/DerivedData/Build/Products/Debug-iphonesimulator/DemoApp.app

FAILURES=0
call() {  # call METHOD PATH [JSON]
  curl -sS -X "$1" "$BASE$2" -H 'Content-Type: application/json' ${3:+-d "$3"}
}
check() {  # check DESCRIPTION JSON JQ_FILTER
  if echo "$2" | jq -e "$3" > /dev/null 2>&1; then
    echo "  PASS  $1"
  else
    echo "  FAIL  $1"; echo "$2" | head -c 600 | sed 's/^/        /'
    FAILURES=$((FAILURES + 1))
  fi
}
session() {
  call POST /session "{\"bundleId\":\"$BUNDLE_ID\",\"arguments\":[\"-VOScenario\",\"$1\"]}"
}

echo "== Runner status"
check "runner is up" "$(call GET /status)" '.ready == true'

echo "== static: walk the whole screen"
R=$(session static); echo "  session: $(echo "$R" | jq -c '{readyAfter, utterance}')"
# On iOS 27.2+ every session reports where VoiceOver landed; on 27.0 only the first does.
check "session landing is the app or unknown" "$R" '.utterance == null or (.utterance | startswith("VOFocus Demo"))'
if [[ "$(echo "$R" | jq -r '.utterance // empty')" != "" ]]; then
  echo "  (landing reported: $(echo "$R" | jq -r .utterance))"
fi
check "walk from the middle still covers the whole screen" \
  "$(call POST /vo/next >/dev/null; call POST /vo/next >/dev/null; call POST /vo/walk)" \
  '[.stops[] | capture("(?<w>Static Order|One|Two|Three)").w] == ["Static Order","One","Two","Three"]'
R=$(call POST /vo/walk); echo "  stops: $(echo "$R" | jq -c .stops)"
check "walk reaches the end" "$R" '.reachedEnd == true'
check "order is heading, One, Two, Three" "$R" \
  '[.stops[] | select(test("Static Order|One|Two|Three"))] | map(capture("(?<w>Static Order|One|Two|Three)").w) == ["Static Order","One","Two","Three"]'

echo "== counter: VoiceOver double tap activates"
session counter > /dev/null
check "focus moves to Increment" "$(call POST /vo/focus '{"element":{"identifier":"increment"}}')" \
  '(.utterance // "") | contains("Increment")'
check "activate is accepted" "$(call POST /vo/activate)" ".ok == true"
check "count is now 1" "$(call GET /tree)" '[.. | objects | .label? // empty] | index("Count: 1") != null'
check "next/previous then activate finds the focused element" \
  "$(call POST /vo/previous >/dev/null; call POST /vo/next >/dev/null; call POST /vo/activate)" '.ok == true'
check "activate on a given element works too" "$(call POST /vo/activate '{"element":{"identifier":"increment"}}')" '.ok == true'
check "count is now 3" "$(call GET /tree)" '[.. | objects | .label? // empty] | index("Count: 3") != null'

echo "== uikit-banner: .layoutChanged moves focus to the banner"
session uikit-banner > /dev/null
check "focus moves to Save" "$(call POST /vo/focus '{"element":{"identifier":"save"}}')" \
  '(.utterance // "") | contains("Save")'
check "activate is accepted" "$(call POST /vo/activate)" ".ok == true"
check "VoiceOver lands on the banner" \
  "$(call GET '/vo/current?contains=Saved%20successfully&timeout=3')" '(.utterance // "") | contains("Saved successfully")'

echo "== swiftui-error: @AccessibilityFocusState moves focus to the error"
session swiftui-error > /dev/null
check "focus moves to Submit" "$(call POST /vo/focus '{"element":{"identifier":"submit"}}')" \
  '(.utterance // "") | contains("Submit")'
check "activate is accepted" "$(call POST /vo/activate)" ".ok == true"
check "VoiceOver lands on the error" \
  "$(call GET '/vo/current?contains=Name%20is%20required&timeout=3')" '(.utterance // "") | contains("Name is required")'

echo "== tree and errors"
check "tree has the error text" "$(call GET /tree)" '[.. | .identifier? // empty] | index("error") != null'
check "unknown element is a clean error" \
  "$(call POST /vo/focus '{"element":{"identifier":"nope","timeout":0.5}}')" '.error.code == "elementNotFound"'
check "unknown route is a clean error" "$(call GET /nope)" '.error.code == "notFound"'

echo
if [[ $FAILURES -eq 0 ]]; then echo "All checks passed"; else echo "$FAILURES check(s) failed"; exit 1; fi

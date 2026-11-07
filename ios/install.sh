#!/usr/bin/env bash
# Builds Baby Monitor and installs it on every iPhone paired with this Mac.
#
#   ./install.sh                  install on all paired iPhones
#   TEAM_ID=ABCDE12345 ./install.sh
#   BUNDLE_ID=com.you.BabyMonitor ./install.sh
#
# Phones can be plugged in with a cable, or on the same Wi-Fi as the Mac once
# they have been paired with it (connect with a cable once). With a free Apple ID
# the app stops opening after 7 days: just run this again.
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit "${2:-1}"; }

command -v xcodebuild >/dev/null || fail "Xcode isn't installed. Get it from the Mac App Store, open it once, then run this again."
xcrun --find devicectl >/dev/null 2>&1 || fail "This needs Xcode 15 or newer."

# --- Find the phones ---------------------------------------------------------
say "Looking for iPhones…"
devices_json="$(mktemp)"
trap 'rm -f "$devices_json"' EXIT
xcrun devicectl list devices --json-output "$devices_json" >/dev/null 2>&1 || true

# One line per phone: "<udid>\t<name>"
phones="$(/usr/bin/python3 - "$devices_json" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    hw = d.get("hardwareProperties", {})
    conn = d.get("connectionProperties", {})
    if hw.get("platform") != "iOS" or hw.get("reality") == "virtual":
        continue
    if conn.get("pairingState") != "paired":
        continue
    udid = hw.get("udid") or d.get("identifier")
    name = d.get("deviceProperties", {}).get("name", udid)
    print(f"{udid}\t{name}")
PY
)"

if [ -z "$phones" ]; then
  fail "No iPhone found. Connect a phone with a cable, unlock it and tap "Trust This Computer", then run this again." 3
fi
echo "$phones" | while IFS=$'\t' read -r _ name; do echo "  • $name"; done

# --- Signing team ------------------------------------------------------------
team="${TEAM_ID:-}"
if [ -z "$team" ]; then
  # The team picked in Xcode → Signing & Capabilities, if any.
  team="$(xcodebuild -project BabyMonitor.xcodeproj -target BabyMonitor -showBuildSettings 2>/dev/null \
    | awk -F' = ' '$1 ~ /^ *DEVELOPMENT_TEAM$/ { print $2; exit }')"
fi
if [ -z "$team" ]; then
  # Otherwise the team of an Apple Development certificate on this Mac.
  team="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -n 1)"
fi
if [ -z "$team" ]; then
  fail "No Apple signing team found yet. Do this once:
  1. Open BabyMonitor.xcodeproj in Xcode.
  2. Xcode → Settings → Accounts: add your Apple ID.
  3. Click the BabyMonitor project → Signing & Capabilities → Team: pick your name.
Then run ./install.sh again."
fi
echo "Signing team: $team"

extra_settings=()
if [ -n "${BUNDLE_ID:-}" ]; then
  extra_settings+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID")
fi

# --- Build and install on each phone -----------------------------------------
app="build/Build/Products/Release-iphoneos/BabyMonitor.app"
installed=0
failed=0
while IFS=$'\t' read -r udid name; do
  say "Building for $name…"
  if ! xcodebuild build \
      -project BabyMonitor.xcodeproj \
      -scheme BabyMonitor \
      -configuration Release \
      -destination "id=$udid" \
      -derivedDataPath build \
      -allowProvisioningUpdates \
      -allowProvisioningDeviceRegistration \
      DEVELOPMENT_TEAM="$team" \
      ${extra_settings[@]+"${extra_settings[@]}"} \
      -quiet; then
    echo "Build for $name failed (see the messages above)."
    failed=$((failed + 1))
    continue
  fi
  say "Installing on $name…"
  if xcrun devicectl device install app --device "$udid" "$app"; then
    installed=$((installed + 1))
  else
    echo "Couldn't install on $name. Is it unlocked and nearby?"
    failed=$((failed + 1))
  fi
done <<< "$phones"

if [ "$failed" -eq 0 ]; then
  say "Installed on $installed phone(s)."
else
  say "Installed on $installed phone(s), $failed failed."
fi
cat <<'EOF'
First time on a phone?
  • Settings → Privacy & Security → Developer Mode → On (the phone restarts).
  • Settings → General → VPN & Device Management → your Apple ID → Trust.
With a free Apple ID the app stops opening after 7 days. Run ./install.sh again to renew it.
EOF
[ "$failed" -eq 0 ]

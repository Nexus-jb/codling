#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Takes screenshots of Codling's main pages on simulators of every screen
# size that can be jailbroken (A12 and newer), upright and on its side:
#
#   scripts/layout-screenshots.sh <out-dir>
#
# Needs Xcode, XcodeGen's project (xcodegen generate) and gpgv. Each
# simulator's screenshots go into <out-dir>/<iOS>-<device>/. The app reads
# real sources from the internet, through ScreenshotTests/root.

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <out-dir>" >&2
    exit 2
fi
out=$(mkdir -p "$1" && cd "$1" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A folder laid out like a rootless jailbreak's root, with gpgv for the
# sources' signatures.
root="$work/root"
cp -R ScreenshotTests/root "$root"
mkdir -p "$root/usr/bin"
ln -s "$(command -v gpgv)" "$root/usr/bin/gpgv"

derived="$work/derived"
xcodebuild build-for-testing -project Codling.xcodeproj -scheme Codling \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -quiet

# Before iOS 26 Codling draws its own tab bar; on iOS 26 it uses the system's.
# The newest runtime of each major version is used.
devices="
18 iPhone SE (3rd generation)
18 iPhone 12 mini
18 iPhone 11 Pro Max
18 iPhone 16 Pro Max
18 iPad mini (6th generation)
18 iPad (10th generation)
18 iPad Pro 13-inch (M4)
26 iPhone 17 Pro Max
26 iPad Pro 13-inch (M5)
"

xcrun simctl list runtimes --json > "$work/runtimes.json"
xcrun simctl list devicetypes --json > "$work/devicetypes.json"

failed=0
while read -r major name; do
    [ -n "$major" ] || continue
    ids=$(python3 -I - "$work/runtimes.json" "$work/devicetypes.json" "$major" "$name" <<'PY'
import json, sys
runtimes = json.load(open(sys.argv[1]))["runtimes"]
types = json.load(open(sys.argv[2]))["devicetypes"]
major, name = sys.argv[3], sys.argv[4]
def version(r):
    return tuple(int(p) for p in r["version"].split("."))
fitting = [r for r in runtimes if r.get("isAvailable") and r.get("platform", "iOS") == "iOS"
           and r["version"].split(".")[0] == major]
kind = [t for t in types if t["name"] == name]
if fitting and kind:
    runtime = max(fitting, key=version)
    supported = {t["identifier"] for t in runtime.get("supportedDeviceTypes", [])}
    if not supported or kind[0]["identifier"] in supported:
        print(runtime["identifier"], kind[0]["identifier"], runtime["version"])
PY
)
    if [ -z "$ids" ]; then
        echo "Skipped: iOS $major $name (not on this runner)"
        continue
    fi
    set -- $ids
    label=$(printf 'iOS%s-%s' "$3" "$name" | tr -c 'A-Za-z0-9.\n' '-' | sed 's/--*/-/g; s/-$//')
    udid=$(xcrun simctl create "$label" "$2" "$1" </dev/null)
    echo "== $label"
    if ! TEST_RUNNER_SCREENSHOT_ROOT="$root" TEST_RUNNER_SCREENSHOT_DIR="$out/$label" \
        xcodebuild test-without-building -project Codling.xcodeproj -scheme Codling \
        -destination "id=$udid" -derivedDataPath "$derived" \
        -only-testing:LayoutScreenshots -quiet </dev/null; then
        echo "The screenshots on $label did not all succeed." >&2
        failed=1
    fi
    xcrun simctl shutdown "$udid" </dev/null >/dev/null 2>&1 || true
    xcrun simctl delete "$udid" </dev/null >/dev/null 2>&1 || true
done <<LIST
$devices
LIST

ls -R "$out"
# A simulator that failed still leaves the screenshots it took; the
# workflow publishes them either way.
if [ "$failed" -ne 0 ]; then
    echo "Some simulators did not finish; see the log above." >&2
fi

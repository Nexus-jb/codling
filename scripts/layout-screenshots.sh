#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Screenshots of Codling's main pages on simulators of every screen size that
# can be jailbroken (A12 and newer), upright and on their side:
#
#   scripts/layout-screenshots.sh build <products-dir>
#   scripts/layout-screenshots.sh shoot <products-dir> <iOS major> <device name> <out-dir>
#
# build makes the app and its screenshot test for the simulator, with
# XcodeGen's project (xcodegen generate) already there. shoot runs the test
# on a new simulator of that device, with the newest runtime of that major
# iOS version, and saves the screenshots in <out-dir>, upright. It needs
# gpgv: the app reads real sources from the internet, through
# ScreenshotTests/root. The Layout screenshots workflow runs one shoot per
# device, side by side.

set -eu

usage() {
    echo "usage: $0 build <products-dir>" >&2
    echo "       $0 shoot <products-dir> <iOS major> <device name> <out-dir>" >&2
    exit 2
}

[ "$#" -ge 2 ] || usage
command=$1
products=$2

case "$command" in
build)
    [ "$#" -eq 2 ] || usage
    derived=$(mktemp -d)
    xcodebuild build-for-testing -project Codling.xcodeproj -scheme Codling \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -quiet
    rm -rf "$products"
    mkdir -p "$products"
    cp -R "$derived/Build/Products/." "$products/"
    rm -rf "$derived"
    ls "$products"
    ;;
shoot)
    [ "$#" -eq 5 ] || usage
    major=$3
    name=$4
    out=$(mkdir -p "$5" && cd "$5" && pwd)
    work=$(mktemp -d)
    udid=
    cleanup() {
        if [ -n "$udid" ]; then
            xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
            xcrun simctl delete "$udid" >/dev/null 2>&1 || true
        fi
        rm -rf "$work"
    }
    trap cleanup EXIT

    # A folder laid out like a rootless jailbreak's root, with gpgv for the
    # sources' signatures.
    root="$work/root"
    cp -R ScreenshotTests/root "$root"
    mkdir -p "$root/usr/bin"
    ln -s "$(command -v gpgv)" "$root/usr/bin/gpgv"

    xcrun simctl list runtimes --json > "$work/runtimes.json"
    xcrun simctl list devicetypes --json > "$work/devicetypes.json"
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
        echo "iOS $major $name is not on this machine. Runtimes:" >&2
        xcrun simctl list runtimes >&2
        exit 1
    fi
    set -- $ids
    label=$(printf 'iOS%s-%s' "$3" "$name" | tr -c 'A-Za-z0-9.\n' '-' | sed 's/--*/-/g; s/-$//')
    udid=$(xcrun simctl create "$label" "$2" "$1")
    xctestrun=$(ls "$products"/*.xctestrun | head -n 1)
    status=0
    TEST_RUNNER_SCREENSHOT_ROOT="$root" TEST_RUNNER_SCREENSHOT_DIR="$out/$label" \
        xcodebuild test-without-building -xctestrun "$xctestrun" -destination "id=$udid" \
        -only-testing:LayoutScreenshots > "$work/test.log" 2>&1 || status=$?
    # What went wrong, without the rest of xcodebuild's output.
    grep -E "error:|failed|Skipped|Executed" "$work/test.log" | tail -n 40 || true
    # The screenshots come in the screen's own orientation: one taken on
    # the device's side is turned upright here.
    for file in "$out/$label"/landscape-*.png; do
        [ -f "$file" ] || continue
        width=$(sips -g pixelWidth "$file" | awk '/pixelWidth/ { print $2 }')
        height=$(sips -g pixelHeight "$file" | awk '/pixelHeight/ { print $2 }')
        if [ "$height" -gt "$width" ]; then
            sips --rotate 270 "$file" >/dev/null
        fi
    done
    ls "$out/$label" 2>/dev/null || true
    exit "$status"
    ;;
*)
    usage
    ;;
esac

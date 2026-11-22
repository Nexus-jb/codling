#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Builds com.nexusjb.codling-test-crash, a rootless test package with a
# tweak that crashes SpringBoard once on purpose, eight seconds after the
# respring that follows its install
# (TestPackages/SafeModeTest/CodlingSafeModeTest.c). Burrow's Safe Mode then
# turns it off in SpringBoard, and Codling's Turned Off by Safe Mode list
# shows it with Turn Back On and Remove. It crashes only once per install.
# Needs macOS with Xcode, ldid and dpkg.
#
#   scripts/make-safe-mode-test-package.sh <out-dir>

set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: make-safe-mode-test-package.sh <out-dir>}
mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
chmod 0755 "$stage"

tweaks="$stage/var/jb/usr/lib/TweakInject"
mkdir -p "$stage/DEBIAN" "$tweaks"
# arm64e for SpringBoard on A12 and later, arm64 alongside it as tweaks
# usually carry.
xcrun --sdk iphoneos clang -arch arm64 -arch arm64e -mios-version-min=15.0 -Os -Wall -Wextra -Werror \
    -dynamiclib -install_name /var/jb/usr/lib/TweakInject/CodlingSafeModeTest.dylib \
    "$here/TestPackages/SafeModeTest/CodlingSafeModeTest.c" -o "$tweaks/CodlingSafeModeTest.dylib"
ldid -S "$tweaks/CodlingSafeModeTest.dylib"
install -m 0644 "$here/TestPackages/SafeModeTest/CodlingSafeModeTest.plist" "$tweaks/CodlingSafeModeTest.plist"

cat > "$stage/DEBIAN/control" <<'CONTROL'
Package: com.nexusjb.codling-test-crash
Name: Codling Safe Mode Test
Version: 1.0
Architecture: iphoneos-arm64
Section: Tweaks
Maintainer: Ultra Team <support@nexusjb.com>
Author: Ultra Team <support@nexusjb.com>
Description: Crashes SpringBoard once on purpose, to try Safe Mode
 After the respring that follows its install, this tweak crashes
 SpringBoard once, eight seconds after it starts. Burrow's Safe Mode turns
 it off in SpringBoard, and Codling lists it under Turned Off by Safe Mode
 in System, Burrow, where Remove takes it off. It crashes only once for
 each install. It is a test package; remove it afterwards.
CONTROL

marker=/var/mobile/Library/Caches/com.nexusjb.codling-test-crash.crashed
for script in postinst postrm; do
    cat > "$stage/DEBIAN/$script" <<SCRIPT
#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Each install crashes SpringBoard once again.
rm -f $marker
exit 0
SCRIPT
    chmod 0755 "$stage/DEBIAN/$script"
done

deb="$out/com.nexusjb.codling-test-crash_1.0_iphoneos-arm64.deb"
dpkg-deb --root-owner-group -Zgzip --build "$stage" "$deb" >/dev/null
echo "$deb"

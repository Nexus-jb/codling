#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Builds com.nexusjb.codling-test-setup, a rootless test package whose setup
# fails the first time on purpose. Installing it leaves a package half
# configured, so the System tab's Finish Setting Up can be tried on a real
# device; the second setup succeeds. It installs no files.
#
#   scripts/make-test-package.sh <out-dir>

set -euo pipefail

out=${1:?usage: make-test-package.sh <out-dir>}
mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/DEBIAN"
cat > "$stage/DEBIAN/control" <<'CONTROL'
Package: com.nexusjb.codling-test-setup
Name: Codling Setup Test
Version: 1.0
Architecture: iphoneos-arm64
Section: Development
Maintainer: Nexus <support@nexusjb.com>
Description: Fails its first setup on purpose, to test Codling's repair
 Installing this package leaves it half configured. Codling's System tab
 then offers Finish Setting Up, and the second setup succeeds. Remove the
 package afterwards; it installs no files.
CONTROL

cat > "$stage/DEBIAN/postinst" <<'SCRIPT'
#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
marker=/var/jb/var/tmp/com.nexusjb.codling-test-setup.tried
if [ "$1" = configure ] && [ ! -e "$marker" ]; then
    mkdir -p /var/jb/var/tmp
    touch "$marker"
    echo "Codling Setup Test: failing the first setup on purpose." >&2
    exit 1
fi
exit 0
SCRIPT

cat > "$stage/DEBIAN/postrm" <<'SCRIPT'
#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
rm -f /var/jb/var/tmp/com.nexusjb.codling-test-setup.tried
exit 0
SCRIPT

chmod 0755 "$stage/DEBIAN/postinst" "$stage/DEBIAN/postrm"
deb="$out/com.nexusjb.codling-test-setup_1.0_iphoneos-arm64.deb"
dpkg-deb --root-owner-group -Zgzip --build "$stage" "$deb" >/dev/null
echo "$deb"

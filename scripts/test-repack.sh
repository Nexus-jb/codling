#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Tests Helper/repack.c, which rebuilds an installed package's .deb for undo,
# against a made-up dpkg database and file tree. Needs a C compiler and
# dpkg-deb, as on Ubuntu.

set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
checks=0

check() {
    checks=$((checks + 1))
    if [ "$2" != "$3" ]; then
        echo "not ok: $1"
        echo "  expected: $3"
        echo "  got:      $2"
        failures=$((failures + 1))
    fi
}

cc -std=c11 -Wall -Wextra -Werror -o "$work/driver" "$here/Helper/repack.c" "$here/Helper/tests/repack_driver.c"

# The jailbreak's files. As on rootless, /var/jb is a link to the real root.
root="$work/root"
mkdir -p "$root/var" "$root/preboot/jb/usr/bin" "$root/preboot/jb/usr/lib" "$root/preboot/jb/etc"
ln -s ../preboot/jb "$root/var/jb"
printf '#!/bin/sh\necho tool\n' > "$root/preboot/jb/usr/bin/tool"
chmod 4755 "$root/preboot/jb/usr/bin/tool"
printf 'library' > "$root/preboot/jb/usr/lib/libtool.1.dylib"
ln -s libtool.1.dylib "$root/preboot/jb/usr/lib/libtool.dylib"
printf 'setting=changed\n' > "$root/preboot/jb/etc/tool.conf"

admin="$work/admin"
mkdir -p "$admin/info"
cat > "$admin/status" <<'STATUS'
Package: other
Status: install ok installed
Version: 1.0
Architecture: iphoneos-arm64
Description: Another package

Package: tool
Status: install ok installed
Priority: optional
Section: Utilities
Installed-Size: 12
Maintainer: Jane Doe <jane@example.com>
Architecture: iphoneos-arm64
Version: 1:2.0-1
Depends: other (>= 1.0)
Conffiles:
 /var/jb/etc/tool.conf 0123456789abcdef0123456789abcdef
 /var/jb/etc/gone.conf 0123456789abcdef0123456789abcdef obsolete
Description: A tool
 It does things.
 .
 Really.

Package: leftover
Status: deinstall ok config-files
Version: 3.0
Architecture: iphoneos-arm64
STATUS
cat > "$admin/info/tool.list" <<'LIST'
/.
/var
/var/jb
/var/jb/usr
/var/jb/usr/bin
/var/jb/usr/bin/tool
/var/jb/usr/bin/deleted
/var/jb/usr/lib
/var/jb/usr/lib/libtool.1.dylib
/var/jb/usr/lib/libtool.dylib
/var/jb/etc
/var/jb/etc/tool.conf
LIST
printf '#!/bin/sh\nexit 0\n' > "$admin/info/tool.postinst"
mkdir -p "$work/out"

name=$("$work/driver" "$admin" "$root" "$work/staging" "$work/out" tool)
check "the backup's name" "$name" "tool_1%3a2.0-1_iphoneos-arm64.deb"
deb="$work/out/$name"
check "the backup is built" "$([ -f "$deb" ] && echo yes)" "yes"
check "no partial file is left" "$(ls "$work/out" | grep -c part || true)" "0"
check "the staging directory is cleaned" "$(ls -A "$work/staging")" ""

check "Package" "$(dpkg-deb -f "$deb" Package)" "tool"
check "Version" "$(dpkg-deb -f "$deb" Version)" "1:2.0-1"
check "Depends" "$(dpkg-deb -f "$deb" Depends)" "other (>= 1.0)"
check "Status is dropped" "$(dpkg-deb -f "$deb" Status)" ""
check "Conffiles is dropped" "$(dpkg-deb -f "$deb" Conffiles)" ""
check "the description keeps its lines" "$(dpkg-deb -f "$deb" Description | tr '\n' '|')" "A tool| It does things.| .| Really.|"

contents=$(dpkg-deb -c "$deb")
line() { printf '%s\n' "$contents" | grep " ./$1\( \|$\|/$\)" | head -n 1; }
check "/var/jb is a directory, not the link" "$(line var/jb | cut -c1)" "d"
check "the tool keeps its mode" "$(line var/jb/usr/bin/tool | cut -c1-10)" "-rwsr-xr-x"
check "the library is copied" "$(line var/jb/usr/lib/libtool.1.dylib | cut -c1)" "-"
check "the package's own link stays a link" "$(line var/jb/usr/lib/libtool.dylib | sed 's/.* -> //')" "libtool.1.dylib"
check "a deleted file is left out" "$(line var/jb/usr/bin/deleted)" ""

mkdir -p "$work/control"
dpkg-deb -e "$deb" "$work/control"
check "the conffile on disk is kept, the obsolete one dropped" "$(cat "$work/control/conffiles")" "/var/jb/etc/tool.conf"
check "postinst is kept and runnable" "$([ -x "$work/control/postinst" ] && echo yes)" "yes"
mkdir -p "$work/extracted"
dpkg-deb -x "$deb" "$work/extracted"
check "a changed conffile keeps its content" "$(cat "$work/extracted/var/jb/etc/tool.conf")" "setting=changed"

check "an installed version" "$("$work/driver" --version "$admin" tool)" "1:2.0-1 iphoneos-arm64"
check "a removed package has no version" "$("$work/driver" --version "$admin" leftover || echo none)" "none"
check "a removed package is not rebuilt" "$("$work/driver" "$admin" "$root" "$work/staging" "$work/out" leftover || true)" "the package is not installed"
check "an unknown package is not rebuilt" "$("$work/driver" "$admin" "$root" "$work/staging" "$work/out" toolbox || true)" "the package is not installed"

if [ "$failures" -ne 0 ]; then
    echo "[repack] $failures of $checks checks failed"
    exit 1
fi
echo "[repack] $checks checks passed"

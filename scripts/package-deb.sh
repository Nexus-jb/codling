#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Signs a Codling.app build with ldid and packages it for each supported
# jailbreak scheme:
#
#   scripts/package-deb.sh <Codling.app> <version> <out-dir>
#
# Writes, in <out-dir>:
#   com.nexusjb.codling_<version>_iphoneos-arm64.deb    rootless (/var/jb/Applications)
#   com.nexusjb.codling_<version>_iphoneos-arm64e.deb   roothide (/Applications in the hidden root)
#   SHA256SUMS
#
# Needs ldid and dpkg-deb (Homebrew: brew install ldid dpkg). SKIP_SIGN=1
# leaves the binary unsigned, to check the layout on a machine without ldid.
set -euo pipefail

app=${1:?path to Codling.app}
version=${2:?version}
out=${3:?output directory}

identifier=com.nexusjb.codling
bundle_name=Codling
repo=$(cd "$(dirname "$0")/.." && pwd)
entitlements="$repo/packaging/Codling.entitlements"

# Debian versions: digits and dots, with an optional ~ or + suffix for
# development builds (for example 0.1.0~dev.42, which sorts before 0.1.0).
if ! [[ $version =~ ^[0-9]+(\.[0-9]+){1,3}([~+][0-9A-Za-z.]+)?$ ]]; then
  echo "Not a valid version: $version" >&2
  exit 1
fi
if [[ ! -d $app || ! -f $app/Info.plist ]]; then
  echo "Not an app bundle: $app" >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

bundle="$work/$bundle_name.app"
cp -R "$app" "$bundle"

plist_value() {
  if command -v plutil >/dev/null 2>&1; then
    plutil -extract "$1" raw "$bundle/Info.plist"
  else
    python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))[sys.argv[2]])' \
      "$bundle/Info.plist" "$1"
  fi
}
executable=$(plist_value CFBundleExecutable)
built_id=$(plist_value CFBundleIdentifier)
if [[ $built_id != "$identifier" ]]; then
  echo "The build is $built_id, not $identifier" >&2
  exit 1
fi

# The root helper is built into the bundle with the app (project.yml).
helper="$bundle/codling-helper"
if [[ ! -f $helper ]]; then
  echo "The build has no root helper: $helper" >&2
  exit 1
fi

# The app shows the package version, which the build cannot know.
if command -v plutil >/dev/null 2>&1; then
  plutil -replace CodlingPackageVersion -string "$version" "$bundle/Info.plist"
else
  python3 -I -c 'import plistlib, sys
path = sys.argv[1]
info = plistlib.load(open(path, "rb"))
info["CodlingPackageVersion"] = sys.argv[2]
plistlib.dump(info, open(path, "wb"))' "$bundle/Info.plist" "$version"
fi

# Replace any signature Xcode left behind, then sign with our entitlements.
find "$bundle" -name _CodeSignature -type d -prune -exec rm -rf {} +
if [[ ${SKIP_SIGN:-0} != 1 ]]; then
  while IFS= read -r -d '' lib; do
    ldid -S "$lib"
  done < <(find "$bundle" -name '*.dylib' -type f -print0)
  ldid -S"$repo/packaging/codling-helper.entitlements" "$helper"
  ldid -S"$entitlements" "$bundle/$executable"
fi
# The app runs as the mobile user, so everything must be readable by everyone.
chmod -R u+rwX,go+rX,go-w "$bundle"
chmod 0755 "$bundle/$executable" "$helper"

# make_deb ARCH PREFIX UICACHE
#   ARCH     Debian architecture of the scheme
#   PREFIX   where the jailbreak root is, as dpkg sees it
#   UICACHE  path of uicache, as the maintainer scripts see it
make_deb() {
  local arch=$1 prefix=$2 uicache=$3
  local root="$work/deb-$arch"
  mkdir -p "$root/DEBIAN" "$root$prefix/Applications"
  cp -R "$bundle" "$root$prefix/Applications/$bundle_name.app"

  cat > "$root/DEBIAN/control" <<CONTROL
Package: $identifier
Name: Codling
Version: $version
Architecture: $arch
Description: A modern, open-source package manager for jailbroken iOS.
 Installs, upgrades and removes packages from your sources, buys paid ones,
 and can undo a change.
Maintainer: Ultra Team
Author: Ultra Team
Section: Packaging
Depends: firmware (>= 15.0), uikittools
Homepage: https://github.com/Nexus-jb/codling
CONTROL

  # Refuse chips older than the A12.
  install -m 0755 "$repo/packaging/preinst" "$root/DEBIAN/preinst"

  # Register the app with the home screen, and forget it on removal.
  cat > "$root/DEBIAN/postinst" <<SCRIPT
#!/bin/sh
$uicache -p "$prefix/Applications/$bundle_name.app" || $uicache -a || true
exit 0
SCRIPT
  cat > "$root/DEBIAN/postrm" <<SCRIPT
#!/bin/sh
if [ "\$1" = remove ] || [ "\$1" = purge ]; then
  $uicache -a || true
fi
exit 0
SCRIPT
  chmod 0755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"
  chmod -R u+rwX,go+rX,go-w "$root"

  local deb="$out/${identifier}_${version}_${arch}.deb"
  dpkg-deb --root-owner-group -Zxz -b "$root" "$deb" >/dev/null

  # Every entry must be readable by everyone.
  local closed
  closed=$(dpkg-deb -c "$deb" | awk '$1 !~ /^.r..r..r/ {print $1, $6}')
  if [[ -n $closed ]]; then
    echo "Entries not readable by everyone in $deb:" >&2
    head -20 <<< "$closed" >&2
    exit 1
  fi
  echo "$deb"
}

# Rootless: the jailbreak root is /var/jb.
make_deb iphoneos-arm64 /var/jb /var/jb/usr/bin/uicache
# RootHide: dpkg and maintainer scripts see the hidden root as /.
make_deb iphoneos-arm64e "" uicache

(cd "$out" && shasum -a 256 ./*.deb > SHA256SUMS 2>/dev/null || sha256sum ./*.deb > SHA256SUMS)
echo "$out/SHA256SUMS"

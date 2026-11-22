#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Checks, with a real apt, what the root helper relies on to install
# purchased packages (stage_purchases in Helper/codling-helper.c):
#
#   1. apt does not check the signature of a .deb named on its command line,
#      so a purchase must not reach apt as a file;
#   2. a package whose archive is already in apt's cache is still checked:
#      from a source that is not signed it is refused without
#      --allow-unauthenticated, and taken with it;
#   3. from a signed source it is installed from the cache, with no
#      download (paid packages cannot be downloaded from the source);
#   4. apt-get install --print-uris with an empty cache names the archive,
#      and the helper reads that name from apt's real output;
#   5. a .deb the user opened in Codling (take-file, the %TOKEN operation)
#      is installed as a file, its dependencies come from the sources, and
#      the helper reads its name and version from dpkg-deb's real output.
#
# Two flat repositories, one signed with a throwaway key, are served on
# 127.0.0.1. Needs apt, dpkg-deb, gpg, python3 and a C compiler, as on
# Ubuntu. Runs without root.

set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
server=
cleanup() {
    [ -n "$server" ] && kill "$server" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

failures=0
checks=0
expect() {
    checks=$((checks + 1))
    if [ "$1" != "$2" ]; then
        failures=$((failures + 1))
        echo "not ok: $3 (expected $2, got $1)" >&2
    fi
}

cc -std=gnu11 -Wall -Wextra -Werror -Wno-format-truncation -I"$here/Helper" -o "$work/driver" \
    "$here/Helper/tests/purchase_driver.c" "$here/Helper/repack.c" "$here/Helper/sha256.c"

# Packages: paid ones are in the indexes but not on the servers, as with a
# real paid source.
mkdir -p "$work/build" "$work/srv/signed" "$work/srv/unsigned"
package() {
    mkdir -p "$work/build/$1/DEBIAN"
    printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: Test <test@example.com>\nDescription: test\n' \
        "$1" "$2" > "$work/build/$1/DEBIAN/control"
    dpkg-deb -b -Zgzip "$work/build/$1" "$work/build/$1.deb" > /dev/null
}
package paid-unsigned 1.0
package paid-signed 2:1.0-1

# A package the user opened from a file, which depends on one from a source
# and on one no source has.
opened() {
    mkdir -p "$work/build/$1/DEBIAN"
    printf 'Package: %s\nName: Opened Tweak\nVersion: 1.0.3\nArchitecture: all\nMaintainer: Test <test@example.com>\nDepends: %s\nDescription: opened from a file\n second line\n' \
        "$1" "$2" > "$work/build/$1/DEBIAN/control"
    dpkg-deb -b -Zgzip "$work/build/$1" "$work/build/$1.deb" > /dev/null
}
opened opened-tweak paid-signed
opened opened-broken no-source-has-this

python3 -I - "$work" <<'EOF'
import hashlib, os, subprocess, sys
work = sys.argv[1]
for repo, name in (("unsigned", "paid-unsigned"), ("signed", "paid-signed")):
    deb = os.path.join(work, "build", name + ".deb")
    data = open(deb, "rb").read()
    control = subprocess.run(["dpkg-deb", "-f", deb], check=True, capture_output=True, text=True).stdout
    record = control.rstrip("\n") + "\nFilename: ./%s.deb\nSize: %d\nSHA256: %s\n\n" % (
        name, len(data), hashlib.sha256(data).hexdigest())
    directory = os.path.join(work, "srv", repo)
    open(os.path.join(directory, "Packages"), "w").write(record)
    packages = record.encode()
    open(os.path.join(directory, "Release"), "w").write(
        "Origin: Test\nLabel: Test\nSuite: stable\nCodename: test\nArchitectures: all\n"
        "Date: Sat, 21 Nov 2026 00:00:00 UTC\nSHA256:\n %s %d Packages\n"
        % (hashlib.sha256(packages).hexdigest(), len(packages)))
EOF

mkdir -m 700 "$work/gnupg"
export GNUPGHOME="$work/gnupg"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' --quick-gen-key 'Codling Test <test@example.com>' \
    ed25519 sign never 2> /dev/null
gpg --batch --yes --clearsign -o "$work/srv/signed/InRelease" "$work/srv/signed/Release" 2> /dev/null

port=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -I -m http.server "$port" --bind 127.0.0.1 --directory "$work/srv" > "$work/http.log" 2>&1 &
server=$!

root="$work/root"
mkdir -p "$root/etc/apt/apt.conf.d" "$root/etc/apt/preferences.d" "$root/etc/apt/sources.list.d" \
    "$root/etc/apt/trusted.gpg.d" "$root/var/lib/apt/lists/partial" "$root/var/cache/apt/archives/partial" \
    "$root/var/lib/dpkg" "$work/empty/partial"
touch "$root/var/lib/dpkg/status"
gpg --batch --export > "$root/etc/apt/trusted.gpg.d/test.gpg"
cat > "$root/etc/apt/sources.list.d/test.sources" <<EOF
Types: deb
URIs: http://127.0.0.1:$port/unsigned/
Suites: ./

Types: deb
URIs: http://127.0.0.1:$port/signed/
Suites: ./
EOF
cat > "$work/apt.conf" <<EOF
Dir "$root/";
Dir::State::status "$root/var/lib/dpkg/status";
Debug::NoLocking "true";
APT::Sandbox::User "$(id -un)";
Acquire::Languages "none";
EOF
export APT_CONFIG="$work/apt.conf"

# The server may take a moment to listen.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if python3 -I -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$port/signed/Release')" \
        2> /dev/null; then
        break
    fi
    sleep 0.5
done

apt-get update -q -o Acquire::AllowInsecureRepositories=true > "$work/update.log" 2>&1

# 0 when the file holds the text.
found() {
    if grep -q "$1" "$2"; then echo 0; else echo 1; fi
}

run() {
    status=0
    apt-get install -y -q --download-only "$@" > "$work/run.log" 2>&1 || status=$?
    echo "$status"
}
archives="$root/var/cache/apt/archives"

expect "$(found "unsigned ./ Release' is not signed" "$work/update.log")" 0 \
    "apt reads the unsigned source and says it is not signed"

# 1. A .deb on the command line is not checked.
expect "$(run "$work/build/paid-unsigned.deb")" 0 "a file from an unsigned source is taken without consent"
rm -f "$archives"/*.deb

# 2. A cached archive from the unsigned source is checked.
cp "$work/build/paid-unsigned.deb" "$archives/paid-unsigned_1.0_all.deb"
expect "$(run paid-unsigned=1.0)" 100 "a cached package from an unsigned source is refused"
expect "$(found "cannot be authenticated" "$work/run.log")" 0 "apt names it as not authenticated"
expect "$(run --allow-unauthenticated paid-unsigned=1.0)" 0 "with consent it is taken"

# 4. print-uris names the archive, epoch and all, and the helper reads it.
status=0
apt-get install -qq -y --print-uris -o "Dir::Cache::Archives=$work/empty/" paid-signed=2:1.0-1 \
    > "$work/uris.txt" 2>&1 || status=$?
expect "$status" 0 "print-uris works out the change"
name=$("$work/driver" uris "$work/uris.txt" paid-signed 2:1.0-1 || true)
expect "$name" "paid-signed_2%3a1.0-1_all.deb" "the helper reads apt's name for the archive"

# 3. A cached archive from the signed source is installed without a download.
cp "$work/build/paid-signed.deb" "$archives/$name"
expect "$(run paid-signed=2:1.0-1)" 0 "a cached package from a signed source is taken"
expect "$(found "Download complete" "$work/run.log")" 0 "apt finished without fetching it"
expect "$(found "paid-signed" "$work/http.log")" 1 "the paid package was not asked for from the source"

# 5. An opened file is installed as a file, with its dependencies from the
# sources, and the helper reads what dpkg-deb prints.
dpkg-deb --field "$work/build/opened-tweak.deb" > "$work/fields.txt"
expect "$("$work/driver" field "$work/fields.txt" Package || true)" "opened-tweak" "the helper reads the package"
expect "$("$work/driver" field "$work/fields.txt" Version || true)" "1.0.3" "the helper reads the version"
expect "$("$work/driver" field "$work/fields.txt" Name || true)" "Opened Tweak" "the helper reads the name"
status=0
apt-get install -s -q "$work/build/opened-tweak.deb" > "$work/opened.log" 2>&1 || status=$?
expect "$status" 0 "an opened file is planned"
expect "$(found "^Inst opened-tweak " "$work/opened.log")" 0 "the opened file is installed"
expect "$(found "^Inst paid-signed " "$work/opened.log")" 0 "its dependency comes from a source"
status=0
apt-get install -s -q "$work/build/opened-broken.deb" > "$work/broken.log" 2>&1 || status=$?
expect "$status" 100 "an opened file whose dependency no source has is refused"
expect "$(found "no-source-has-this" "$work/broken.log")" 0 "apt names the missing dependency"

if [ "$failures" -ne 0 ]; then
    echo "[apt trust] $failures of $checks checks failed" >&2
    exit 1
fi
echo "[apt trust] $checks checks passed"

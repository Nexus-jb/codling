#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Tests packaging/preinst, the package's check for an A12 chip or newer,
# with a stand-in for uname.

set -u

script=$(cd "$(dirname "$0")/.." && pwd)/packaging/preinst
stubs=$(mktemp -d)
trap 'rm -rf "$stubs"' EXIT

# uname -m prints TEST_MODEL, and fails without it.
cat > "$stubs/uname" <<'STUB'
#!/bin/sh
[ -n "${TEST_MODEL-}" ] || exit 1
echo "$TEST_MODEL"
STUB
chmod 0755 "$stubs/uname"

checks=0
failures=0

# expect STATUS ACTION MODEL
expect() {
  checks=$((checks + 1))
  output=$(PATH="$stubs:$PATH" TEST_MODEL=$3 sh "$script" "$2" 2>&1)
  status=$?
  if [ "$status" -ne "$1" ]; then
    failures=$((failures + 1))
    echo "[preinst] $2 on '$3': exit $status, expected $1" >&2
    return
  fi
  if [ "$1" -ne 0 ]; then
    checks=$((checks + 1))
    case "$output" in
      *"A12 chip or newer"*"($3)"*) ;;
      *)
        failures=$((failures + 1))
        echo "[preinst] unclear message: $output" >&2
        ;;
    esac
  fi
}

# A12 and newer.
expect 0 install iPhone15,3
expect 0 install iPhone11,8
expect 0 install iPhone11,2
expect 0 upgrade iPhone17,1
expect 0 install iPad8,1
expect 0 install iPad11,6
expect 0 install iPad13,4
# A11 and older.
expect 1 install iPhone10,6
expect 1 install iPhone10,1
expect 1 install iPhone9,1
expect 1 install iPhone6,1
expect 1 upgrade iPhone10,3
expect 1 install iPad7,11
expect 1 install iPad6,3
expect 1 install iPad1,1
expect 1 install iPod9,1
# A device uname cannot name, or one that is not an iPhone, iPad or iPod.
expect 0 install ''
expect 0 install Mac14,2
# Only install and upgrade are checked.
expect 0 remove iPhone10,6
expect 0 abort-upgrade iPhone10,6
expect 0 configure iPhone10,6

if [ "$failures" -ne 0 ]; then
  echo "[preinst] $failures of $checks checks failed" >&2
  exit 1
fi
echo "[preinst] $checks checks passed"

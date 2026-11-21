#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Tests what the root helper uses to take a purchased package
# (Helper/sha256.c and parts of Helper/codling-helper.c) with a driver that
# includes the helper. Needs a C compiler, as on Ubuntu.

set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# GCC warns that the helper's existing path joins may be cut short; they
# check their limits on Apple's compiler, which is what builds the helper.
cc -std=gnu11 -Wall -Wextra -Werror -Wno-format-truncation -I"$here/Helper" -o "$work/driver" \
    "$here/Helper/tests/purchase_driver.c" "$here/Helper/repack.c" "$here/Helper/sha256.c"
mkdir "$work/root"
"$work/driver" "$work/root"

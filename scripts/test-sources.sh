#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Tests the root helper's editing of codling.sources (Helper/codling-helper.c)
# with a driver that includes it. Needs a C compiler, as on Ubuntu.

set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# GCC warns that the helper's existing path joins may be cut short; they
# check their limits on Apple's compiler, which is what builds the helper.
cc -std=gnu11 -Wall -Wextra -Werror -Wno-format-truncation -I"$here/Helper" -o "$work/driver" \
    "$here/Helper/tests/sources_driver.c" "$here/Helper/repack.c"
mkdir "$work/files"
"$work/driver" "$work/files"

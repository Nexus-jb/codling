// SPDX-License-Identifier: Apache-2.0
//
// Paths as the jailbreak's own programs see them.
//
// The helper works with real paths. RootHide's programs (apt, dpkg, dpkg-deb,
// gpgv) see the hidden jailbreak root as / and the system volume under
// /rootfs, so a path given to one of them on its command line or in its
// environment must be written their way: a path inside the root loses the
// root's own path, and any other path gains /rootfs. Rootless programs see
// real paths, so nothing changes there. App/ToolPath in CodlingCore does the
// same for the app.

#ifndef CODLING_TOOL_PATH_H
#define CODLING_TOOL_PATH_H

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

// Whether root, a real path, is a RootHide root: a directory whose name starts
// with ".jbroot-".
static inline bool codling_is_roothide_root(const char *root) {
    if (!root) {
        return false;
    }
    const char *last = strrchr(root, '/');
    return last && strncmp(last + 1, ".jbroot-", 8) == 0 && last[9] != '\0';
}

// Writes to out the path that the programs of the jailbreak rooted at root see
// for the real path path. A NULL root changes nothing. Returns 0, or -1 when
// the result does not fit.
static inline int codling_tool_path(const char *root, const char *path, char *out, size_t size) {
    int written;
    if (!codling_is_roothide_root(root)) {
        written = snprintf(out, size, "%s", path);
    } else {
        size_t root_length = strlen(root);
        if (strncmp(path, root, root_length) == 0 && (path[root_length] == '/' || path[root_length] == '\0')) {
            written = snprintf(out, size, "%s", path[root_length] ? path + root_length : "/");
        } else {
            written = snprintf(out, size, "/rootfs%s", path);
        }
    }
    return written >= 0 && (size_t)written < size ? 0 : -1;
}

#endif

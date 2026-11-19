// SPDX-License-Identifier: Apache-2.0
//
// codling-helper: Codling's root helper.
//
// Codling starts the helper as root through a spawn persona, which takes an
// entitlement that only Codling holds. The helper is not setuid, so any other
// program that runs it gets no more rights than it already had. It does only
// the commands listed in main(), and takes no paths from its caller: it finds
// the jailbreak root from where it is installed.
//
//   codling-helper check   prints the identity it runs with and whether it
//                          can write the package database, as one JSON
//                          object. It changes nothing.

#include <limits.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern char **environ;

// Where the helper sits below the jailbreak root.
static const char app_suffix[] = "/Applications/Codling.app/codling-helper";

// The jailbreak root this copy of Codling is installed in: the helper's own
// path with every link followed, less app_suffix. Rootless resolves /var/jb
// into /private/preboot; RootHide's root is a hidden directory.
static int jailbreak_root(char root[PATH_MAX]) {
    char path[PATH_MAX];
    uint32_t size = sizeof path;
    if (_NSGetExecutablePath(path, &size) != 0) {
        return -1;
    }
    char resolved[PATH_MAX];
    if (!realpath(path, resolved)) {
        return -1;
    }
    size_t length = strlen(resolved);
    size_t suffix = sizeof app_suffix - 1;
    if (length <= suffix || strcmp(resolved + length - suffix, app_suffix) != 0) {
        return -1;
    }
    memcpy(root, resolved, length - suffix);
    root[length - suffix] = '\0';
    return 0;
}

static int check(void) {
    char root[PATH_MAX];
    if (jailbreak_root(root) != 0) {
        puts("{\"error\":\"The helper is not inside Codling.app in a jailbreak root.\"}");
        return 70;
    }
    char dpkg[PATH_MAX];
    int length = snprintf(dpkg, sizeof dpkg, "%s/var/lib/dpkg", root);
    int writable = length > 0 && (size_t)length < sizeof dpkg && access(dpkg, W_OK) == 0;
    printf("{\"uid\":%u,\"euid\":%u,\"gid\":%u,\"egid\":%u,\"dpkgWritable\":%s}\n", (unsigned)getuid(),
           (unsigned)geteuid(), (unsigned)getgid(), (unsigned)getegid(), writable ? "true" : "false");
    return 0;
}

int main(int argc, char **argv) {
    // Nothing from the caller's environment, and a known file mode mask.
    static char *clean[] = { "PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL };
    environ = clean;
    umask(022);

    if (argc == 2 && strcmp(argv[1], "check") == 0) {
        return check();
    }
    fputs("usage: codling-helper check\n", stderr);
    return 64;
}

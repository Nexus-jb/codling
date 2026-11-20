// SPDX-License-Identifier: Apache-2.0
//
// Runs codling_repack for scripts/test-repack.sh:
//   repack_driver ADMIN FILES STAGING OUTPUT PACKAGE
// prints the backup's file name, or the reason it failed and exits 1.
//   repack_driver --version ADMIN PACKAGE
// prints "VERSION ARCHITECTURE", or exits 1.

#include "../repack.h"

#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "--version") == 0) {
        char version[256];
        char architecture[64];
        if (codling_installed_version(argv[2], argv[3], version, sizeof version, architecture, sizeof architecture) != 0) {
            return 1;
        }
        printf("%s %s\n", version, architecture);
        return 0;
    }
    if (argc != 6) {
        fputs("usage: repack_driver ADMIN FILES STAGING OUTPUT PACKAGE\n", stderr);
        return 64;
    }
    struct codling_repack_paths paths = {
        .admin = argv[1],
        .files = argv[2],
        .staging = argv[3],
        .output = argv[4],
        .dpkg_deb = "/usr/bin/dpkg-deb",
        .path_variable = "PATH=/usr/bin:/bin",
    };
    char file_name[512];
    char message[1024];
    if (codling_repack(&paths, argv[5], file_name, sizeof file_name, message, sizeof message) != 0) {
        printf("%s\n", message);
        return 1;
    }
    printf("%s\n", file_name);
    return 0;
}

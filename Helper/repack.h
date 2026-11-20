// SPDX-License-Identifier: Apache-2.0
//
// Rebuilds the .deb of an installed package from what dpkg recorded about it
// and the files on disk, so that Codling can put back a package it is about
// to remove or replace. Plain POSIX C: the helper uses it on the device, and
// scripts/test-repack.sh tests it on Linux.

#ifndef CODLING_REPACK_H
#define CODLING_REPACK_H

#include <stddef.h>

struct codling_repack_paths {
    // dpkg's database: the directory holding status and info/.
    const char *admin;
    // Prepended to every path dpkg lists, to read the package's files: "" on
    // the device, where the lists hold real paths; a test root on Linux.
    const char *files;
    // An empty directory the package is staged in; it is removed afterwards.
    const char *staging;
    // Where the .deb is written.
    const char *output;
    // The dpkg-deb program, and the PATH it runs with.
    const char *dpkg_deb;
    const char *path_variable;
};

// Rebuilds package into paths->output as name_version_architecture.deb, with
// ":" in the version written as "%3a" as apt does, and writes that file name
// to file_name. Returns 0, or -1 with a reason in message.
int codling_repack(const struct codling_repack_paths *paths, const char *package, char *file_name,
                   size_t file_name_size, char *message, size_t message_size);

// The installed version of package, from the status file; 0 when found.
int codling_installed_version(const char *admin, const char *package, char *version, size_t version_size,
                              char *architecture, size_t architecture_size);

// version as it appears in a backup's file name.
void codling_escape_version(const char *version, char *escaped, size_t escaped_size);

// Removes a directory tree without following links; 0 when gone.
int codling_remove_tree(const char *path);

#endif

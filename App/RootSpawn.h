// SPDX-License-Identifier: Apache-2.0
//
// Starts Codling's helper as root and collects what it prints.

#ifndef CODLING_ROOT_SPAWN_H
#define CODLING_ROOT_SPAWN_H

#include <stdbool.h>
#include <stddef.h>

struct codling_result {
    // The helper's exit status, or minus the signal that ended it.
    int status;
    // 0, or the errno posix_spawn failed with.
    int spawn_error;
    // Whether the helper ran past the timeout and was killed.
    bool timed_out;
    // What it printed, each up to 1 MiB; free with codling_result_free.
    char *output;
    size_t output_length;
    char *errors;
    size_t errors_length;
};

// Runs path as root with arguments (arguments[0] is the program name; the
// list ends with NULL), stdin from /dev/null, a fixed environment and no other
// open files. Returns 0 when it ran, or -1 when it could not start
// (spawn_error says why).
int codling_run_as_root(const char *path, const char *const *arguments, int timeout_ms,
                        struct codling_result *result);

void codling_result_free(struct codling_result *result);

#endif

// SPDX-License-Identifier: Apache-2.0

#include "RootSpawn.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

// Spawn personas, from the private part of the system's spawn interface. A
// process with the com.apple.private.persona-mgmt entitlement can start
// another as any user; 99 is the system persona.
#define CODLING_PERSONA_SYSTEM 99
#define CODLING_PERSONA_FLAGS_OVERRIDE 1
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *attributes, uid_t persona, uint32_t flags);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *attributes, uid_t uid);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *attributes, gid_t gid);

enum { output_limit = 1 << 20 };

struct buffer {
    char *data;
    size_t length;
    size_t capacity;
};

// Keeps up to output_limit bytes; the rest is read and dropped.
static void append(struct buffer *buffer, const char *data, size_t length) {
    if (buffer->length + length > output_limit) {
        length = output_limit - buffer->length;
    }
    if (length == 0) {
        return;
    }
    if (buffer->length + length + 1 > buffer->capacity) {
        size_t capacity = buffer->capacity ? buffer->capacity : 4096;
        while (capacity < buffer->length + length + 1) {
            capacity *= 2;
        }
        char *grown = realloc(buffer->data, capacity);
        if (!grown) {
            return;
        }
        buffer->data = grown;
        buffer->capacity = capacity;
    }
    memcpy(buffer->data + buffer->length, data, length);
    buffer->length += length;
    buffer->data[buffer->length] = '\0';
}

static int64_t now_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static void close_pair(int pair[2]) {
    for (int i = 0; i < 2; i++) {
        if (pair[i] >= 0) {
            close(pair[i]);
            pair[i] = -1;
        }
    }
}

int codling_run_as_root(const char *path, const char *const *arguments, int timeout_ms,
                        struct codling_result *result) {
    return codling_run(path, arguments, NULL, true, timeout_ms, result);
}

int codling_run(const char *path, const char *const *arguments, const char *const *environment, bool as_root,
                int timeout_ms, struct codling_result *result) {
    memset(result, 0, sizeof *result);
    int out[2] = { -1, -1 }, err[2] = { -1, -1 };
    if (pipe(out) != 0 || pipe(err) != 0) {
        result->spawn_error = errno;
        close_pair(out);
        close_pair(err);
        return -1;
    }

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_init(&actions);
    posix_spawnattr_init(&attributes);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO);
    // Every other descriptor is closed in the helper.
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (as_root) {
        posix_spawnattr_set_persona_np(&attributes, CODLING_PERSONA_SYSTEM, CODLING_PERSONA_FLAGS_OVERRIDE);
        posix_spawnattr_set_persona_uid_np(&attributes, 0);
        posix_spawnattr_set_persona_gid_np(&attributes, 0);
    }

    char *const fixed[] = { "PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL };
    pid_t pid;
    int spawned = posix_spawn(&pid, path, &actions, &attributes, (char *const *)arguments,
                              environment ? (char *const *)environment : fixed);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    close(out[1]);
    close(err[1]);
    out[1] = err[1] = -1;
    if (spawned != 0) {
        result->spawn_error = spawned;
        close_pair(out);
        close_pair(err);
        return -1;
    }

    struct buffer buffers[2] = { { 0 }, { 0 } };
    struct pollfd fds[2] = { { .fd = out[0], .events = POLLIN }, { .fd = err[0], .events = POLLIN } };
    int open_pipes = 2;
    int64_t deadline = now_ms() + timeout_ms;
    while (open_pipes > 0) {
        int64_t left = deadline - now_ms();
        if (left <= 0) {
            result->timed_out = true;
            kill(pid, SIGKILL);
            break;
        }
        int ready = poll(fds, 2, (int)left);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            kill(pid, SIGKILL);
            break;
        }
        for (int i = 0; i < 2; i++) {
            if (fds[i].fd < 0 || !(fds[i].revents & (POLLIN | POLLHUP | POLLERR))) {
                continue;
            }
            char chunk[4096];
            ssize_t got = read(fds[i].fd, chunk, sizeof chunk);
            if (got > 0) {
                append(&buffers[i], chunk, (size_t)got);
            } else if (got == 0 || errno != EINTR) {
                fds[i].fd = -1;
                open_pipes--;
            }
        }
    }
    close_pair(out);
    close_pair(err);

    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    result->status = WIFEXITED(status) ? WEXITSTATUS(status) : -WTERMSIG(status);
    result->output = buffers[0].data;
    result->output_length = buffers[0].length;
    result->errors = buffers[1].data;
    result->errors_length = buffers[1].length;
    return 0;
}

void codling_result_free(struct codling_result *result) {
    free(result->output);
    free(result->errors);
    result->output = result->errors = NULL;
    result->output_length = result->errors_length = 0;
}

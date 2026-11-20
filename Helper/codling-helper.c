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
//   codling-helper audit   runs dpkg --audit and apt-get check, which only
//                          read, and prints their status and output as JSON.
//   codling-helper configure-pending
//                          runs dpkg --configure -a, which finishes setting
//                          up packages that were unpacked or left half
//                          configured, keeping changed configuration files,
//                          and prints its status and output as JSON.

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <sys/wait.h>
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

enum { output_limit = 1 << 20 };

// Prints a JSON string, escaping what JSON requires.
static void print_json_string(const char *text, size_t length) {
    putchar('"');
    for (size_t i = 0; i < length; i++) {
        unsigned char c = (unsigned char)text[i];
        switch (c) {
        case '"': fputs("\\\"", stdout); break;
        case '\\': fputs("\\\\", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        default:
            if (c < 0x20) {
                printf("\\u%04x", c);
            } else {
                putchar(c);
            }
        }
    }
    putchar('"');
}

// Runs a program from the jailbreak with its output and errors together,
// and prints {"status":N,"output":"..."}.
static void run_and_report(const char *root, const char *program, const char *const *arguments) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s%s", root, program);
    char search[4 * PATH_MAX];
    snprintf(search, sizeof search,
             "PATH=%s/usr/sbin:%s/usr/bin:%s/sbin:%s/bin:/usr/sbin:/usr/bin:/sbin:/bin", root, root, root, root);
    char *const environment[] = { search, "DEBIAN_FRONTEND=noninteractive", "LANG=C", "LC_ALL=C", NULL };

    int pipe_ends[2];
    if (pipe(pipe_ends) != 0) {
        printf("{\"status\":-1,\"output\":\"pipe failed\"}");
        return;
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, pipe_ends[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipe_ends[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipe_ends[0]);
    posix_spawn_file_actions_addclose(&actions, pipe_ends[1]);
    pid_t pid;
    int spawned = posix_spawn(&pid, path, &actions, NULL, (char *const *)arguments, environment);
    posix_spawn_file_actions_destroy(&actions);
    close(pipe_ends[1]);

    char *output = malloc(output_limit);
    size_t length = 0;
    if (spawned == 0 && output) {
        for (;;) {
            char chunk[4096];
            ssize_t got = read(pipe_ends[0], chunk, sizeof chunk);
            if (got < 0 && errno == EINTR) {
                continue;
            }
            if (got <= 0) {
                break;
            }
            size_t keep = (size_t)got;
            if (length + keep > output_limit) {
                keep = output_limit - length;
            }
            memcpy(output + length, chunk, keep);
            length += keep;
        }
    }
    close(pipe_ends[0]);
    int status = -1;
    if (spawned == 0) {
        int raw = 0;
        while (waitpid(pid, &raw, 0) < 0 && errno == EINTR) {
        }
        status = WIFEXITED(raw) ? WEXITSTATUS(raw) : 128 + WTERMSIG(raw);
    }
    printf("{\"status\":%d,\"output\":", status);
    if (spawned != 0) {
        const char *reason = strerror(spawned);
        print_json_string(reason, strlen(reason));
    } else {
        print_json_string(output ? output : "", length);
    }
    putchar('}');
    free(output);
}

static int audit(void) {
    char root[PATH_MAX];
    if (jailbreak_root(root) != 0) {
        puts("{\"error\":\"The helper is not inside Codling.app in a jailbreak root.\"}");
        return 70;
    }
    const char *const dpkg[] = { "dpkg", "--audit", NULL };
    const char *const apt[] = { "apt-get", "check", "-q", NULL };
    fputs("{\"dpkgAudit\":", stdout);
    run_and_report(root, "/usr/bin/dpkg", dpkg);
    fputs(",\"aptCheck\":", stdout);
    run_and_report(root, "/usr/bin/apt-get", apt);
    puts("}");
    return 0;
}

static int configure_pending(void) {
    char root[PATH_MAX];
    if (jailbreak_root(root) != 0) {
        puts("{\"error\":\"The helper is not inside Codling.app in a jailbreak root.\"}");
        return 70;
    }
    // A changed configuration file is kept, and dpkg asks nothing.
    const char *const dpkg[] = { "dpkg", "--configure", "-a", "--force-confdef", "--force-confold", NULL };
    run_and_report(root, "/usr/bin/dpkg", dpkg);
    putchar('\n');
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
    if (argc == 2 && strcmp(argv[1], "audit") == 0) {
        return audit();
    }
    if (argc == 2 && strcmp(argv[1], "configure-pending") == 0) {
        return configure_pending();
    }
    fputs("usage: codling-helper check | audit | configure-pending\n", stderr);
    return 64;
}

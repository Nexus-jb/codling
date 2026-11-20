// SPDX-License-Identifier: Apache-2.0
//
// See repack.h. The steps follow what dpkg records for an installed package:
// its stanza in the status file becomes DEBIAN/control, the maintainer
// scripts kept in info/ go back into DEBIAN/, and the files named in
// info/PACKAGE.list are copied as they are now, then dpkg-deb builds the
// archive.

#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include "repack.h"

#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <limits.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

enum { file_limit = 128 << 20 };

// snprintf for paths: -1 when the result does not fit.
static int format_path(char *out, size_t size, const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    int length = vsnprintf(out, size, format, arguments);
    va_end(arguments);
    return length < 0 || (size_t)length >= size ? -1 : 0;
}

static void say(char *message, size_t size, const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(message, size, format, arguments);
    va_end(arguments);
}

// The whole of a file, with a NUL after it; NULL when it cannot be read.
static char *read_file(const char *path, size_t *length) {
    int descriptor = open(path, O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) {
        return NULL;
    }
    size_t capacity = 1 << 16;
    size_t used = 0;
    char *data = malloc(capacity + 1);
    while (data) {
        if (used == capacity) {
            if (capacity >= file_limit) {
                free(data);
                data = NULL;
                break;
            }
            capacity *= 2;
            char *grown = realloc(data, capacity + 1);
            if (!grown) {
                free(data);
                data = NULL;
                break;
            }
            data = grown;
        }
        ssize_t got = read(descriptor, data + used, capacity - used);
        if (got < 0 && errno == EINTR) {
            continue;
        }
        if (got < 0) {
            free(data);
            data = NULL;
            break;
        }
        if (got == 0) {
            data[used] = '\0';
            if (length) {
                *length = used;
            }
            break;
        }
        used += (size_t)got;
    }
    close(descriptor);
    return data;
}

static int write_all(int descriptor, const char *data, size_t length) {
    while (length > 0) {
        ssize_t wrote = write(descriptor, data, length);
        if (wrote < 0 && errno == EINTR) {
            continue;
        }
        if (wrote <= 0) {
            return -1;
        }
        data += wrote;
        length -= (size_t)wrote;
    }
    return 0;
}

static int write_file(const char *path, const char *data, size_t length, mode_t mode) {
    int descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, mode);
    if (descriptor < 0) {
        return -1;
    }
    int result = write_all(descriptor, data, length);
    if (fchmod(descriptor, mode) != 0) {
        result = -1;
    }
    if (close(descriptor) != 0) {
        result = -1;
    }
    return result;
}

// mkdir -p, for the directories above a staged file.
static int make_parents(const char *path) {
    char copy[PATH_MAX];
    if (format_path(copy, sizeof copy, "%s", path) != 0) {
        return -1;
    }
    for (char *slash = strchr(copy + 1, '/'); slash; slash = strchr(slash + 1, '/')) {
        *slash = '\0';
        if (mkdir(copy, 0755) != 0 && errno != EEXIST) {
            return -1;
        }
        *slash = '/';
    }
    return 0;
}

// The stanza for package in a status file, when it is installed.
static int find_stanza(const char *status, const char *package, const char **start, size_t *length) {
    size_t name_length = strlen(package);
    const char *cursor = status;
    while (*cursor) {
        const char *end = strstr(cursor, "\n\n");
        size_t size = end ? (size_t)(end - cursor) + 1 : strlen(cursor);
        // "Package: NAME" on the stanza's first line, exactly.
        const char *line = cursor;
        while (line < cursor + size) {
            const char *line_end = memchr(line, '\n', (size_t)(cursor + size - line));
            if (!line_end) {
                line_end = cursor + size;
            }
            size_t line_length = (size_t)(line_end - line);
            if (line_length == 9 + name_length && strncmp(line, "Package: ", 9) == 0
                && strncmp(line + 9, package, name_length) == 0) {
                // Installed means a Status line that ends in " installed".
                const char *status_line = strstr(cursor, "\nStatus: ");
                if (status_line && status_line < cursor + size) {
                    const char *status_end = memchr(status_line + 1, '\n', (size_t)(cursor + size - status_line - 1));
                    if (!status_end) {
                        status_end = cursor + size;
                    }
                    if (status_end - status_line > 10 && strncmp(status_end - 10, " installed", 10) == 0) {
                        *start = cursor;
                        *length = size;
                        return 0;
                    }
                }
                break;
            }
            line = line_end + 1;
        }
        if (!end) {
            break;
        }
        cursor = end + 2;
        while (*cursor == '\n') {
            cursor++;
        }
    }
    return -1;
}

// A field's single-line value from a stanza.
static int field_value(const char *stanza, size_t length, const char *name, char *value, size_t size) {
    size_t name_length = strlen(name);
    const char *line = stanza;
    while (line < stanza + length) {
        const char *end = memchr(line, '\n', (size_t)(stanza + length - line));
        if (!end) {
            end = stanza + length;
        }
        if ((size_t)(end - line) > name_length + 1 && strncmp(line, name, name_length) == 0 && line[name_length] == ':') {
            const char *text = line + name_length + 1;
            while (text < end && (*text == ' ' || *text == '\t')) {
                text++;
            }
            size_t text_length = (size_t)(end - text);
            if (text_length + 1 > size) {
                return -1;
            }
            memcpy(value, text, text_length);
            value[text_length] = '\0';
            return 0;
        }
        line = end + 1;
    }
    return -1;
}

int codling_installed_version(const char *admin, const char *package, char *version, size_t version_size,
                              char *architecture, size_t architecture_size) {
    char path[PATH_MAX];
    char *status = format_path(path, sizeof path, "%s/status", admin) == 0 ? read_file(path, NULL) : NULL;
    if (!status) {
        return -1;
    }
    const char *stanza;
    size_t length;
    int result = -1;
    if (find_stanza(status, package, &stanza, &length) == 0
        && field_value(stanza, length, "Version", version, version_size) == 0
        && field_value(stanza, length, "Architecture", architecture, architecture_size) == 0) {
        result = 0;
    }
    free(status);
    return result;
}

void codling_escape_version(const char *version, char *escaped, size_t escaped_size) {
    size_t used = 0;
    for (const char *c = version; *c && used + 4 < escaped_size; c++) {
        if (*c == ':') {
            memcpy(escaped + used, "%3a", 3);
            used += 3;
        } else {
            escaped[used++] = *c;
        }
    }
    escaped[used] = '\0';
}

static int remove_entry(const char *path, const struct stat *info, int type, struct FTW *walk) {
    (void)info;
    (void)walk;
    return (type == FTW_DP ? rmdir(path) : unlink(path)) == 0 || errno == ENOENT ? 0 : -1;
}

int codling_remove_tree(const char *path) {
    struct stat info;
    if (lstat(path, &info) != 0) {
        return errno == ENOENT ? 0 : -1;
    }
    return nftw(path, remove_entry, 16, FTW_DEPTH | FTW_PHYS);
}

// The control file: the status stanza without what only dpkg's database
// holds.
static int write_control(const char *stanza, size_t length, const char *path) {
    static const char *const dropped[] = { "Status", "Config-Version", "Conffiles", NULL };
    char *control = malloc(length + 2);
    if (!control) {
        return -1;
    }
    size_t used = 0;
    int skipping = 0;
    const char *line = stanza;
    while (line < stanza + length) {
        const char *end = memchr(line, '\n', (size_t)(stanza + length - line));
        if (!end) {
            end = stanza + length;
        }
        size_t line_length = (size_t)(end - line);
        if (line_length > 0 && line[0] != ' ' && line[0] != '\t') {
            skipping = 0;
            for (int i = 0; dropped[i]; i++) {
                size_t name_length = strlen(dropped[i]);
                if (line_length > name_length && strncmp(line, dropped[i], name_length) == 0 && line[name_length] == ':') {
                    skipping = 1;
                }
            }
        }
        if (!skipping && line_length > 0) {
            memcpy(control + used, line, line_length);
            used += line_length;
            control[used++] = '\n';
        }
        line = end + 1;
    }
    int result = write_file(path, control, used, 0644);
    free(control);
    return result;
}

// The conffiles that are still on disk: dpkg-deb refuses a conffile the
// package does not hold. Taken from info/PACKAGE.conffiles, or else from the
// stanza's Conffiles field.
static int write_conffiles(const char *stanza, size_t length, const char *info_path, const char *staged,
                           const char *path) {
    size_t list_length = 0;
    char *list = read_file(info_path, &list_length);
    char *from_stanza = NULL;
    if (!list) {
        const char *field = strstr(stanza, "\nConffiles:");
        if (!field || field >= stanza + length) {
            return 0;
        }
        from_stanza = malloc(length + 1);
        if (!from_stanza) {
            return -1;
        }
        size_t used = 0;
        const char *line = strchr(field + 1, '\n');
        while (line && line + 1 < stanza + length && (line[1] == ' ' || line[1] == '\t')) {
            const char *start = line + 2;
            const char *end = memchr(start, '\n', (size_t)(stanza + length - start));
            if (!end) {
                end = stanza + length;
            }
            const char *space = memchr(start, ' ', (size_t)(end - start));
            if (space && !memmem(space, (size_t)(end - space), "obsolete", 8)) {
                memcpy(from_stanza + used, start, (size_t)(space - start));
                used += (size_t)(space - start);
                from_stanza[used++] = '\n';
            }
            line = end < stanza + length ? end : NULL;
        }
        from_stanza[used] = '\0';
        list = from_stanza;
        list_length = used;
    }
    char *kept = malloc(list_length + 2);
    size_t used = 0;
    for (char *line = list; kept && line && *line;) {
        char *end = strchr(line, '\n');
        size_t line_length = end ? (size_t)(end - line) : strlen(line);
        // A conffile line may carry flags after the path ("remove-on-upgrade").
        char entry[PATH_MAX];
        size_t entry_length = 0;
        while (entry_length < line_length && line[entry_length] != ' ' && entry_length + 1 < sizeof entry) {
            entry[entry_length] = line[entry_length];
            entry_length++;
        }
        entry[entry_length] = '\0';
        char staged_path[PATH_MAX];
        struct stat info;
        if (entry_length > 1 && entry[0] == '/' && memmem(line, line_length, "remove-on-upgrade", 17) == NULL
            && format_path(staged_path, sizeof staged_path, "%s%s", staged, entry) == 0
            && lstat(staged_path, &info) == 0 && S_ISREG(info.st_mode)) {
            memcpy(kept + used, entry, entry_length);
            used += entry_length;
            kept[used++] = '\n';
        }
        line = end ? end + 1 : NULL;
    }
    int result = 0;
    if (!kept) {
        result = -1;
    } else if (used > 0) {
        result = write_file(path, kept, used, 0644);
    }
    free(kept);
    free(list);
    return result;
}

static int copy_regular(const char *source, const char *target, const struct stat *info) {
    int input = open(source, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (input < 0) {
        return -1;
    }
    int output = open(target, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (output < 0) {
        close(input);
        return -1;
    }
    int result = 0;
    char buffer[1 << 16];
    for (;;) {
        ssize_t got = read(input, buffer, sizeof buffer);
        if (got < 0 && errno == EINTR) {
            continue;
        }
        if (got < 0) {
            result = -1;
            break;
        }
        if (got == 0) {
            break;
        }
        if (write_all(output, buffer, (size_t)got) != 0) {
            result = -1;
            break;
        }
    }
    // Owner first: changing it clears the set-ID bits.
    if (fchown(output, info->st_uid, info->st_gid) != 0) {
        // Not root, as in the tests: the files stay the caller's.
    }
    if (fchmod(output, info->st_mode & 07777) != 0) {
        result = -1;
    }
    close(input);
    if (close(output) != 0) {
        result = -1;
    }
    return result;
}

// Whether another listed path lies below path: then path is a directory of
// the package even where the disk has a link (as /var/jb is on rootless).
static int has_children(char **entries, size_t count, const char *path) {
    size_t length = strlen(path);
    for (size_t i = 0; i < count; i++) {
        if (strncmp(entries[i], path, length) == 0 && entries[i][length] == '/') {
            return 1;
        }
    }
    return 0;
}

static int stage_files(const struct codling_repack_paths *paths, const char *list_path, const char *staged,
                       char *message, size_t message_size) {
    size_t length = 0;
    char *list = read_file(list_path, &length);
    if (!list) {
        say(message, message_size, "dpkg has no file list for this package");
        return -1;
    }
    size_t count = 0;
    for (size_t i = 0; i < length; i++) {
        count += list[i] == '\n';
    }
    char **entries = calloc(count + 1, sizeof *entries);
    if (!entries) {
        free(list);
        say(message, message_size, "out of memory");
        return -1;
    }
    size_t used = 0;
    for (char *line = list; *line && used <= count;) {
        char *end = strchr(line, '\n');
        if (end) {
            *end = '\0';
        }
        if (line[0] == '/' && strcmp(line, "/.") != 0 && strstr(line, "/../") == NULL) {
            entries[used++] = line;
        }
        line = end ? end + 1 : line + strlen(line);
    }
    int result = 0;
    for (size_t i = 0; i < used && result == 0; i++) {
        char source[PATH_MAX];
        char target[PATH_MAX];
        if (format_path(source, sizeof source, "%s%s", paths->files, entries[i]) != 0
            || format_path(target, sizeof target, "%s%s", staged, entries[i]) != 0) {
            say(message, message_size, "a path is too long: %s", entries[i]);
            result = -1;
            break;
        }
        struct stat info;
        if (lstat(source, &info) != 0) {
            // Deleted since it was installed: the backup goes without it.
            continue;
        }
        if (make_parents(target) != 0) {
            say(message, message_size, "cannot create the directories for %s", entries[i]);
            result = -1;
            break;
        }
        if (S_ISLNK(info.st_mode) && has_children(entries, used, entries[i])) {
            if (stat(source, &info) != 0 || !S_ISDIR(info.st_mode)) {
                continue;
            }
        }
        if (S_ISDIR(info.st_mode)) {
            if (mkdir(target, 0755) != 0 && errno != EEXIST) {
                say(message, message_size, "cannot create %s", entries[i]);
                result = -1;
            } else {
                if (chown(target, info.st_uid, info.st_gid) != 0) {
                    // Not root, as in the tests.
                }
                chmod(target, info.st_mode & 07777);
            }
        } else if (S_ISLNK(info.st_mode)) {
            char link[PATH_MAX];
            ssize_t link_length = readlink(source, link, sizeof link - 1);
            if (link_length < 0) {
                say(message, message_size, "cannot read the link %s", entries[i]);
                result = -1;
                break;
            }
            link[link_length] = '\0';
            unlink(target);
            if (symlink(link, target) != 0) {
                say(message, message_size, "cannot copy the link %s", entries[i]);
                result = -1;
            } else if (lchown(target, info.st_uid, info.st_gid) != 0) {
                // Not root, as in the tests.
            }
        } else if (S_ISREG(info.st_mode)) {
            if (copy_regular(source, target, &info) != 0) {
                say(message, message_size, "cannot copy %s: %s", entries[i], strerror(errno));
                result = -1;
            }
        }
    }
    free(entries);
    free(list);
    return result;
}

// Runs dpkg-deb, keeping the start of what it prints for the message.
static int build(const struct codling_repack_paths *paths, const char *staged, const char *target, char *message,
                 size_t message_size) {
    char *const arguments[] = { "dpkg-deb", "-Zgzip", "-b", (char *)staged, (char *)target, NULL };
    char *environment[] = { (char *)paths->path_variable, "LANG=C", "LC_ALL=C", NULL };
    int pipe_ends[2];
    if (pipe(pipe_ends) != 0) {
        say(message, message_size, "pipe failed");
        return -1;
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, pipe_ends[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipe_ends[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipe_ends[0]);
    posix_spawn_file_actions_addclose(&actions, pipe_ends[1]);
    pid_t pid;
    int spawned = posix_spawn(&pid, paths->dpkg_deb, &actions, NULL, arguments, environment);
    posix_spawn_file_actions_destroy(&actions);
    close(pipe_ends[1]);
    char output[1024];
    size_t used = 0;
    for (;;) {
        char chunk[512];
        ssize_t got = read(pipe_ends[0], chunk, sizeof chunk);
        if (got < 0 && errno == EINTR) {
            continue;
        }
        if (got <= 0) {
            break;
        }
        size_t keep = (size_t)got < sizeof output - 1 - used ? (size_t)got : sizeof output - 1 - used;
        memcpy(output + used, chunk, keep);
        used += keep;
    }
    output[used] = '\0';
    close(pipe_ends[0]);
    if (spawned != 0) {
        say(message, message_size, "dpkg-deb could not start: %s", strerror(spawned));
        return -1;
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        while (used > 0 && (output[used - 1] == '\n' || output[used - 1] == ' ')) {
            output[--used] = '\0';
        }
        say(message, message_size, "dpkg-deb failed: %s", used ? output : "no output");
        return -1;
    }
    return 0;
}

int codling_repack(const struct codling_repack_paths *paths, const char *package, char *file_name,
                   size_t file_name_size, char *message, size_t message_size) {
    char status_path[PATH_MAX];
    char *status = format_path(status_path, sizeof status_path, "%s/status", paths->admin) == 0
        ? read_file(status_path, NULL) : NULL;
    if (!status) {
        say(message, message_size, "cannot read dpkg's status file");
        return -1;
    }
    const char *stanza;
    size_t length;
    char version[256];
    char architecture[64];
    if (find_stanza(status, package, &stanza, &length) != 0) {
        free(status);
        say(message, message_size, "the package is not installed");
        return -1;
    }
    if (field_value(stanza, length, "Version", version, sizeof version) != 0
        || field_value(stanza, length, "Architecture", architecture, sizeof architecture) != 0) {
        free(status);
        say(message, message_size, "the package has no version or architecture");
        return -1;
    }

    char staged[PATH_MAX];
    char debian[PATH_MAX];
    if (format_path(staged, sizeof staged, "%s/%s", paths->staging, package) != 0
        || format_path(debian, sizeof debian, "%s/DEBIAN", staged) != 0) {
        free(status);
        say(message, message_size, "the staging path is too long");
        return -1;
    }
    codling_remove_tree(staged);
    int result = -1;
    if (mkdir(paths->staging, 0755) != 0 && errno != EEXIST) {
        say(message, message_size, "cannot create the staging directory");
    } else if (mkdir(staged, 0755) != 0 || mkdir(debian, 0755) != 0) {
        say(message, message_size, "cannot create the staging directory");
    } else {
        char path[PATH_MAX];
        result = format_path(path, sizeof path, "%s/info/%s.list", paths->admin, package);
        if (result == 0) {
            result = stage_files(paths, path, staged, message, message_size);
        } else {
            say(message, message_size, "a path is too long");
        }
        if (result == 0) {
            result = format_path(path, sizeof path, "%s/control", debian);
            result = result == 0 ? write_control(stanza, length, path) : -1;
            if (result != 0) {
                say(message, message_size, "cannot write the control file");
            }
        }
        if (result == 0) {
            char info_path[PATH_MAX];
            result = format_path(info_path, sizeof info_path, "%s/info/%s.conffiles", paths->admin, package) == 0
                && format_path(path, sizeof path, "%s/conffiles", debian) == 0
                ? write_conffiles(stanza, length, info_path, staged, path) : -1;
            if (result != 0) {
                say(message, message_size, "cannot write the conffiles");
            }
        }
        static const char *const scripts[] = { "preinst", "postinst", "prerm", "postrm", "config", NULL };
        static const char *const others[] = { "triggers", "shlibs", "symbols", "templates", NULL };
        for (int kind = 0; kind < 2 && result == 0; kind++) {
            const char *const *names = kind == 0 ? scripts : others;
            for (int i = 0; names[i] && result == 0; i++) {
                char source[PATH_MAX];
                if (format_path(source, sizeof source, "%s/info/%s.%s", paths->admin, package, names[i]) != 0
                    || format_path(path, sizeof path, "%s/%s", debian, names[i]) != 0) {
                    say(message, message_size, "a path is too long");
                    result = -1;
                    break;
                }
                size_t size = 0;
                char *data = read_file(source, &size);
                if (!data) {
                    continue;
                }
                if (write_file(path, data, size, kind == 0 ? 0755 : 0644) != 0) {
                    say(message, message_size, "cannot copy the %s script", names[i]);
                    result = -1;
                }
                free(data);
            }
        }
        if (result == 0) {
            char escaped[512];
            codling_escape_version(version, escaped, sizeof escaped);
            char target[PATH_MAX];
            char partial[PATH_MAX];
            if (format_path(file_name, file_name_size, "%s_%s_%s.deb", package, escaped, architecture) != 0
                || format_path(target, sizeof target, "%s/%s", paths->output, file_name) != 0
                || format_path(partial, sizeof partial, "%s.part", target) != 0) {
                say(message, message_size, "the backup's name is too long");
                result = -1;
            } else {
                result = build(paths, staged, partial, message, message_size);
                if (result == 0 && rename(partial, target) != 0) {
                    say(message, message_size, "cannot keep the backup: %s", strerror(errno));
                    result = -1;
                }
                if (result != 0) {
                    unlink(partial);
                }
            }
        }
    }
    codling_remove_tree(staged);
    free(status);
    return result;
}

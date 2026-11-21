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
//   codling-helper update-lists
//                          runs apt-get update, so that apt knows the
//                          packages Codling shows. Sources that are not
//                          signed are read too, as other package managers
//                          do; Codling warns about their packages before
//                          installing them.
//   codling-helper simulate OPERATION...
//                          runs apt-get install -s, which works out what a
//                          change would do and changes nothing. An operation
//                          is +package (install or upgrade) or -package
//                          (remove).
//   codling-helper apply [--trust-unsigned] [--allow-removals] OPERATION...
//                          makes the change with apt-get install -y. Without
//                          --trust-unsigned, packages from sources that are
//                          not signed are refused; without --allow-removals,
//                          a change that would remove packages the operations
//                          do not name is refused. Essential packages are
//                          never removed.
//   codling-helper respring
//                          restarts SpringBoard, so that tweaks load.
//   codling-helper backup PACKAGE...
//                          rebuilds the .deb of each installed package from
//                          dpkg's database and the files on disk (repack.c),
//                          into JAILBREAK/var/lib/codling/backups, which only
//                          root can write, so that undo can put it back. The
//                          newest backups are kept; older ones are deleted.
//   codling-helper add-source URI
//                          adds a flat repository to JAILBREAK/etc/apt/
//                          sources.list.d/codling.sources, the only sources
//                          file Codling writes. URI is http:// or https://, a
//                          host in lower case and a path ending in "/", with
//                          nothing in it that apt or a shell could read
//                          another way.
//   codling-helper remove-source URI
//                          takes the repository at URI out of every sources
//                          file apt reads: a deb822 stanza, or the address in
//                          a stanza with several, and a one-line "deb" entry.
//                          Comments and the other sources stay. An emptied
//                          codling.sources is deleted; other files stay, as
//                          their package manager may own them.
//   codling-helper take-purchase PACKAGE VERSION
//                          takes the .deb Codling downloaded after a
//                          purchase from its caches (PACKAGE_VERSION.deb in
//                          purchase_inbox below, a name the helper makes
//                          itself), checks it against the SHA256 hash apt
//                          lists for that version, and keeps it in
//                          JAILBREAK/var/lib/codling/purchases, which only
//                          root can write. The download is deleted either
//                          way.
//   codling-helper burrow-state
//                          runs Burrow's burrowctl json, which prints the
//                          tweak loader in use, the loader settings, every
//                          tweak and Safe Mode's events, and prints its status
//                          and output as JSON. It changes nothing.
//   codling-helper burrow-tweak on|off TWEAK [PROCESS]
//                          turns a tweak back on or off with burrowctl enable
//                          or disable, in the process PROCESS (a bundle
//                          identifier or an executable name), or everywhere
//                          with PROCESS "*". Without PROCESS, on means
//                          wherever it is off. TWEAK may be "*", every tweak.
//   codling-helper burrow-loader burrow|ellekit
//                          makes Burrow's or ElleKit's loader the one that
//                          loads tweaks into new processes, with burrowctl
//                          loader. Burrow's guard goes back to ElleKit's by
//                          itself when Burrow's loader crashes.
//
// Operations name packages only: letters, digits, "+", "-" and ".", starting
// with a letter or digit and ending with a letter, a digit or "+". A third
// operation, @package=version, installs that version from its backup, and a
// fourth, $package=version, installs a purchased package that take-purchase
// checked; the version is checked too, and the helper finds the file itself.
// Nothing else from the caller reaches apt.

#include "repack.h"
#include "sha256.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#else
// Linux, where scripts/test-sources.sh tests parts of the helper; its driver
// provides this.
int _NSGetExecutablePath(char *buffer, uint32_t *size);
#endif
#include <spawn.h>
#include <sys/wait.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
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

// Runs a program from the jailbreak with its output and errors together.
// Returns its exit status, or -1 when it did not start. *output holds what
// it printed, at most output_limit bytes, or why it did not start; the
// caller frees it.
static int run_collect(const char *root, const char *program, const char *const *arguments, char **output,
                       size_t *length) {
    *length = 0;
    *output = malloc(output_limit);
    if (!*output) {
        return -1;
    }
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s%s", root, program);
    char search[4 * PATH_MAX];
    snprintf(search, sizeof search,
             "PATH=%s/usr/sbin:%s/usr/bin:%s/sbin:%s/bin:/usr/sbin:/usr/bin:/sbin:/bin", root, root, root, root);
    char *const environment[] = { search, "DEBIAN_FRONTEND=noninteractive", "LANG=C", "LC_ALL=C", NULL };

    int pipe_ends[2];
    if (pipe(pipe_ends) != 0) {
        *length = (size_t)snprintf(*output, output_limit, "pipe failed");
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
    int spawned = posix_spawn(&pid, path, &actions, NULL, (char *const *)arguments, environment);
    posix_spawn_file_actions_destroy(&actions);
    close(pipe_ends[1]);
    if (spawned != 0) {
        close(pipe_ends[0]);
        *length = (size_t)snprintf(*output, output_limit, "%s", strerror(spawned));
        return -1;
    }

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
        if (*length + keep > output_limit) {
            keep = output_limit - *length;
        }
        memcpy(*output + *length, chunk, keep);
        *length += keep;
    }
    close(pipe_ends[0]);
    int raw = 0;
    while (waitpid(pid, &raw, 0) < 0 && errno == EINTR) {
    }
    return WIFEXITED(raw) ? WEXITSTATUS(raw) : 128 + WTERMSIG(raw);
}

// Runs a program from the jailbreak with its output and errors together,
// and prints {"status":N,"output":"..."}.
static void run_and_report(const char *root, const char *program, const char *const *arguments) {
    char *output = NULL;
    size_t length = 0;
    int status = run_collect(root, program, arguments, &output, &length);
    printf("{\"status\":%d,\"output\":", status);
    print_json_string(output ? output : "", length);
    putchar('}');
    free(output);
}

// Exits with the error JSON when the helper is not where Codling installs it.
static void require_root(char root[PATH_MAX]) {
    if (jailbreak_root(root) != 0) {
        puts("{\"error\":\"The helper is not inside Codling.app in a jailbreak root.\"}");
        exit(70);
    }
}

static void usage_error(const char *message) {
    printf("{\"error\":");
    print_json_string(message, strlen(message));
    puts("}");
    fprintf(stderr, "%s\n", message);
    exit(64);
}

// Prints {"error":...} and the message, and exits with status 1: the
// command was understood but could not be done.
static void failure(const char *message) {
    printf("{\"error\":");
    print_json_string(message, strlen(message));
    puts("}");
    fprintf(stderr, "%s\n", message);
    exit(1);
}

enum { name_limit = 128, operation_limit = 200, backups_kept = 60 };

static const char backups_suffix[] = "/var/lib/codling/backups";

// A package name as dpkg accepts it, kept to what cannot be read as an
// option, a pattern or a path.
static int valid_package(const char *name) {
    size_t length = strlen(name);
    if (length < 2 || length > name_limit) {
        return 0;
    }
    for (size_t i = 0; i < length; i++) {
        char c = name[i];
        int alnum = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
        if (!alnum && c != '+' && c != '-' && c != '.') {
            return 0;
        }
        if (i == 0 && !alnum) {
            return 0;
        }
        if (i == length - 1 && !alnum && c != '+') {
            return 0;
        }
    }
    return 1;
}

// A Debian version: a digit first, then letters, digits and ".+~:-".
static int valid_version(const char *version) {
    size_t length = strlen(version);
    if (length < 1 || length > 128 || version[0] < '0' || version[0] > '9') {
        return 0;
    }
    for (size_t i = 0; i < length; i++) {
        char c = version[i];
        int alnum = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
        if (!alnum && !strchr(".+~:-", c)) {
            return 0;
        }
    }
    return 1;
}

enum { backup_path_size = PATH_MAX };

// Splits name=version into the package name, in package, and the version,
// checking both. 0 when they are valid.
static int split_versioned(const char *text, char package[name_limit + 1], const char **version) {
    const char *equals = strchr(text, '=');
    size_t name_length = equals ? (size_t)(equals - text) : 0;
    if (!equals || name_length > name_limit) {
        return -1;
    }
    memcpy(package, text, name_length);
    package[name_length] = '\0';
    if (!valid_package(package) || !valid_version(equals + 1)) {
        return -1;
    }
    *version = equals + 1;
    return 0;
}

static const char purchases_suffix[] = "/var/lib/codling/purchases";

// Where Codling, which runs as mobile, leaves a package it downloaded after
// a purchase. The helper takes it from here into purchases_suffix.
static const char purchase_inbox[] = "/var/mobile/Library/Caches/com.nexusjb.codling/purchases";

enum { mobile_uid = 501, sha256_hex_size = 65, hashes_limit = 16 };

// A purchased package's file name: NAME_VERSION.deb, with ":" in the
// version escaped as in backups. 0 when it fits.
static int purchase_file_name(const char *name, const char *version, char *file, size_t size) {
    char escaped[512];
    codling_escape_version(version, escaped, sizeof escaped);
    int written = snprintf(file, size, "%s_%s.deb", name, escaped);
    return written > 0 && (size_t)written < size ? 0 : -1;
}

// The checked copy of a purchased package. 0 when it exists.
static int purchase_path(const char *root, const char *name, const char *version, char path[backup_path_size]) {
    char file[NAME_MAX + 1];
    struct stat info;
    if (purchase_file_name(name, version, file, sizeof file) != 0) {
        return -1;
    }
    int written = snprintf(path, backup_path_size, "%s%s/%s", root, purchases_suffix, file);
    if (written < 0 || written >= backup_path_size) {
        return -1;
    }
    return lstat(path, &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == 0 ? 0 : -1;
}

// The SHA256 fields of the records apt-cache show printed, in lower case.
// Returns how many it found, at most limit.
static size_t listed_sha256(const char *text, size_t length, char hashes[][sha256_hex_size], size_t limit) {
    static const char field[] = "SHA256:";
    const size_t field_length = sizeof field - 1;
    size_t found = 0;
    size_t start = 0;
    while (start < length && found < limit) {
        size_t end = start;
        while (end < length && text[end] != '\n') {
            end++;
        }
        if (end - start > field_length && strncmp(text + start, field, field_length) == 0) {
            size_t first = start + field_length;
            size_t last = end;
            while (first < last && (text[first] == ' ' || text[first] == '\t')) {
                first++;
            }
            while (last > first && (text[last - 1] == ' ' || text[last - 1] == '\t' || text[last - 1] == '\r')) {
                last--;
            }
            int valid = last - first == 64;
            for (size_t i = 0; valid && i < 64; i++) {
                char c = (char)tolower((unsigned char)text[first + i]);
                valid = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
                hashes[found][i] = c;
            }
            if (valid) {
                hashes[found][64] = '\0';
                found++;
            }
        }
        start = end + 1;
    }
    return found;
}

// The backup of name at version: NAME_VERSION_ARCH.deb in the backups
// directory, found by listing it. 0 when it exists.
static int backup_path(const char *root, const char *name, const char *version, char path[backup_path_size]) {
    char directory[PATH_MAX];
    snprintf(directory, sizeof directory, "%s%s", root, backups_suffix);
    char escaped[512];
    codling_escape_version(version, escaped, sizeof escaped);
    char prefix[name_limit + 520];
    snprintf(prefix, sizeof prefix, "%s_%s_", name, escaped);
    DIR *listing = opendir(directory);
    if (!listing) {
        return -1;
    }
    int found = -1;
    struct dirent *entry;
    while ((entry = readdir(listing)) != NULL) {
        size_t length = strlen(entry->d_name);
        if (strncmp(entry->d_name, prefix, strlen(prefix)) == 0 && length > 4
            && strcmp(entry->d_name + length - 4, ".deb") == 0 && !strchr(entry->d_name + strlen(prefix), '_')) {
            snprintf(path, backup_path_size, "%s/%s", directory, entry->d_name);
            found = 0;
            break;
        }
    }
    closedir(listing);
    return found;
}

// Turns operations into apt-get install arguments: +name installs name,
// -name removes it (name-), @name=version installs the backup's file, and
// $name=version the checked download of a purchased package. The
// strings stay owned by argv or the buffer. Sets *restores when any
// operation restores a backup.
static size_t add_operations(const char *root, int count, char **operations, const char **arguments, size_t used,
                             char buffer[][backup_path_size], int *restores) {
    if (count < 1) {
        usage_error("No operations were given.");
    }
    if (count > operation_limit) {
        usage_error("Too many operations at once.");
    }
    for (int i = 0; i < count; i++) {
        const char *operation = operations[i];
        char kind = operation[0];
        const char *name = operation + (kind ? 1 : 0);
        if (kind == '@') {
            char package[name_limit + 1];
            const char *version;
            if (split_versioned(name, package, &version) != 0) {
                usage_error("A restore is not @package=version with a valid package and version.");
            }
            if (backup_path(root, package, version, buffer[i]) != 0) {
                usage_error("There is no backup of that version of the package.");
            }
            arguments[used++] = buffer[i];
            *restores = 1;
            continue;
        }
        if (kind == '$') {
            char package[name_limit + 1];
            const char *version;
            if (split_versioned(name, package, &version) != 0) {
                usage_error("A purchase is not $package=version with a valid package and version.");
            }
            if (purchase_path(root, package, version, buffer[i]) != 0) {
                usage_error("Codling has no checked download of that version of the purchased package.");
            }
            arguments[used++] = buffer[i];
            continue;
        }
        if ((kind != '+' && kind != '-') || !valid_package(name)) {
            usage_error("An operation is not +package, -package, @package=version or $package=version with valid names.");
        }
        if (kind == '+') {
            arguments[used++] = name;
        } else {
            snprintf(buffer[i], backup_path_size, "%s-", name);
            arguments[used++] = buffer[i];
        }
    }
    return used;
}

static int update_lists(void) {
    char root[PATH_MAX];
    require_root(root);
    const char *const apt[] = { "apt-get", "update", "-q", "-o", "Acquire::AllowInsecureRepositories=true", NULL };
    run_and_report(root, "/usr/bin/apt-get", apt);
    putchar('\n');
    return 0;
}

static int simulate(int count, char **operations) {
    char root[PATH_MAX];
    require_root(root);
    static char buffer[operation_limit][backup_path_size];
    const char *arguments[operation_limit + 8];
    size_t used = 0;
    int restores = 0;
    arguments[used++] = "apt-get";
    arguments[used++] = "install";
    arguments[used++] = "-s";
    arguments[used++] = "-q";
    // Set below when an operation restores a backup, which may be older.
    size_t downgrades = used++;
    arguments[downgrades] = "-q";
    used = add_operations(root, count, operations, arguments, used, buffer, &restores);
    if (restores) {
        arguments[downgrades] = "--allow-downgrades";
    }
    arguments[used] = NULL;
    run_and_report(root, "/usr/bin/apt-get", arguments);
    putchar('\n');
    return 0;
}

static int apply(int count, char **words) {
    char root[PATH_MAX];
    require_root(root);
    int trust_unsigned = 0;
    int allow_removals = 0;
    int first = 0;
    while (first < count && words[first][0] == '-' && words[first][1] == '-') {
        if (strcmp(words[first], "--trust-unsigned") == 0) {
            trust_unsigned = 1;
        } else if (strcmp(words[first], "--allow-removals") == 0) {
            allow_removals = 1;
        } else {
            usage_error("Unknown option for apply.");
        }
        first++;
    }
    static char buffer[operation_limit][backup_path_size];
    const char *arguments[operation_limit + 16];
    size_t used = 0;
    int restores = 0;
    arguments[used++] = "apt-get";
    arguments[used++] = "install";
    arguments[used++] = "-y";
    arguments[used++] = "-q";
    size_t downgrades = used++;
    arguments[downgrades] = "-q";
    // A changed configuration file is kept, and dpkg asks nothing.
    arguments[used++] = "-o";
    arguments[used++] = "Dpkg::Options::=--force-confdef";
    arguments[used++] = "-o";
    arguments[used++] = "Dpkg::Options::=--force-confold";
    if (trust_unsigned) {
        arguments[used++] = "--allow-unauthenticated";
    }
    if (!allow_removals) {
        arguments[used++] = "--no-remove";
    }
    used = add_operations(root, count - first, words + first, arguments, used, buffer, &restores);
    if (restores) {
        arguments[downgrades] = "--allow-downgrades";
    }
    arguments[used] = NULL;
    run_and_report(root, "/usr/bin/apt-get", arguments);
    putchar('\n');
    return 0;
}

// Deletes all but the newest backups_kept packages in a directory of
// backups or purchases.
static void prune_backups(const char *directory) {
    DIR *listing = opendir(directory);
    if (!listing) {
        return;
    }
    struct kept { char name[NAME_MAX + 1]; time_t time; };
    static struct kept files[1024];
    size_t count = 0;
    struct dirent *entry;
    while ((entry = readdir(listing)) != NULL && count < sizeof files / sizeof files[0]) {
        size_t length = strlen(entry->d_name);
        if (length > 4 && strcmp(entry->d_name + length - 4, ".deb") == 0) {
            char path[PATH_MAX];
            struct stat info;
            snprintf(path, sizeof path, "%s/%s", directory, entry->d_name);
            if (lstat(path, &info) == 0 && S_ISREG(info.st_mode)) {
                snprintf(files[count].name, sizeof files[count].name, "%s", entry->d_name);
                files[count].time = info.st_mtime;
                count++;
            }
        }
    }
    closedir(listing);
    while (count > backups_kept) {
        size_t oldest = 0;
        for (size_t i = 1; i < count; i++) {
            if (files[i].time < files[oldest].time) {
                oldest = i;
            }
        }
        char path[PATH_MAX];
        snprintf(path, sizeof path, "%s/%s", directory, files[oldest].name);
        unlink(path);
        files[oldest] = files[--count];
    }
}

static int backup(int count, char **names) {
    char root[PATH_MAX];
    require_root(root);
    if (count < 1 || count > operation_limit) {
        usage_error("Name between 1 and 200 packages to back up.");
    }
    for (int i = 0; i < count; i++) {
        if (!valid_package(names[i])) {
            usage_error("A package name is not valid.");
        }
    }
    char codling[PATH_MAX];
    char directory[PATH_MAX];
    char staging[PATH_MAX];
    char admin[PATH_MAX];
    char dpkg_deb[PATH_MAX];
    char search[4 * PATH_MAX];
    snprintf(codling, sizeof codling, "%s/var/lib/codling", root);
    snprintf(directory, sizeof directory, "%s%s", root, backups_suffix);
    snprintf(staging, sizeof staging, "%s/var/lib/codling/staging", root);
    snprintf(admin, sizeof admin, "%s/var/lib/dpkg", root);
    snprintf(dpkg_deb, sizeof dpkg_deb, "%s/usr/bin/dpkg-deb", root);
    snprintf(search, sizeof search,
             "PATH=%s/usr/sbin:%s/usr/bin:%s/sbin:%s/bin:/usr/sbin:/usr/bin:/sbin:/bin", root, root, root, root);
    for (const char *made = codling; made; made = made == codling ? directory : NULL) {
        if (mkdir(made, 0755) != 0 && errno != EEXIST) {
            usage_error("The backup directory cannot be created.");
        }
        // Root's alone, whoever made it.
        if (chown(made, 0, 0) != 0 || chmod(made, 0755) != 0) {
            usage_error("The backup directory cannot be made root's.");
        }
    }
    struct codling_repack_paths paths = {
        .admin = admin, .files = "", .staging = staging, .output = directory,
        .dpkg_deb = dpkg_deb, .path_variable = search,
    };
    fputs("{\"backups\":[", stdout);
    for (int i = 0; i < count; i++) {
        char version[256] = "";
        char architecture[64] = "";
        char file_name[PATH_MAX];
        char message[1024];
        codling_installed_version(admin, names[i], version, sizeof version, architecture, sizeof architecture);
        int made = codling_repack(&paths, names[i], file_name, sizeof file_name, message, sizeof message);
        printf("%s{\"package\":", i ? "," : "");
        print_json_string(names[i], strlen(names[i]));
        fputs(",\"version\":", stdout);
        print_json_string(version, strlen(version));
        if (made == 0) {
            fputs(",\"file\":", stdout);
            print_json_string(file_name, strlen(file_name));
        } else {
            fputs(",\"error\":", stdout);
            print_json_string(message, strlen(message));
        }
        putchar('}');
    }
    puts("]}");
    codling_remove_tree(staging);
    prune_backups(directory);
    return 0;
}

enum { purchase_size_limit = 1 << 30 };

static int take_purchase(const char *package, const char *version) {
    char root[PATH_MAX];
    require_root(root);
    if (!valid_package(package) || !valid_version(version)) {
        usage_error("The package or version is not valid.");
    }
    char file[NAME_MAX + 1];
    char inbox[PATH_MAX];
    if (purchase_file_name(package, version, file, sizeof file) != 0
        || snprintf(inbox, sizeof inbox, "%s/%s", purchase_inbox, file) >= (int)sizeof inbox) {
        usage_error("The package's name and version are too long.");
    }

    // The hashes apt lists for that version, from the sources' indexes,
    // which apt checked against their signed Release files where they have
    // them.
    char request[name_limit + 140];
    snprintf(request, sizeof request, "%s=%s", package, version);
    const char *const arguments[] = { "apt-cache", "show", "-q", request, NULL };
    char *output = NULL;
    size_t length = 0;
    int status = run_collect(root, "/usr/bin/apt-cache", arguments, &output, &length);
    static char hashes[hashes_limit][sha256_hex_size];
    size_t listed = status == 0 && output ? listed_sha256(output, length, hashes, hashes_limit) : 0;
    free(output);

    // The download is used once, whatever happens next: it is unlinked as
    // soon as it is open, and read through the open file.
    int in = open(inbox, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    unlink(inbox);
    if (listed == 0) {
        failure("apt lists no SHA256 hash for this version of the package, so Codling cannot check the "
                "download. Refresh your sources and try again.");
    }
    struct stat info;
    if (in < 0 || fstat(in, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != mobile_uid
        || info.st_size <= 0 || info.st_size > purchase_size_limit) {
        failure("Codling's download of the package is missing, or is not a file Codling made.");
    }

    char codling[PATH_MAX];
    char directory[PATH_MAX];
    char target[PATH_MAX];
    char partial[PATH_MAX];
    snprintf(codling, sizeof codling, "%s/var/lib/codling", root);
    snprintf(directory, sizeof directory, "%s%s", root, purchases_suffix);
    for (const char *made = codling; made; made = made == codling ? directory : NULL) {
        // Root's alone, whoever made it.
        if ((mkdir(made, 0755) != 0 && errno != EEXIST) || chown(made, 0, 0) != 0 || chmod(made, 0755) != 0) {
            failure("The directory for purchased packages cannot be made root's.");
        }
    }
    if (snprintf(target, sizeof target, "%s/%s", directory, file) >= (int)sizeof target
        || snprintf(partial, sizeof partial, "%s.part", target) >= (int)sizeof partial) {
        failure("The package's name and version are too long.");
    }
    unlink(partial);
    int out = open(partial, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (out < 0) {
        failure("The checked copy of the package cannot be written.");
    }

    codling_sha256 hash;
    codling_sha256_init(&hash);
    static char chunk[1 << 16];
    long long total = 0;
    int copied = 1;
    while (copied) {
        ssize_t got = read(in, chunk, sizeof chunk);
        if (got < 0 && errno == EINTR) {
            continue;
        }
        if (got <= 0) {
            copied = got == 0;
            break;
        }
        total += got;
        if (total > purchase_size_limit) {
            copied = 0;
            break;
        }
        codling_sha256_update(&hash, chunk, (size_t)got);
        ssize_t done = 0;
        while (done < got) {
            ssize_t wrote = write(out, chunk + done, (size_t)(got - done));
            if (wrote < 0 && errno == EINTR) {
                continue;
            }
            if (wrote <= 0) {
                copied = 0;
                break;
            }
            done += wrote;
        }
    }
    close(in);
    if (close(out) != 0) {
        copied = 0;
    }
    char digest[sha256_hex_size];
    codling_sha256_hex(&hash, digest);
    int matches = 0;
    for (size_t i = 0; i < listed; i++) {
        matches = matches || strcmp(hashes[i], digest) == 0;
    }
    if (!copied || !matches || rename(partial, target) != 0) {
        unlink(partial);
        failure(!copied    ? "The download could not be copied."
                : !matches ? "The download does not match the package your source lists, so Codling did not keep it."
                           : "The checked copy of the package cannot be kept.");
    }
    prune_backups(directory);
    fputs("{\"package\":", stdout);
    print_json_string(package, strlen(package));
    fputs(",\"version\":", stdout);
    print_json_string(version, strlen(version));
    fputs(",\"sha256\":", stdout);
    print_json_string(digest, strlen(digest));
    puts("}");
    return 0;
}

static int respring(void) {
    char root[PATH_MAX];
    require_root(root);
    char sbreload[PATH_MAX];
    snprintf(sbreload, sizeof sbreload, "%s/usr/bin/sbreload", root);
    if (access(sbreload, X_OK) == 0) {
        const char *const arguments[] = { "sbreload", NULL };
        run_and_report(root, "/usr/bin/sbreload", arguments);
    } else {
        const char *const arguments[] = { "killall", "-9", "SpringBoard", NULL };
        run_and_report(root, "/usr/bin/killall", arguments);
    }
    putchar('\n');
    return 0;
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

// A tweak or process name for burrowctl: letters, digits, spaces and
// "._+-", not starting with "." or "-", so that it cannot be read as an
// option or a path; or "*", every tweak or everywhere.
static int valid_burrow_name(const char *name) {
    size_t length = strlen(name);
    if (length == 0 || length > name_limit) {
        return 0;
    }
    if (strcmp(name, "*") == 0) {
        return 1;
    }
    if (name[0] == '.' || name[0] == '-') {
        return 0;
    }
    for (const char *c = name; *c; c++) {
        if (!isalnum((unsigned char)*c) && !strchr(" ._+-", *c)) {
            return 0;
        }
    }
    return 1;
}

// A repository URI as SourceList.repositoryURI writes it: http or https, a
// lower-case host with a dot, and a path ending in "/" without "." or ".."
// segments, from a short list of characters.
static int valid_repository_uri(const char *uri) {
    size_t length = strlen(uri);
    if (length == 0 || length > 512) {
        return 0;
    }
    const char *host;
    if (strncmp(uri, "https://", 8) == 0) {
        host = uri + 8;
    } else if (strncmp(uri, "http://", 7) == 0) {
        host = uri + 7;
    } else {
        return 0;
    }
    const char *path = strchr(host, '/');
    if (!path || path == host || host[0] == '.' || host[0] == '-' || path[-1] == '.') {
        return 0;
    }
    int dot = 0;
    for (const char *c = host; c < path; c++) {
        if (*c == '.') {
            dot = 1;
        } else if (!((*c >= 'a' && *c <= 'z') || (*c >= '0' && *c <= '9') || *c == '-')) {
            return 0;
        }
    }
    if (!dot || uri[length - 1] != '/') {
        return 0;
    }
    for (const char *c = path; *c; c++) {
        if (!isalnum((unsigned char)*c) && !strchr("._~/%+-", *c)) {
            return 0;
        }
    }
    // No "." or ".." segment.
    for (const char *segment = path; segment && *segment; segment = strchr(segment + 1, '/')) {
        const char *start = segment + 1;
        size_t size = strcspn(start, "/");
        if ((size == 1 && start[0] == '.') || (size == 2 && start[0] == '.' && start[1] == '.')) {
            return 0;
        }
    }
    return 1;
}

static const char codling_sources[] = "/etc/apt/sources.list.d/codling.sources";

// Reads codling.sources, at most output_limit bytes; an empty buffer when it
// does not exist. Returns NULL on another error.
static char *read_codling_sources(const char *path, size_t *length) {
    *length = 0;
    char *text = calloc(1, output_limit + 1);
    if (!text) {
        return NULL;
    }
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        if (errno == ENOENT) {
            return text;
        }
        free(text);
        return NULL;
    }
    for (;;) {
        ssize_t got = read(fd, text + *length, output_limit - *length);
        if (got < 0 && errno == EINTR) {
            continue;
        }
        if (got <= 0) {
            break;
        }
        *length += (size_t)got;
        if (*length == output_limit) {
            break;
        }
    }
    close(fd);
    return text;
}

// Writes text to path through a temporary file beside it, so that apt never
// reads half a file. An empty text removes the file.
static int write_codling_sources(const char *path, const char *text, size_t length) {
    if (length == 0) {
        return unlink(path) == 0 || errno == ENOENT ? 0 : -1;
    }
    char temporary[PATH_MAX];
    if (snprintf(temporary, sizeof temporary, "%s.part", path) >= (int)sizeof temporary) {
        return -1;
    }
    int fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0644);
    if (fd < 0) {
        return -1;
    }
    size_t written = 0;
    while (written < length) {
        ssize_t put = write(fd, text + written, length - written);
        if (put < 0 && errno == EINTR) {
            continue;
        }
        if (put <= 0) {
            close(fd);
            unlink(temporary);
            return -1;
        }
        written += (size_t)put;
    }
    if (fchmod(fd, 0644) != 0 || fsync(fd) != 0 || close(fd) != 0 || rename(temporary, path) != 0) {
        unlink(temporary);
        return -1;
    }
    return 0;
}

// Whether a stanza (text up to a blank line) has the line "URIs: uri".
static int stanza_has_uri(const char *stanza, size_t size, const char *uri) {
    size_t uri_length = strlen(uri);
    const char *end = stanza + size;
    for (const char *line = stanza; line < end;) {
        const char *next = memchr(line, '\n', (size_t)(end - line));
        size_t line_length = (size_t)((next ? next : end) - line);
        if (line_length == 6 + uri_length && strncmp(line, "URIs: ", 6) == 0 && strncmp(line + 6, uri, uri_length) == 0) {
            return 1;
        }
        line = next ? next + 1 : end;
    }
    return 0;
}

// Copies the stanzas of text into out, leaving out those with uri; returns
// how many were left out. Blank lines between stanzas become one.
static int filter_stanzas(const char *text, size_t length, const char *uri, char *out, size_t *out_length) {
    int dropped = 0;
    *out_length = 0;
    const char *end = text + length;
    const char *position = text;
    while (position < end) {
        // Skip blank lines.
        while (position < end && *position == '\n') {
            position++;
        }
        if (position >= end) {
            break;
        }
        const char *stanza_end = position;
        while (stanza_end < end && !(stanza_end[0] == '\n' && (stanza_end + 1 == end || stanza_end[1] == '\n'))) {
            stanza_end++;
        }
        size_t size = (size_t)(stanza_end - position);
        if (stanza_has_uri(position, size, uri)) {
            dropped++;
        } else {
            memcpy(out + *out_length, position, size);
            *out_length += size;
            memcpy(out + *out_length, "\n\n", 2);
            *out_length += 2;
        }
        position = stanza_end;
    }
    return dropped;
}

// An address as it may stand in any sources file, for removal only: it is
// compared, never passed on. http or https, printable, without spaces,
// quotes or backslashes.
static int valid_existing_uri(const char *uri) {
    size_t length = strlen(uri);
    if (length == 0 || length > 512 || (strncmp(uri, "https://", 8) != 0 && strncmp(uri, "http://", 7) != 0)) {
        return 0;
    }
    for (const char *c = uri; *c; c++) {
        if (*c <= ' ' || *c > '~' || *c == '"' || *c == '\'' || *c == '\\') {
            return 0;
        }
    }
    return 1;
}

// Whether an address in a file names uri, with or without a trailing "/".
static int same_uri(const char *token, size_t size, const char *uri) {
    size_t uri_length = strlen(uri);
    while (size > 0 && token[size - 1] == '/') {
        size--;
    }
    while (uri_length > 0 && uri[uri_length - 1] == '/') {
        uri_length--;
    }
    return size == uri_length && strncmp(token, uri, size) == 0;
}

// Appends text to out.
static void put(char *out, size_t *out_length, const char *text, size_t size) {
    memcpy(out + *out_length, text, size);
    *out_length += size;
}

// Copies a deb822 file's stanzas into out without uri: a stanza whose only
// address it is goes, and a stanza with others loses it from its URIs line.
// Returns how many addresses went.
static int filter_deb822(const char *text, size_t length, const char *uri, char *out, size_t *out_length) {
    int dropped = 0;
    *out_length = 0;
    const char *end = text + length;
    const char *position = text;
    while (position < end) {
        while (position < end && *position == '\n') {
            position++;
        }
        if (position >= end) {
            break;
        }
        const char *stanza_end = position;
        while (stanza_end < end && !(stanza_end[0] == '\n' && (stanza_end + 1 == end || stanza_end[1] == '\n'))) {
            stanza_end++;
        }
        // The stanza, line by line, with the URIs line rewritten when it
        // names uri; dropped whole when uri was its only address.
        size_t start_length = *out_length;
        int named = 0, others = 0;
        for (const char *line = position; line < stanza_end;) {
            const char *next = memchr(line, '\n', (size_t)(stanza_end - line));
            const char *line_end = next ? next : stanza_end;
            if (line_end - line >= 5 && strncasecmp(line, "URIs:", 5) == 0) {
                put(out, out_length, "URIs:", 5);
                for (const char *token = line + 5; token < line_end;) {
                    while (token < line_end && (*token == ' ' || *token == '\t')) {
                        token++;
                    }
                    const char *token_end = token;
                    while (token_end < line_end && *token_end != ' ' && *token_end != '\t') {
                        token_end++;
                    }
                    if (token_end > token) {
                        if (same_uri(token, (size_t)(token_end - token), uri)) {
                            named++;
                        } else {
                            others++;
                            put(out, out_length, " ", 1);
                            put(out, out_length, token, (size_t)(token_end - token));
                        }
                    }
                    token = token_end;
                }
            } else {
                put(out, out_length, line, (size_t)(line_end - line));
            }
            put(out, out_length, "\n", 1);
            line = next ? next + 1 : stanza_end;
        }
        dropped += named;
        if (named && !others) {
            *out_length = start_length;
        } else {
            put(out, out_length, "\n", 1);
        }
        position = stanza_end;
    }
    return dropped;
}

// Copies a one-line sources file into out without its "deb" and "deb-src"
// lines for uri. Returns how many lines went.
static int filter_one_line(const char *text, size_t length, const char *uri, char *out, size_t *out_length) {
    int dropped = 0;
    *out_length = 0;
    const char *end = text + length;
    for (const char *line = text; line < end;) {
        const char *next = memchr(line, '\n', (size_t)(end - line));
        const char *line_end = next ? next : end;
        const char *c = line;
        while (c < line_end && (*c == ' ' || *c == '\t')) {
            c++;
        }
        int matches = 0;
        size_t rest = (size_t)(line_end - c);
        size_t type = rest >= 4 && strncmp(c, "deb ", 4) == 0 ? 4 : rest >= 8 && strncmp(c, "deb-src ", 8) == 0 ? 8 : 0;
        if (type) {
            c += type;
            while (c < line_end && (*c == ' ' || *c == '\t')) {
                c++;
            }
            if (c < line_end && *c == '[') {
                const char *close = memchr(c, ']', (size_t)(line_end - c));
                c = close ? close + 1 : line_end;
                while (c < line_end && (*c == ' ' || *c == '\t')) {
                    c++;
                }
            }
            const char *token_end = c;
            while (token_end < line_end && *token_end != ' ' && *token_end != '\t') {
                token_end++;
            }
            matches = token_end > c && same_uri(c, (size_t)(token_end - c), uri);
        }
        if (matches) {
            dropped++;
        } else {
            put(out, out_length, line, (size_t)(line_end - line));
            if (next) {
                put(out, out_length, "\n", 1);
            }
        }
        line = next ? next + 1 : end;
    }
    return dropped;
}

// Takes uri out of one sources file. Returns how many entries went, or -1.
static int remove_from_file(const char *path, const char *uri, int delete_when_empty) {
    struct stat info;
    if (lstat(path, &info) != 0 || !S_ISREG(info.st_mode)) {
        return 0;
    }
    size_t length = 0;
    char *text = read_codling_sources(path, &length);
    // A stanza gains at most one blank line.
    char *out = text && length < output_limit ? malloc(length * 2 + 64) : NULL;
    if (!text || !out) {
        free(text);
        return -1;
    }
    size_t out_length = 0;
    size_t name_length = strlen(path);
    int deb822 = name_length > 8 && strcmp(path + name_length - 8, ".sources") == 0;
    int dropped = deb822 ? filter_deb822(text, length, uri, out, &out_length)
                         : filter_one_line(text, length, uri, out, &out_length);
    int failed = 0;
    if (dropped > 0) {
        if (out_length == 0 && !delete_when_empty) {
            // Keep a package manager's file, empty.
            failed = write_codling_sources(path, "\n", 1) != 0;
        } else {
            failed = write_codling_sources(path, out, out_length) != 0;
        }
    }
    free(text);
    free(out);
    return failed ? -1 : dropped;
}

static int remove_source(const char *uri) {
    char root[PATH_MAX];
    require_root(root);
    if (!valid_existing_uri(uri)) {
        usage_error("The address is not one Codling can look for in the sources files.");
    }
    char path[PATH_MAX];
    int removed = 0, failed = 0;
    if (snprintf(path, sizeof path, "%s/etc/apt/sources.list", root) < (int)sizeof path) {
        int result = remove_from_file(path, uri, 0);
        failed |= result < 0;
        removed += result > 0 ? result : 0;
    }
    char directory[PATH_MAX];
    snprintf(directory, sizeof directory, "%s/etc/apt/sources.list.d", root);
    DIR *listing = opendir(directory);
    struct dirent *entry;
    while (listing && (entry = readdir(listing))) {
        size_t size = strlen(entry->d_name);
        int sources = size > 8 && strcmp(entry->d_name + size - 8, ".sources") == 0;
        int list = size > 5 && strcmp(entry->d_name + size - 5, ".list") == 0;
        if (entry->d_name[0] == '.' || (!sources && !list) ||
            snprintf(path, sizeof path, "%s/%s", directory, entry->d_name) >= (int)sizeof path) {
            continue;
        }
        int result = remove_from_file(path, uri, strcmp(entry->d_name, "codling.sources") == 0);
        failed |= result < 0;
        removed += result > 0 ? result : 0;
    }
    if (listing) {
        closedir(listing);
    }
    if (failed) {
        puts("{\"error\":\"A sources file could not be read or written.\"}");
        return 74;
    }
    printf("{\"changed\":%s}\n", removed > 0 ? "true" : "false");
    return 0;
}

static int add_source(const char *uri) {
    char root[PATH_MAX];
    require_root(root);
    if (!valid_repository_uri(uri)) {
        usage_error("The address is not a repository address Codling writes.");
    }
    char path[PATH_MAX];
    if (snprintf(path, sizeof path, "%s%s", root, codling_sources) >= (int)sizeof path) {
        usage_error("The jailbreak root is too long.");
    }
    size_t length = 0;
    char *text = read_codling_sources(path, &length);
    char *out = text && length < output_limit ? malloc(length + 512 + 64) : NULL;
    if (!text || !out) {
        free(text);
        puts("{\"error\":\"codling.sources cannot be read.\"}");
        return 74;
    }
    size_t out_length = 0;
    int already = filter_stanzas(text, length, uri, out, &out_length) > 0;
    int failed = 0;
    if (!already) {
        out_length += (size_t)sprintf(out + out_length, "Types: deb\nURIs: %s\nSuites: ./\n\n", uri);
        failed = write_codling_sources(path, out, out_length) != 0;
    }
    free(text);
    free(out);
    if (failed) {
        printf("{\"error\":");
        const char *reason = strerror(errno);
        print_json_string(reason, strlen(reason));
        puts("}");
        return 74;
    }
    printf("{\"changed\":%s}\n", already ? "false" : "true");
    return 0;
}

static const char burrowctl[] = "/usr/bin/burrowctl";

static int burrow_state(void) {
    char root[PATH_MAX];
    require_root(root);
    const char *const arguments[] = { "burrowctl", "json", NULL };
    run_and_report(root, burrowctl, arguments);
    putchar('\n');
    return 0;
}

static int burrow_tweak(int count, char **words) {
    char root[PATH_MAX];
    require_root(root);
    if (count < 2 || count > 3 || (strcmp(words[0], "on") != 0 && strcmp(words[0], "off") != 0)) {
        usage_error("Say on or off, a tweak, and optionally a process.");
    }
    if (!valid_burrow_name(words[1]) || (count == 3 && !valid_burrow_name(words[2]))) {
        usage_error("A tweak or process name has characters burrowctl does not take.");
    }
    const char *const arguments[] = { "burrowctl", strcmp(words[0], "on") == 0 ? "enable" : "disable", words[1],
                                      count == 3 ? words[2] : NULL, NULL };
    run_and_report(root, burrowctl, arguments);
    putchar('\n');
    return 0;
}

static int burrow_loader(const char *which) {
    char root[PATH_MAX];
    require_root(root);
    if (strcmp(which, "burrow") != 0 && strcmp(which, "ellekit") != 0) {
        usage_error("The loader is burrow or ellekit.");
    }
    const char *const arguments[] = { "burrowctl", "loader", which, NULL };
    run_and_report(root, burrowctl, arguments);
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
    if (argc == 2 && strcmp(argv[1], "update-lists") == 0) {
        return update_lists();
    }
    if (argc >= 2 && strcmp(argv[1], "simulate") == 0) {
        return simulate(argc - 2, argv + 2);
    }
    if (argc >= 2 && strcmp(argv[1], "apply") == 0) {
        return apply(argc - 2, argv + 2);
    }
    if (argc == 2 && strcmp(argv[1], "respring") == 0) {
        return respring();
    }
    if (argc >= 2 && strcmp(argv[1], "backup") == 0) {
        return backup(argc - 2, argv + 2);
    }
    if (argc == 3 && strcmp(argv[1], "add-source") == 0) {
        return add_source(argv[2]);
    }
    if (argc == 3 && strcmp(argv[1], "remove-source") == 0) {
        return remove_source(argv[2]);
    }
    if (argc == 4 && strcmp(argv[1], "take-purchase") == 0) {
        return take_purchase(argv[2], argv[3]);
    }
    if (argc == 2 && strcmp(argv[1], "burrow-state") == 0) {
        return burrow_state();
    }
    if (argc >= 2 && strcmp(argv[1], "burrow-tweak") == 0) {
        return burrow_tweak(argc - 2, argv + 2);
    }
    if (argc == 3 && strcmp(argv[1], "burrow-loader") == 0) {
        return burrow_loader(argv[2]);
    }
    fputs("usage: codling-helper check | audit | configure-pending | update-lists | simulate OPERATION... |\n"
          "       apply [--trust-unsigned] [--allow-removals] OPERATION... | respring | backup PACKAGE... |\n"
          "       add-source URI | remove-source URI | take-purchase PACKAGE VERSION |\n"
          "       burrow-state | burrow-tweak on|off TWEAK [PROCESS] | burrow-loader burrow|ellekit\n", stderr);
    return 64;
}

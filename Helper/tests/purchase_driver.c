// SPDX-License-Identifier: Apache-2.0
//
// Tests what the helper uses to take a purchased package or a .deb the user
// opened: SHA-256 (sha256.c), reading the SHA256 fields apt-cache prints,
// the $package=version and %TOKEN operations' parts, reading control fields,
// and finding a checked copy. It includes the helper with its main renamed,
// so that the static functions are in reach.

#define main codling_helper_main
#include "../codling-helper.c"
#undef main

int _NSGetExecutablePath(char *buffer, uint32_t *size) {
    (void)buffer;
    (void)size;
    return -1;
}

static int failures, checks;

static void expect(int condition, const char *what) {
    checks++;
    if (!condition) {
        failures++;
        fprintf(stderr, "not ok: %s\n", what);
    }
}

static void expect_string(const char *got, const char *expected, const char *what) {
    expect(strcmp(got, expected) == 0, what);
    if (strcmp(got, expected) != 0) {
        fprintf(stderr, "  expected: [%s]\n  got:      [%s]\n", expected, got);
    }
}

static void hash_text(const char *text, char hex[65]) {
    codling_sha256 hash;
    codling_sha256_init(&hash);
    codling_sha256_update(&hash, text, strlen(text));
    codling_sha256_hex(&hash, hex);
}

// driver uris FILE PACKAGE VERSION: prints the archive name that
// archive_name_from_uris finds in FILE, which holds what apt-get install
// --print-uris printed, so that scripts/test-apt-trust.sh can check it
// against a real apt.
static int find_in_uris(const char *path, const char *package, const char *version) {
    static char text[1 << 16];
    FILE *input = fopen(path, "r");
    if (!input) {
        return 2;
    }
    size_t length = fread(text, 1, sizeof text, input);
    fclose(input);
    char file[NAME_MAX + 1];
    if (archive_name_from_uris(text, length, package, version, file, sizeof file) != 0) {
        return 1;
    }
    puts(file);
    return 0;
}

// driver field FILE NAME: prints the field that control_field finds in
// FILE, which holds what dpkg-deb --field printed, so that
// scripts/test-apt-trust.sh can check it against a real dpkg-deb.
static int find_field(const char *path, const char *name) {
    static char text[1 << 16];
    FILE *input = fopen(path, "r");
    if (!input) {
        return 2;
    }
    size_t length = fread(text, 1, sizeof text, input);
    fclose(input);
    char value[512];
    if (control_field(text, length, name, value, sizeof value) != 0) {
        return 1;
    }
    puts(value);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 5 && strcmp(argv[1], "uris") == 0) {
        return find_in_uris(argv[2], argv[3], argv[4]);
    }
    if (argc == 4 && strcmp(argv[1], "field") == 0) {
        return find_field(argv[2], argv[3]);
    }
    if (argc != 2) {
        fprintf(stderr, "usage: %s DIRECTORY | uris FILE PACKAGE VERSION | field FILE NAME\n", argv[0]);
        return 2;
    }
    char hex[65];

    // FIPS 180-4's examples, and NIST's one million "a".
    hash_text("", hex);
    expect_string(hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "the empty message");
    hash_text("abc", hex);
    expect_string(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "abc");
    hash_text("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", hex);
    expect_string(hex, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "two blocks");
    codling_sha256 hash;
    codling_sha256_init(&hash);
    char a[1000];
    memset(a, 'a', sizeof a);
    for (int i = 0; i < 1000; i++) {
        codling_sha256_update(&hash, a, sizeof a);
    }
    codling_sha256_hex(&hash, hex);
    expect_string(hex, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "one million a");

    // The same bytes in pieces that cross the 64-byte blocks give the same
    // hash, for every padding length.
    for (size_t size = 0; size < 200; size++) {
        char data[200];
        for (size_t i = 0; i < size; i++) {
            data[i] = (char)(i * 7 + size);
        }
        char whole[65];
        char pieces[65];
        codling_sha256_init(&hash);
        codling_sha256_update(&hash, data, size);
        codling_sha256_hex(&hash, whole);
        codling_sha256_init(&hash);
        for (size_t i = 0; i < size; i += 13) {
            codling_sha256_update(&hash, data + i, size - i < 13 ? size - i : 13);
        }
        codling_sha256_hex(&hash, pieces);
        expect(strcmp(whole, pieces) == 0, "pieces hash as the whole");
    }

    // What apt-cache show prints: one record per source that lists the
    // version, and the installed package's record without hashes.
    const char *shown =
        "Package: com.example.paid\nVersion: 1.2.5\nInstalled-Size: 120\n"
        "MD5sum: 0123456789abcdef0123456789abcdef\n"
        "SHA256: 9F86D081884C7D659A2FEAA0C55AD015A3BF4F1B2B0B822CD15D6C15B0F00A08\n\n"
        "Package: com.example.paid\nVersion: 1.2.5\n"
        "SHA256:\t 2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae \r\n"
        "SHA256: tooshort\nSHA256sum: 0000\nSHA512: aa\n"
        "Description: SHA256: 2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae\n"
        "SHA256: zz26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae";
    char hashes[hashes_limit][sha256_hex_size];
    size_t listed = listed_sha256(shown, strlen(shown), hashes, hashes_limit);
    expect(listed == 2, "two SHA256 fields are read");
    if (listed == 2) {
        expect_string(hashes[0], "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08", "in lower case");
        expect_string(hashes[1], "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae",
                      "spaces, tabs and a carriage return are trimmed");
    }
    expect(listed_sha256(shown, strlen(shown), hashes, 1) == 1, "at most limit hashes");
    expect(listed_sha256("", 0, hashes, hashes_limit) == 0, "no output, no hashes");

    // $package=version.
    char package[name_limit + 1];
    const char *version = NULL;
    expect(split_versioned("com.example.paid=1:1.2.5-1", package, &version) == 0, "name=version");
    expect_string(package, "com.example.paid", "the name");
    expect(version && strcmp(version, "1:1.2.5-1") == 0, "the version");
    const char *bad[] = { "com.example.paid", "=1.0", "com.example.paid=", "-x=1.0", "a/b=1.0", "pkg=1.0/..",
                          "pkg=v1.0", "pkg=1.0 2" };
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) {
        expect(split_versioned(bad[i], package, &version) != 0, bad[i]);
    }

    char file[NAME_MAX + 1];
    expect(purchase_file_name("com.example.paid", "1:1.2.5", file, sizeof file) == 0, "a file name");
    expect_string(file, "com.example.paid_1%3a1.2.5.deb", "the epoch is escaped as in backups");
    expect(purchase_file_name("com.example.paid", "1.0", file, 10) != 0, "a name that does not fit");

    // A checked copy is a regular file of root's under purchases_suffix.
    char root[PATH_MAX];
    char directory[PATH_MAX];
    char path[backup_path_size];
    snprintf(root, sizeof root, "%s", argv[1]);
    snprintf(directory, sizeof directory, "%s/var", root);
    mkdir(directory, 0755);
    snprintf(directory, sizeof directory, "%s/var/lib", root);
    mkdir(directory, 0755);
    snprintf(directory, sizeof directory, "%s/var/lib/codling", root);
    mkdir(directory, 0755);
    snprintf(directory, sizeof directory, "%s%s", root, purchases_suffix);
    expect(mkdir(directory, 0755) == 0, "the purchases directory is made");
    expect(purchase_path(root, "com.example.paid", "1.2.5", path) != 0, "no copy, no path");
    char copy[PATH_MAX];
    snprintf(copy, sizeof copy, "%s/com.example.paid_1.2.5.deb", directory);
    FILE *written = fopen(copy, "w");
    expect(written != NULL, "a copy is written");
    if (written) {
        fputs("!<arch>\n", written);
        fclose(written);
    }
    // Only root's files count; the tests run as root on some machines and
    // not on others.
    int found = purchase_path(root, "com.example.paid", "1.2.5", path);
    expect(getuid() == 0 ? found == 0 : found != 0, "a copy counts only when it is root's");
    if (found == 0) {
        expect_string(path, copy, "the copy's path");
    }
    char link_path[PATH_MAX];
    snprintf(link_path, sizeof link_path, "%s/com.example.linked_1.0.deb", directory);
    expect(symlink(copy, link_path) == 0, "a link is made");
    expect(purchase_path(root, "com.example.linked", "1.0", path) != 0, "a link is not a copy");

    // Paths as the jailbreak's programs see them (tool-path.h).
    const char *hidden = "/private/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF";
    const char *preboot = "/private/preboot/ABCDEF/jb-XYZ/procursus";
    char seen[PATH_MAX];
    expect(codling_is_roothide_root(hidden), "a .jbroot- directory is a RootHide root");
    expect(!codling_is_roothide_root(preboot), "a rootless root is not");
    expect(!codling_is_roothide_root("/var/jb"), "nor is /var/jb");
    expect(!codling_is_roothide_root("/private/var/containers/Bundle/Application/.jbroot-"), "a bare prefix is not");
    expect(!codling_is_roothide_root(NULL), "no root is not");
    expect(codling_tool_path(preboot, "/private/preboot/ABCDEF/jb-XYZ/procursus/var/lib/x.deb", seen, sizeof seen) == 0,
           "a rootless path converts");
    expect_string(seen, "/private/preboot/ABCDEF/jb-XYZ/procursus/var/lib/x.deb", "rootless paths stay real");
    expect(codling_tool_path(hidden, "/private/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF/var/lib/x.deb",
                             seen, sizeof seen) == 0,
           "a RootHide path converts");
    expect_string(seen, "/var/lib/x.deb", "a path in the hidden root loses the root");
    expect(codling_tool_path(hidden, hidden, seen, sizeof seen) == 0, "the root itself converts");
    expect_string(seen, "/", "the hidden root is /");
    expect(codling_tool_path(hidden, "/private/var/mobile/Library/Caches/x", seen, sizeof seen) == 0,
           "a system path converts");
    expect_string(seen, "/rootfs/private/var/mobile/Library/Caches/x", "a system path gains /rootfs");
    expect(codling_tool_path(hidden, "/private/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF0/x", seen,
                             sizeof seen) == 0,
           "a longer sibling converts");
    expect_string(seen, "/rootfs/private/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF0/x",
                  "a directory that only starts like the root is not in it");
    expect(codling_tool_path(NULL, "/var/jb/x", seen, sizeof seen) == 0, "no root converts");
    expect_string(seen, "/var/jb/x", "no root changes nothing");
    expect(codling_tool_path(hidden, "/private/var/mobile/x", seen, 10) != 0, "a result that does not fit fails");
    char search[8 * PATH_MAX];
    tool_search_path(hidden, search, sizeof search);
    expect_string(search, "PATH=/usr/sbin:/usr/bin:/sbin:/bin:/rootfs/usr/sbin:/rootfs/usr/bin:/rootfs/sbin:/rootfs/bin",
                  "RootHide's search path");
    tool_search_path(preboot, search, sizeof search);
    expect_string(search,
                  "PATH=/private/preboot/ABCDEF/jb-XYZ/procursus/usr/sbin:/private/preboot/ABCDEF/jb-XYZ/procursus/usr/bin:"
                  "/private/preboot/ABCDEF/jb-XYZ/procursus/sbin:/private/preboot/ABCDEF/jb-XYZ/procursus/bin:"
                  "/usr/sbin:/usr/bin:/sbin:/bin",
                  "the rootless search path is as before");

    // What apt-get install --print-uris prints, as apt 2.8 does: the
    // purchase, a dependency, and a version with an epoch.
    const char *uris =
        "'https://repo.example.com/./debs/dep.deb' com.example.dep_2.0_iphoneos-arm64.deb 1200 SHA256:ab\n"
        "'https://repo.example.com/./paid/com.example.paid' com.example.paid_1.2.5_iphoneos-arm64.deb 498 MD5Sum:3c\n"
        "'https://repo.example.com/./e.deb' com.example.epoch_2%3a1.0-1_all.deb 508 MD5Sum:5c\n";
    char archive[NAME_MAX + 1];
    expect(archive_name_from_uris(uris, strlen(uris), "com.example.paid", "1.2.5", archive, sizeof archive) == 0,
           "the purchase's line is found");
    expect_string(archive, "com.example.paid_1.2.5_iphoneos-arm64.deb", "apt's name for the download");
    expect(archive_name_from_uris(uris, strlen(uris), "com.example.epoch", "2:1.0-1", archive, sizeof archive) == 0,
           "a version with an epoch is found");
    expect_string(archive, "com.example.epoch_2%3a1.0-1_all.deb", "the epoch is written %3a");
    expect(archive_name_from_uris(uris, strlen(uris), "com.example.paid", "1.2", archive, sizeof archive) != 0,
           "another version is not taken");
    expect(archive_name_from_uris(uris, strlen(uris), "com.example", "1.2.5", archive, sizeof archive) != 0,
           "a package whose name starts the same is not taken");
    const char *unsafe[] = {
        "'u' com.example.paid_1.2.5_x/../../evil.deb 1 h\n",
        "'u' com.example.paid_1.2.5_a\"b.deb 1 h\n",
        "com.example.paid_1.2.5_all.deb 1 h\n",
        "'u'com.example.paid_1.2.5_all.deb 1 h\n",
        "'unclosed com.example.paid_1.2.5_all.deb 1 h\n",
    };
    for (size_t i = 0; i < sizeof unsafe / sizeof *unsafe; i++) {
        expect(archive_name_from_uris(unsafe[i], strlen(unsafe[i]), "com.example.paid", "1.2.5", archive,
                                      sizeof archive) != 0, unsafe[i]);
    }
    expect(archive_name_from_uris("", 0, "com.example.paid", "1.2.5", archive, sizeof archive) != 0,
           "nothing printed, no name");
    expect(archive_name_from_uris(uris, strlen(uris), "com.example.paid", "1.2.5", archive, 20) != 0,
           "a name that does not fit");

    // The checked copy is placed in apt's archive cache, whole, through a
    // partial file that does not stay.
    char archives[PATH_MAX];
    snprintf(archives, sizeof archives, "%s/archives", root);
    expect(mkdir(archives, 0755) == 0, "an archive cache is made");
    char source[PATH_MAX];
    snprintf(source, sizeof source, "%s/source.deb", root);
    FILE *deb = fopen(source, "w");
    expect(deb != NULL, "a package is written");
    if (deb) {
        for (int i = 0; i < 20000; i++) {
            fputc((char)(i * 31), deb);
        }
        fclose(deb);
    }
    expect(place_archive(source, archives, "com.example.paid_1.2.5_iphoneos-arm64.deb") == 0, "the copy is placed");
    char placed[PATH_MAX];
    snprintf(placed, sizeof placed, "%s/com.example.paid_1.2.5_iphoneos-arm64.deb", archives);
    struct stat placed_info;
    expect(stat(placed, &placed_info) == 0 && placed_info.st_size == 20000, "the placed copy is whole");
    char leftover[PATH_MAX];
    snprintf(leftover, sizeof leftover, "%s.part", placed);
    expect(access(leftover, F_OK) != 0, "no partial file stays");
    expect(place_archive(source, archives, "com.example.paid_1.2.5_iphoneos-arm64.deb") == 0,
           "placing it again replaces it");
    char linked_source[PATH_MAX];
    snprintf(linked_source, sizeof linked_source, "%s/linked.deb", root);
    expect(symlink(source, linked_source) == 0, "a link to the package is made");
    expect(place_archive(linked_source, archives, "linked_1.0_all.deb") != 0, "a link is not copied");
    snprintf(placed, sizeof placed, "%s/missing", root);
    expect(place_archive(source, placed, "x_1.0_all.deb") != 0, "a missing cache fails cleanly");

    // The inboxes are reached only through real directories.
    char home[PATH_MAX];
    snprintf(home, sizeof home, "%s/home", root);
    expect(mkdir(home, 0755) == 0, "a home is made");
    expect(open_inbox(home, purchases_inbox) < 0, "no inbox yet");
    char step[PATH_MAX];
    snprintf(step, sizeof step, "%s", home);
    for (size_t i = 0; i < sizeof inbox_parents / sizeof *inbox_parents; i++) {
        size_t step_length = strlen(step);
        snprintf(step + step_length, sizeof step - step_length, "/%s", inbox_parents[i]);
        mkdir(step, 0755);
    }
    expect(open_inbox(home, purchases_inbox) < 0, "no purchases inbox yet");
    expect(open_inbox(home, files_inbox) < 0, "no files inbox yet");
    char inbox_path[PATH_MAX];
    snprintf(inbox_path, sizeof inbox_path, "%s/%s", step, purchases_inbox);
    expect(mkdir(inbox_path, 0755) == 0, "the purchases inbox is made");
    int inbox = open_inbox(home, purchases_inbox);
    expect(inbox >= 0, "the purchases inbox opens");
    if (inbox >= 0) {
        close(inbox);
    }
    expect(open_inbox(home, files_inbox) < 0, "the files inbox is still missing");
    char files_path[PATH_MAX];
    snprintf(files_path, sizeof files_path, "%s/files-elsewhere", root);
    expect(mkdir(files_path, 0755) == 0, "a directory elsewhere is made");
    snprintf(inbox_path, sizeof inbox_path, "%s/%s", step, files_inbox);
    expect(symlink(files_path, inbox_path) == 0, "a link takes the files inbox's place");
    expect(open_inbox(home, files_inbox) < 0, "a linked files inbox is not followed");
    expect(unlink(inbox_path) == 0 && mkdir(inbox_path, 0755) == 0, "the files inbox is made");
    inbox = open_inbox(home, files_inbox);
    expect(inbox >= 0, "the files inbox opens");
    if (inbox >= 0) {
        close(inbox);
    }
    // Library/Caches/com.nexusjb.codling becomes a link to another directory.
    char cache[PATH_MAX];
    char moved[PATH_MAX];
    snprintf(cache, sizeof cache, "%s/Library/Caches/com.nexusjb.codling", home);
    snprintf(moved, sizeof moved, "%s/Library/Caches/moved", home);
    expect(rename(cache, moved) == 0, "the cache directory is moved away");
    expect(symlink(moved, cache) == 0, "a link takes its place");
    expect(open_inbox(home, purchases_inbox) < 0, "a link on the way is not followed");
    expect(open_inbox(home, files_inbox) < 0, "a link on the way to the files inbox is not followed");
    char linked_home[PATH_MAX];
    snprintf(linked_home, sizeof linked_home, "%s/linked-home", root);
    expect(symlink(home, linked_home) == 0, "a link to the home is made");
    expect(open_inbox(linked_home, purchases_inbox) < 0, "a linked home is not followed");

    // Tokens for opened files: 32 lowercase hex digits and nothing else.
    expect(valid_file_token("0123456789abcdef0123456789abcdef"), "a token of 32 hex digits");
    expect(!valid_file_token("0123456789abcdef0123456789abcde"), "31 digits are too few");
    expect(!valid_file_token("0123456789abcdef0123456789abcdef0"), "33 digits are too many");
    expect(!valid_file_token("0123456789ABCDEF0123456789abcdef"), "upper case is not a token");
    expect(!valid_file_token("0123456789abcdef0123456789abcde/"), "a slash is not a token");
    expect(!valid_file_token("../3456789abcdef0123456789abcdef"), "a parent directory is not a token");
    expect(!valid_file_token(""), "nothing is not a token");

    // The kept copy is found only when it is a real file.
    const char *token = "00112233445566778899aabbccddeeff";
    char kept[backup_path_size];
    expect(file_copy_path(root, token, kept) != 0, "no kept copy yet");
    snprintf(step, sizeof step, "%s/var/lib/codling/files", root);
    mkdir(step, 0755);
    snprintf(step, sizeof step, "%s/var/lib/codling/files/%s.deb", root, token);
    written = fopen(step, "w");
    expect(written != NULL, "a kept copy is written");
    if (written) {
        fputs("!<arch>\n", written);
        fclose(written);
    }
    if (getuid() == 0) {
        expect(file_copy_path(root, token, kept) == 0, "the kept copy is found");
        expect_string(kept, step, "the kept copy's path");
    } else {
        expect(file_copy_path(root, token, kept) != 0, "a copy that is not root's is not used");
    }
    expect(file_copy_path(root, "../../../../../../etc/passwd", kept) != 0, "a path is not a token");
    snprintf(kept, sizeof kept, "%s/var/lib/codling/files/%s.deb", root, "ffeeddccbbaa99887766554433221100");
    expect(symlink(step, kept) == 0, "a link to the kept copy is made");
    expect(file_copy_path(root, "ffeeddccbbaa99887766554433221100", kept) != 0, "a linked copy is not used");

    // Control fields as dpkg-deb --field prints them.
    const char *control =
        "Package: com.ultrateam.ultradock\nName: UltraDock\nversion:\t1.0.3 \r\n"
        "Architecture: iphoneos-arm64\nDescription: A dock\n  with a second line\n"
        "Depends: firmware (>= 15.0), mobilesubstrate\nPackaged: no\n";
    size_t control_length = strlen(control);
    char value[130];
    expect(control_field(control, control_length, "Package", value, sizeof value) == 0, "the package is read");
    expect_string(value, "com.ultrateam.ultradock", "the package");
    expect(control_field(control, control_length, "Version", value, sizeof value) == 0,
           "a field is read whatever its case");
    expect_string(value, "1.0.3", "the version without its spaces");
    expect(control_field(control, control_length, "Description", value, sizeof value) == 0, "the description");
    expect_string(value, "A dock", "the description's first line");
    expect(control_field(control, control_length, "Pack", value, sizeof value) != 0, "a prefix is not a field");
    expect(control_field(control, control_length, "Maintainer", value, sizeof value) != 0, "a missing field");
    char small[6];
    expect(control_field(control, control_length, "Package", small, sizeof small) != 0, "a value too long fails");
    expect(control_field("Package:", 8, "Package", value, sizeof value) == 0 && value[0] == '\0',
           "an empty field at the end");

    if (failures) {
        fprintf(stderr, "[purchases] %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("[purchases] %d checks passed\n", checks);
    return 0;
}

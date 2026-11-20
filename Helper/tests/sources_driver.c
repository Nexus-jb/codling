// SPDX-License-Identifier: Apache-2.0
//
// Tests the helper's source file editing: valid_repository_uri and the
// reading, filtering and writing of codling.sources. It includes the helper
// with its main renamed, so that the static functions are in reach.

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

static void expect_text(const char *got, size_t length, const char *expected, const char *what) {
    expect(length == strlen(expected) && memcmp(got, expected, length) == 0, what);
    if (length != strlen(expected) || memcmp(got, expected, length) != 0) {
        fprintf(stderr, "  expected: [%s]\n  got:      [%.*s]\n", expected, (int)length, got);
    }
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s DIRECTORY\n", argv[0]);
        return 2;
    }

    // Addresses as SourceList.repositoryURI writes them, and others.
    const char *good[] = { "https://repo.example.com/", "http://example.github.io/repo/",
                           "https://example.com/~me/repo+beta/", "https://a-b.example.co/x_y/%20/" };
    for (size_t i = 0; i < sizeof good / sizeof *good; i++) {
        expect(valid_repository_uri(good[i]), good[i]);
    }
    const char *bad[] = { "", "https://", "https:///", "ftp://example.com/", "https://example.com",
                          "https://localhost/", "https://Example.com/", "https://example.com:8080/",
                          "https://user@example.com/", "https://example.com/a b/", "https://example.com/?x=1/",
                          "https://example.com/../etc/", "https://example.com/./", "https://-example.com/",
                          "https://.example.com/", "https://example.com./", "https://example.com/a\nb/",
                          "https://example.com/'x'/", "https://example.com/$(id)/" };
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) {
        expect(!valid_repository_uri(bad[i]), bad[i]);
    }

    // Filtering stanzas.
    const char *text = "Types: deb\nURIs: https://a.example.com/\nSuites: ./\n\n\n"
                       "Types: deb\nURIs: https://b.example.com/\nSuites: ./\n\n"
                       "Types: deb\nURIs: https://a.example.com/x/\nSuites: ./";
    char out[1024];
    size_t out_length = 0;
    int dropped = filter_stanzas(text, strlen(text), "https://a.example.com/", out, &out_length);
    expect(dropped == 1, "one stanza has the address");
    expect_text(out, out_length,
               "Types: deb\nURIs: https://b.example.com/\nSuites: ./\n\n"
               "Types: deb\nURIs: https://a.example.com/x/\nSuites: ./\n\n",
               "the other stanzas stay, one blank line apart");
    dropped = filter_stanzas(text, strlen(text), "https://c.example.com/", out, &out_length);
    expect(dropped == 0, "no stanza has another address");
    expect(stanza_has_uri("URIs: https://a.example.com/", 28, "https://a.example.com/"), "a last line without a newline");
    expect(!stanza_has_uri("URIs: https://a.example.com/x/", 30, "https://a.example.com/"), "a longer address is another");

    // Writing and reading the file.
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/codling.sources", argv[1]);
    const char *stanza = "Types: deb\nURIs: https://a.example.com/\nSuites: ./\n\n";
    expect(write_codling_sources(path, stanza, strlen(stanza)) == 0, "the file is written");
    struct stat info;
    expect(stat(path, &info) == 0 && (info.st_mode & 0777) == 0644, "the file is 0644");
    size_t length = 0;
    char *read_back = read_codling_sources(path, &length);
    expect(read_back && length == strlen(stanza) && memcmp(read_back, stanza, length) == 0, "the file reads back");
    free(read_back);
    char partial[PATH_MAX];
    snprintf(partial, sizeof partial, "%s.part", path);
    expect(access(partial, F_OK) != 0, "no temporary file is left");
    expect(write_codling_sources(path, "", 0) == 0 && access(path, F_OK) != 0, "an empty file is removed");
    expect(write_codling_sources(path, "", 0) == 0, "removing a missing file is fine");
    read_back = read_codling_sources(path, &length);
    expect(read_back && length == 0, "a missing file reads as empty");
    free(read_back);

    // Removing a source from any file.
    expect(valid_existing_uri("http://apt.thebigboss.org/repofiles/cydia/"), "an existing address");
    expect(valid_existing_uri("https://Repo.Example.com:8443/a_b/"), "an existing address with a port");
    expect(!valid_existing_uri("https://example.com/a b/"), "an address with a space");
    expect(!valid_existing_uri("ftp://example.com/"), "an ftp address");
    expect(same_uri("https://havoc.app", 17, "https://havoc.app/"), "with or without the last slash");
    expect(!same_uri("https://havoc.app/x", 19, "https://havoc.app/"), "a longer address");

    const char *deb822 = "Types: deb\nURIs: https://havoc.app/\nSuites: ./\nComponents:\n\n"
                         "# Chariz\nTypes: deb\nURIs: https://repo.chariz.com/ https://havoc.app\nSuites: ./\n\n"
                         "Types: deb\nURIs: https://apt.procurs.us/\nSuites: 1900\nComponents: main\n";
    char big[2048];
    dropped = filter_deb822(deb822, strlen(deb822), "https://havoc.app/", big, &out_length);
    expect(dropped == 2, "both mentions of the address go");
    expect_text(big, out_length,
                "# Chariz\nTypes: deb\nURIs: https://repo.chariz.com/\nSuites: ./\n\n"
                "Types: deb\nURIs: https://apt.procurs.us/\nSuites: 1900\nComponents: main\n\n",
                "a stanza with only that address goes; another keeps its other address and comment");

    const char *one_line = "# Sources\ndeb https://havoc.app/ ./\ndeb [trusted=yes] http://limneos.net/repo ./\n"
                           "deb-src https://havoc.app ./\ndeb https://repo.chariz.com/ ./\n";
    dropped = filter_one_line(one_line, strlen(one_line), "https://havoc.app/", big, &out_length);
    expect(dropped == 2, "deb and deb-src lines go");
    expect_text(big, out_length, "# Sources\ndeb [trusted=yes] http://limneos.net/repo ./\ndeb https://repo.chariz.com/ ./\n",
                "the other lines stay as they were");
    dropped = filter_one_line(one_line, strlen(one_line), "http://limneos.net/repo/", big, &out_length);
    expect(dropped == 1, "an address after options");

    char sileo[PATH_MAX];
    snprintf(sileo, sizeof sileo, "%s/sileo.sources", argv[1]);
    const char *only = "Types: deb\nURIs: https://havoc.app/\nSuites: ./\n";
    expect(write_codling_sources(sileo, only, strlen(only)) == 0, "a package manager's file");
    expect(remove_from_file(sileo, "https://repo.chariz.com/", 0) == 0, "an address not in the file");
    expect(remove_from_file(sileo, "https://havoc.app/", 0) == 1, "the address goes");
    read_back = read_codling_sources(sileo, &length);
    expect(read_back && length == 1 && read_back[0] == '\n', "another manager's file stays, empty");
    free(read_back);
    snprintf(path, sizeof path, "%s/codling.sources", argv[1]);
    expect(write_codling_sources(path, only, strlen(only)) == 0 && remove_from_file(path, "https://havoc.app/", 1) == 1 &&
               access(path, F_OK) != 0,
           "an emptied codling.sources is deleted");
    char link_path[PATH_MAX];
    snprintf(link_path, sizeof link_path, "%s/linked.sources", argv[1]);
    expect(write_codling_sources(sileo, only, strlen(only)) == 0 && symlink(sileo, link_path) == 0 &&
               remove_from_file(link_path, "https://havoc.app/", 0) == 0,
           "a link is not followed");

    if (failures) {
        fprintf(stderr, "[sources] %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("[sources] %d checks passed\n", checks);
    return 0;
}

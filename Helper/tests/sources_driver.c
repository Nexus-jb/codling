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

    if (failures) {
        fprintf(stderr, "[sources] %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("[sources] %d checks passed\n", checks);
    return 0;
}

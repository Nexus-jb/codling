// SPDX-License-Identifier: Apache-2.0
//
// A tweak for SpringBoard that crashes it once on purpose, eight seconds
// after SpringBoard starts, so that Burrow's Safe Mode and Codling's
// Turned Off by Safe Mode list can be tried on a real device
// (scripts/make-safe-mode-test-package.sh).
//
// It crashes only once per install: before it schedules the crash it
// creates a marker file, and while the marker exists it does nothing. If
// Safe Mode does not turn it off, SpringBoard still starts normally the
// second time. The package's scripts delete the marker when it is
// installed again or removed.

#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <unistd.h>

static const char marker[] = "/var/mobile/Library/Caches/com.nexusjb.codling-test-crash.crashed";

// The crash site, in this tweak's own code, so that Safe Mode blames it.
__attribute__((noinline)) static void crash_on_purpose(void *context) {
    (void)context;
    __builtin_trap();
}

__attribute__((constructor)) static void start(void) {
    int file = open(marker, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (file < 0) {
        // It crashed once already, or cannot record that it did: either
        // way it does nothing.
        return;
    }
    close(file);
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), NULL,
                     crash_on_purpose);
}

// Phase 0 probe: can this process modify an app bundle, and if not, why?
//
// Creates and immediately removes Contents/.thinner-probe inside the target
// app, then reports the outcome. That is a real modification of the bundle,
// so run it only inside a disposable macOS VM, on a disposable app. It is a
// research instrument, not part of the tool.
//
// PROBE_VARIANT changes the compiled code, and so the code signature, without
// changing behaviour: build it with different values to ask whether an App
// Management grant survives a rebuild. See docs/research/phase0.md.

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#ifndef PROBE_VARIANT
#define PROBE_VARIANT 0
#endif

static const int variant = PROBE_VARIANT;

int main(int argc, char *argv[]) {
    if (argc != 3 || strcmp(argv[1], "--yes-modify") != 0) {
        fprintf(stderr,
                "usage: %s --yes-modify <App.app>\n"
                "Writes and removes a file inside the app bundle. Disposable VMs only.\n",
                argv[0]);
        return 2;
    }

    char path[4096];
    if (snprintf(path, sizeof path, "%s/Contents/.thinner-probe", argv[2]) >= (int)sizeof path) {
        fprintf(stderr, "path too long\n");
        return 2;
    }

    printf("probe variant %d, pid %d, uid %d\n", variant, getpid(), getuid());
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) {
        int err = errno;
        const char *meaning =
            err == EPERM  ? "EPERM: refused by policy, as App Management (TCC) or SIP would" :
            err == EACCES ? "EACCES: file permissions" :
            err == EROFS  ? "EROFS: read-only volume" :
            err == EEXIST ? "EEXIST: a previous probe file is still there; remove it first" :
                            "other";
        printf("DENIED  errno %d (%s) -- %s\n", err, strerror(err), meaning);
        return 1;
    }
    close(fd);
    if (unlink(path) != 0) {
        printf("ALLOWED, but could not remove %s: %s -- remove it by hand\n", path, strerror(errno));
        return 1;
    }
    printf("ALLOWED  created and removed %s\n", path);
    return 0;
}

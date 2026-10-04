// Phase 0 helper: a process that keeps a bundle file in use.
//
//   holder pause   -     READY        runs until killed (run it from inside a bundle)
//   holder map    DYLIB  READY        dlopen()s DYLIB, then runs until killed
//   holder open   FILE   READY        keeps FILE open, then runs until killed
//   holder touch  DYLIB  READY GO     dlopen()s DYLIB, waits for GO, then reads
//                                     every page of its signed constant data
//
// READY and GO are FIFOs: the holder writes "ready" to READY once set up, and
// `touch` blocks reading GO. Disposable fixtures only.

#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    if (argc < 4) { fprintf(stderr, "usage: holder MODE ARG READY [GO]\n"); return 2; }
    const char *mode = argv[1];
    void *h = NULL;
    if (!strcmp(mode, "map") || !strcmp(mode, "touch")) {
        h = dlopen(argv[2], RTLD_NOW);
        if (!h) { fprintf(stderr, "%s\n", dlerror()); return 3; }
    }
    if (!strcmp(mode, "open") && open(argv[2], O_RDONLY) < 0) { perror("open"); return 3; }
    int r = open(argv[3], O_WRONLY);
    if (r >= 0) { write(r, "ready\n", 6); close(r); }
    if (!strcmp(mode, "touch")) {
        char buf[16]; int g = open(argv[4], O_RDONLY);
        if (g >= 0) { read(g, buf, sizeof buf); close(g); }
        unsigned long (*sum)(void) = (unsigned long (*)(void))dlsym(h, "sum");
        printf("read all pages, sum %lu\n", sum());
        return 0;
    }
    for (;;) pause();
}

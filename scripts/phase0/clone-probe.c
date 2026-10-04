// Phase 0 helper: exact clonefile(2) errno and volume free space.
//
//   clone-probe clone SRC DST   clonefile(SRC, DST, CLONE_NOFOLLOW); prints errno
//   clone-probe free PATH       bytes available on PATH's volume (statfs)
//   clone-probe alloc PATH      bytes allocated to PATH (st_blocks * 512)
//
// Used by backup-storage.sh on disk images it creates. Never point it at an
// installed app: CLAUDE.md forbids tests that touch real apps.

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/clonefile.h>
#include <sys/mount.h>
#include <sys/stat.h>

int main(int argc, char *argv[]) {
    if (argc == 4 && strcmp(argv[1], "clone") == 0) {
        if (clonefile(argv[2], argv[3], CLONE_NOFOLLOW) == 0) {
            printf("clone OK\n");
            return 0;
        }
        int err = errno;
        printf("clone FAILED errno %d (%s)\n", err, strerror(err));
        return 1;
    }
    if (argc == 3 && strcmp(argv[1], "free") == 0) {
        struct statfs s;
        if (statfs(argv[2], &s) != 0) { perror("statfs"); return 1; }
        printf("%llu\n", (unsigned long long)s.f_bavail * s.f_bsize);
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "alloc") == 0) {
        struct stat st;
        if (lstat(argv[2], &st) != 0) { perror("lstat"); return 1; }
        printf("%llu\n", (unsigned long long)st.st_blocks * 512);
        return 0;
    }
    fprintf(stderr, "usage: clone-probe clone SRC DST | free PATH | alloc PATH\n");
    return 2;
}

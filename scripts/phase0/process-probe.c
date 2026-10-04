// Phase 0 probe: which processes use any file from a bundle?
//
//   process-probe <Bundle>
//
// For every process: its executable (proc_pidpath), every file-backed memory
// region (PROC_PIDREGIONPATHINFO2), and every open vnode (PROC_PIDLISTFDS +
// PROC_PIDFDVNODEPATHINFO). A file matches by path under the bundle, or by
// (device, inode) of a regular file inside it, which also catches the same
// file reached through another path. nullfs mounts of the bundle (App
// Translocation) are listed and their mount points matched as extra prefixes.
//
// Read-only. Prints matches, then how many processes could be inspected.

#include <errno.h>
#include <ftw.h>
#include <libproc.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef PROC_PIDREGIONPATHINFO2
#define PROC_PIDREGIONPATHINFO2 22
#endif

typedef struct { dev_t dev; ino_t ino; } FileID;
static FileID *ids; static size_t nids, capids;
static char prefixes[8][PATH_MAX]; static int nprefixes;

static int collect(const char *p, const struct stat *st, int flag, struct FTW *f) {
    (void)p; (void)f;
    if (flag == FTW_F && S_ISREG(st->st_mode)) {
        if (nids == capids) { capids = capids ? capids * 2 : 256; ids = realloc(ids, capids * sizeof *ids); }
        ids[nids++] = (FileID){ st->st_dev, st->st_ino };
    }
    return 0;
}

static const char *match(const char *path, dev_t dev, ino_t ino, int have_id) {
    for (int i = 0; i < nprefixes; i++) {
        size_t n = strlen(prefixes[i]);
        if (strncmp(path, prefixes[i], n) == 0 && (path[n] == '/' || path[n] == 0))
            return i == 0 ? "path" : "translocated path";
    }
    if (have_id)
        for (size_t i = 0; i < nids; i++)
            if (ids[i].dev == dev && ids[i].ino == ino) return "file identity";
    return NULL;
}

int main(int argc, char *argv[]) {
    if (argc != 2) { fprintf(stderr, "usage: process-probe <Bundle>\n"); return 2; }
    if (!realpath(argv[1], prefixes[0])) { perror(argv[1]); return 2; }
    nprefixes = 1;
    if (nftw(prefixes[0], collect, 32, FTW_PHYS) != 0) { perror("nftw"); return 2; }

    // App Translocation mounts the original location read-only through nullfs.
    struct statfs *mnts; int nm = getmntinfo(&mnts, MNT_NOWAIT);
    for (int i = 0; i < nm; i++) {
        if (strcmp(mnts[i].f_fstypename, "nullfs") != 0) continue;
        printf("nullfs mount %s from %s\n", mnts[i].f_mntonname, mnts[i].f_mntfromname);
        size_t n = strlen(mnts[i].f_mntfromname);
        if (strncmp(prefixes[0], mnts[i].f_mntfromname, n) == 0 && nprefixes < 8)
            snprintf(prefixes[nprefixes++], PATH_MAX, "%s%s", mnts[i].f_mntonname, prefixes[0] + n);
    }

    int cap = proc_listallpids(NULL, 0) + 64;
    pid_t *pids = calloc(cap, sizeof *pids);
    int np = proc_listallpids(pids, cap * sizeof *pids);
    uid_t me = getuid();
    int exe_ok = 0, reg_ok = 0, fd_ok = 0, reg_denied_other = 0, reg_denied_same = 0, matches = 0;

    for (int k = 0; k < np; k++) {
        pid_t pid = pids[k];
        if (pid == 0) continue;
        struct proc_bsdshortinfo sh; uid_t uid = (uid_t)-1;
        if (proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &sh, sizeof sh) == sizeof sh) uid = sh.pbsi_uid;

        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pid, path, sizeof path) > 0) {
            exe_ok++;
            struct stat st; int have = stat(path, &st) == 0;
            const char *how = match(path, have ? st.st_dev : 0, have ? st.st_ino : 0, have);
            if (how) { matches++; printf("MATCH pid %d uid %d executable (%s): %s\n", pid, uid, how, path); }
        }

        struct proc_regionwithpathinfo r; uint64_t addr = 0; int first = 1, denied = 0;
        for (;;) {
            errno = 0;
            int n = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO2, addr, &r, sizeof r);
            if (n <= 0) { if (first && errno == EPERM) denied = 1; break; }
            first = 0;
            const char *how = match(r.prp_vip.vip_path, r.prp_vip.vip_vi.vi_stat.vst_dev,
                                    r.prp_vip.vip_vi.vi_stat.vst_ino, 1);
            if (how) { matches++; printf("MATCH pid %d uid %d mapped (%s): %s\n", pid, uid, how, r.prp_vip.vip_path); }
            addr = r.prp_prinfo.pri_address + r.prp_prinfo.pri_size;
        }
        if (denied) { if (uid == me) reg_denied_same++; else reg_denied_other++; } else reg_ok++;

        int sz = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
        if (sz <= 0) continue;
        struct proc_fdinfo *fds = malloc(sz + 64 * sizeof *fds);
        sz = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, sz + 64 * sizeof *fds);
        if (sz > 0) fd_ok++;
        for (int i = 0; i < sz / (int)sizeof *fds; i++) {
            if (fds[i].proc_fdtype != PROX_FDTYPE_VNODE) continue;
            struct vnode_fdinfowithpath v;
            if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &v, sizeof v) != sizeof v) continue;
            const char *how = match(v.pvip.vip_path, v.pvip.vip_vi.vi_stat.vst_dev, v.pvip.vip_vi.vi_stat.vst_ino, 1);
            if (how) { matches++; printf("MATCH pid %d uid %d open fd %d (%s): %s\n", pid, uid, fds[i].proc_fd, how, v.pvip.vip_path); }
        }
        free(fds);
    }
    printf("processes %d | executable path readable %d | regions readable %d, denied (same uid %d, other uid %d) | fd list readable %d\n",
           np, exe_ok, reg_ok, reg_denied_same, reg_denied_other, fd_ok);
    printf("matches %d\n", matches);
    return matches ? 1 : 0;
}

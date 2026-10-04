// Phase 0 probe: which architecture did LaunchServices start this app as?
//
// Appends one line to the file named by its first argument (pass it with
// `open -W <App.app> --args <log>`): the slice that is running, and whether
// the process is translated by Rosetta. See docs/research/phase0.md,
// "Rosetta signals".

#include <stdio.h>
#include <sys/sysctl.h>

int main(int argc, char *argv[]) {
#if defined(__x86_64__)
    const char *arch = "x86_64";
#elif defined(__arm64__)
    const char *arch = "arm64";
#else
    const char *arch = "unknown";
#endif
    int translated = 0;
    size_t size = sizeof translated;
    if (sysctlbyname("sysctl.proc_translated", &translated, &size, NULL, 0) != 0) translated = -1;

    FILE *log = argc > 1 ? fopen(argv[1], "a") : stdout;
    if (!log) return 1;
    fprintf(log, "arch=%s translated=%d\n", arch, translated);
    return 0;
}

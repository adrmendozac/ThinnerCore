/// M2 and M3 are activated together only after the release checklist is met.
/// Source-controlled and immutable at runtime: no CLI option, environment
/// variable, or library call opens it.
///
/// A development build may open it at compile time, for manual testing on
/// disposable copies (decided 2026-10-05):
///
///     swift build -c release -Xswiftc -DTHINNER_DEV_MUTATION
///
/// Such a build announces itself on every run and must never be distributed.
/// Release builds and `swift test` are built without the flag.
public enum MutationReleaseGate {
    #if THINNER_DEV_MUTATION
    public static let isOpen = true
    #else
    public static let isOpen = false
    #endif

    /// Printed to stderr by every command of a build with the gate open.
    public static let developmentWarning = "WARNING: development build (THINNER_DEV_MUTATION): thinning, restore, recover, and release are enabled. Use it only on disposable copies of apps; never distribute this build."
}

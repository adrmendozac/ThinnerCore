import Darwin

/// An exclusive lock on one app bundle, held by every operation that changes
/// it: thinning, its rollback, recovery, and restore.
///
/// It is `flock(2)` on the bundle directory itself. No lock file is created
/// next to or inside the app, and the lock belongs to the directory, so every
/// process that opens it contends for the same lock whatever its user. A
/// second process is refused while the first holds it (measured 2026-10-03).
/// Released when the object is freed or the process exits.
final class AppLock {
    private let fd: Int32

    /// `bundle` is the app's real path.
    init(_ bundle: String) throws(Problem) {
        let fd = open(bundle, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Problem("cannot open \(bundle) to lock it: \(errnoDescription())") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            let reason = errnoDescription()
            close(fd)
            throw Problem(busy ? "another operation is changing \(bundle)" : "cannot lock \(bundle): \(reason)")
        }
        self.fd = fd
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

import Darwin
import Foundation

/// Guards for the write path's own path handling.
///
/// Apply needs root to inspect every process, and a root run must not let a
/// less privileged user steer its writes. Staging and the swaps address
/// files by path beside and inside the app, so a user who can change a
/// directory on that path could swap in a symlink and redirect a write as
/// root elsewhere.
enum PathSafety {
    /// Why a run as `euid` must not change the app at `real`, or nil. Only
    /// root runs are checked: anyone else can already write only what they
    /// could write by hand. Every directory above the app must belong to root
    /// or to the user who ran `sudo`, and be writable by no one else, except
    /// through the admin or wheel group (whose members can use `sudo` anyway)
    /// or a sticky bit (which stops others renaming entries they do not own).
    static func untrustedAncestor(of real: String, euid: uid_t = geteuid(),
                                  invoker: uid_t? = sudoUID(),
                                  status: (String) -> stat? = lstatus) -> String? {
        guard euid == 0 else { return nil }
        let owners: Set<uid_t> = Set([0] + [invoker].compactMap { $0 })
        let groups: Set<gid_t> = [0, adminGroup]
        for dir in ancestors(of: real) {
            guard let info = status(dir) else { return "cannot inspect \(dir): \(errnoDescription())" }
            guard info.st_mode & S_IFMT == S_IFDIR else { return "\(dir) is not a directory" }
            guard owners.contains(info.st_uid) else {
                return "\(dir) belongs to \(userName(info.st_uid)), who could redirect a run as root"
            }
            let sticky = info.st_mode & S_ISVTX != 0
            if info.st_mode & S_IWOTH != 0, !sticky {
                return "\(dir) can be changed by every user, who could redirect a run as root"
            }
            if info.st_mode & S_IWGRP != 0, !sticky, !groups.contains(info.st_gid) {
                return "\(dir) can be changed by the group \(groupName(info.st_gid)), whose members could redirect a run as root"
            }
        }
        return nil
    }

    /// The user who ran `sudo`, if this is a run under it.
    static func sudoUID(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> uid_t? {
        environment["SUDO_UID"].flatMap(uid_t.init).flatMap { $0 == 0 ? nil : $0 }
    }

    /// `rename(2)` through both parent directories, opened without following
    /// a symlink anywhere in their paths: a directory swapped for a symlink
    /// after the checks cannot redirect the swap. Nil on success.
    static func renameNoFollow(_ from: String, _ to: String) -> String? {
        let source = (from as NSString).deletingLastPathComponent
        let target = (to as NSString).deletingLastPathComponent
        let sourceFD = open(source, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard sourceFD >= 0 else { return PermissionDiagnostic.describe(errno, path: source) }
        defer { close(sourceFD) }
        let targetFD = open(target, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard targetFD >= 0 else { return PermissionDiagnostic.describe(errno, path: target) }
        defer { close(targetFD) }
        guard renameat(sourceFD, (from as NSString).lastPathComponent, targetFD, (to as NSString).lastPathComponent) == 0 else {
            return PermissionDiagnostic.describe(errno, path: to)
        }
        return nil
    }

    private static func lstatus(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    private static let adminGroup: gid_t = getgrnam("admin")?.pointee.gr_gid ?? 80

    private static func userName(_ uid: uid_t) -> String {
        getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? "user \(uid)"
    }

    private static func groupName(_ gid: gid_t) -> String {
        getgrgid(gid).map { String(cString: $0.pointee.gr_name) } ?? "group \(gid)"
    }
}

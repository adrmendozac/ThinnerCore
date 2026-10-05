import Darwin
import Foundation

/// Mixed-privilege runs are refused (Phase 4 decision, 2026-10-04).
///
/// An operation's staging directory belongs to the user whose run made it:
/// root for a run under `sudo`, the user otherwise. Both kinds of run find it,
/// because it sits beside the app, but only a run as its owner may use it.
/// Anyone else changes nothing and is told the command to rerun. A directory
/// both could write would let a root run trust journals and backups that an
/// unprivileged user can change.
enum StagingOwner {
    /// Why a run as `euid` must not use `staging`, or nil when it may.
    /// `command` and `app` name the command to rerun.
    static func refusal(_ staging: URL, euid: uid_t, rerun command: String, app: String) -> String? {
        var info = stat()
        guard lstat(staging.path, &info) == 0 else {
            return "Nothing was changed: cannot tell which user made \(staging.path): \(errnoDescription())"
        }
        let owner = info.st_uid
        guard owner != euid else { return nil }
        let rerun = "thinnercore \(command) \(shellQuoted(app))"
        let fix = if owner == 0 {
            "it was made by a run as root, so rerun with sudo: sudo \(rerun)"
        } else if euid == 0 {
            "it was made by \(userName(owner)) without sudo, so rerun without sudo as that user: \(rerun)"
        } else {
            "it was made by \(userName(owner)), so rerun as that user: \(rerun)"
        }
        return "Nothing was changed: \(staging.path) belongs to another user; \(fix)"
    }

    private static func userName(_ uid: uid_t) -> String {
        getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? "user \(uid)"
    }

    /// `path` as one shell word.
    static func shellQuoted(_ path: String) -> String {
        let plain = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) }
        return plain && !path.isEmpty ? path : "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

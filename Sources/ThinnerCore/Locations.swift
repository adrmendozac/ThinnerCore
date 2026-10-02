import Foundation

/// A file's identity: the same object whatever path, symlink, firmlink, or
/// letter case reached it.
struct FileID: Hashable {
    let device: dev_t
    let inode: ino_t

    /// Follows symlinks: an identity names what the path points at.
    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}

/// `path` with every symlink resolved, or nil if it does not exist.
func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Every proper ancestor of an absolute path, from "/" down.
func ancestors(of path: String) -> [String] {
    var result = ["/"]
    var current = ""
    for component in path.split(separator: "/").dropLast() {
        current += "/\(component)"
        result.append(current)
    }
    return path == "/" ? [] : result
}

/// Locations the thinner never modifies. Not configurable: no option or future
/// force flag removes them.
public enum ProtectedLocations {
    public static let paths = ["/System"]

    /// Why the app at `path` (absolute, symlinks resolved) is protected, or nil.
    public static func reason(forRealPath path: String) -> String? {
        if let prefix = protectedPrefix(of: path) { return "under \(prefix)" }
        var info = statfs()
        guard statfs(path, &info) == 0 else {
            return "cannot determine its volume: \(errnoDescription())"
        }
        // The sealed system volume is the root filesystem, mounted read-only
        // from a snapshot. /Applications and the rest of the Data volume are
        // not, even though they appear under /.
        if info.f_flags & UInt32(MNT_ROOTFS) != 0 { return "on the sealed system volume" }
        if info.f_flags & UInt32(MNT_RDONLY) != 0 { return "on a read-only volume" }
        return nil
    }

    /// The protected path containing `path`, if any. Directories under it are
    /// not searched.
    static func protectedPrefix(of path: String) -> String? {
        paths.first { path == $0 || path.hasPrefix($0 + "/") }
    }
}

/// The user's exclusions, matched by identity. Each excludes the path itself,
/// everything below it, and any app that contains it.
struct Exclusions {
    private var excluded: [FileID: String] = [:]
    private var containing: [FileID: String] = [:]
    /// Exclusions that name nothing on disk; they match nothing.
    private(set) var missing: [String] = []

    init(_ paths: [URL]) {
        for url in paths {
            guard let real = realPath(url.path), let id = FileID(path: real) else {
                missing.append(url.path)
                continue
            }
            excluded[id] = url.path
            for ancestor in ancestors(of: real) {
                if let id = FileID(path: ancestor) { containing[id] = url.path }
            }
        }
    }

    /// The exclusion naming exactly this object.
    func exclusion(for id: FileID) -> String? {
        excluded[id]
    }

    /// An exclusion somewhere below this object.
    func exclusion(below id: FileID) -> String? {
        containing[id]
    }
}

import Foundation

/// Something the scan could not read or trust, described for the report.
struct Problem: Error, Equatable, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Read-only access to paths under one directory that never follows a symlink.
///
/// Paths are arrays of single names, resolved through the root's descriptor
/// with `O_NOFOLLOW_ANY`, so a symlink anywhere in a path is an error rather
/// than a detour out of the bundle. Only a path's last component may be
/// inspected as a symlink, through `kind` and `readLink`.
final class FileTree {
    enum Kind: Equatable {
        case directory, regular, symlink, other

        init(mode: mode_t) {
            switch mode & S_IFMT {
            case S_IFDIR: self = .directory
            case S_IFREG: self = .regular
            case S_IFLNK: self = .symlink
            default: self = .other
            }
        }
    }

    private let fd: Int32

    /// Opens `root` itself without following a symlink.
    init(_ root: URL) throws(Problem) {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Problem(errnoDescription()) }
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    /// The kind of the entry at `path`, or nil if nothing is there.
    func kind(_ path: [String]) throws(Problem) -> Kind? {
        var info = stat()
        let found: Bool? = try withParent(of: path, missing: nil) { parent, name in
            fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0
        }
        guard let found else { return nil }
        guard found else {
            if errno == ENOENT { return nil }
            throw failure(path)
        }
        return Kind(mode: info.st_mode)
    }

    /// The entries of the directory at `path` (empty for the root), sorted by
    /// name, each with its own kind. Symlinks are reported, never followed.
    func entries(_ path: [String]) throws(Problem) -> [(name: String, kind: Kind)] {
        let dirFD = openat(fd, path.isEmpty ? "." : try Self.join(path), O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard dirFD >= 0 else { throw Problem(Self.reason()) }
        guard let dir = fdopendir(dirFD) else {
            let problem = Problem(Self.reason())
            close(dirFD)
            throw problem
        }
        defer { closedir(dir) }

        var names: [String] = []
        errno = 0
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        if errno != 0 { throw Problem(Self.reason()) }

        var result: [(name: String, kind: Kind)] = []
        for name in names.sorted() {
            var info = stat()
            guard fstatat(dirfd(dir), name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue } // removed since the listing
                throw Problem("\(name): \(Self.reason())")
            }
            result.append((name, Kind(mode: info.st_mode)))
        }
        return result
    }

    /// The target of the symlink at `path`.
    func readLink(_ path: [String]) throws(Problem) -> String {
        let target: String?? = try withParent(of: path, missing: nil) { parent, name in
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlinkat(parent, name, &buffer, buffer.count - 1)
            guard n >= 0 else { return nil }
            return String(decoding: buffer.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        guard let target, let target else { throw failure(path) }
        return target
    }

    /// The whole contents of the regular file at `path`, refused if larger
    /// than `limit` bytes.
    func read(_ path: [String], limit: Int) throws(Problem) -> Data {
        try withRegularFile(path) { file, size throws(Problem) in
            guard size <= limit else { throw Problem("\(path.joined(separator: "/")) is larger than \(limit) bytes") }
            let data = try Self.read(file, count: size, path: path)
            guard data.count == size else { throw Problem("\(path.joined(separator: "/")) shrank while being read") }
            return data
        }
    }

    /// Up to the first `count` bytes of the regular file at `path`.
    func head(_ path: [String], count: Int) throws(Problem) -> Data {
        try withRegularFile(path) { file, size throws(Problem) in
            try Self.read(file, count: min(count, size), path: path)
        }
    }

    private func withRegularFile<T>(_ path: [String], _ body: (Int32, Int) throws(Problem) -> T) throws(Problem) -> T {
        let joined = try Self.join(path)
        let file = openat(fd, joined, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw failure(path) }
        defer { close(file) }

        var info = stat()
        guard fstat(file, &info) == 0 else { throw failure(path) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Problem("\(joined) is not a regular file") }
        return try body(file, Int(info.st_size))
    }

    /// Reads up to `count` bytes from the start; fewer only at end of file.
    private static func read(_ file: Int32, count: Int, path: [String]) throws(Problem) -> Data {
        var data = Data(count: count)
        var filled = 0
        while filled < count {
            let n = data.withUnsafeMutableBytes { raw in
                pread(file, raw.baseAddress! + filled, raw.count - filled, off_t(filled))
            }
            if n > 0 {
                filled += n
            } else if n == 0 {
                break
            } else if errno != EINTR {
                throw Problem("\(path.joined(separator: "/")): \(reason())")
            }
        }
        return data.prefix(filled)
    }

    /// Runs `body` with a descriptor for the directory holding `path`'s last
    /// component. Every component before it must be a real directory; if one
    /// does not exist, returns `missing` without running `body`.
    private func withParent<T>(of path: [String], missing: T, _ body: (Int32, String) -> T) throws(Problem) -> T {
        _ = try Self.join(path)
        guard let name = path.last else { throw Problem("empty path") }
        let parentPath = Array(path.dropLast())
        if parentPath.isEmpty { return body(fd, name) }

        let parent = openat(fd, try Self.join(parentPath), O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else {
            if errno == ENOENT { return missing }
            throw failure(parentPath)
        }
        defer { close(parent) }
        return body(parent, name)
    }

    private func failure(_ path: [String]) -> Problem {
        Problem("\(path.joined(separator: "/")): \(Self.reason())")
    }

    /// The current `errno`, described.
    private static func reason() -> String {
        // O_NOFOLLOW_ANY reports a symlink in the path as ELOOP.
        errno == ELOOP ? "a path component is a symbolic link" : errnoDescription()
    }

    /// Joins names into a relative path, refusing anything that could step
    /// outside the root or name a different entry than it appears to.
    private static func join(_ path: [String]) throws(Problem) -> String {
        for name in path where name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\0") {
            throw Problem("invalid path component \"\(name)\"")
        }
        return path.joined(separator: "/")
    }
}

func errnoDescription() -> String {
    String(cString: strerror(errno))
}

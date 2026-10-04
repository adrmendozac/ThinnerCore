import Foundation

/// A universal (or malformed universal) regular file found by the walker.
public struct WalkedFile: Equatable, Sendable {
    /// Path relative to the walked root. Every component is a real directory:
    /// the walker never reaches a file through a symlink.
    public let relativePath: String
    public let size: UInt64
    /// Every slice's architecture in header order; empty if the header is
    /// malformed.
    public let architectures: [Arch]
    /// From `BundleWalker`, the architecture rule alone; from
    /// `BundleClassifier`, the seal chain too.
    public let decision: Decision
}

/// A path the walker could not read. A walk with issues is incomplete.
public struct WalkIssue: Equatable, Sendable {
    public let relativePath: String
    public let problem: String
}

public struct WalkResult: Equatable, Sendable {
    /// Sorted by path.
    public var files: [WalkedFile] = []
    /// Sorted by path.
    public var issues: [WalkIssue] = []
}

/// Walks a directory tree read-only and classifies every universal file by
/// architecture.
///
/// The walk goes through directory descriptors (`openat`/`fstatat` with
/// `O_NOFOLLOW`), so no symlink is ever followed, even one swapped in during
/// the scan. Only regular files are opened, non-blocking, and at most a fat
/// header plus 8 bytes per slice is read from each.
///
/// Decisions apply the architecture rule only and know nothing about code
/// signatures. `BundleClassifier` adds the seal checks that make a file
/// eligible.
public enum BundleWalker {
    public static func walk(_ root: URL) -> WalkResult {
        var result = WalkResult()
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            // O_DIRECTORY | O_NOFOLLOW on a symlink fails with ENOTDIR, so
            // look at the root itself to say why.
            var problem = errnoDescription()
            var info = stat()
            if lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                problem = "is a symbolic link"
            }
            result.issues.append(WalkIssue(relativePath: "", problem: problem))
            return result
        }
        visit(directory: fd, relativePath: "", into: &result)
        result.files.sort { $0.relativePath < $1.relativePath }
        result.issues.sort { $0.relativePath < $1.relativePath }
        return result
    }

    /// Takes ownership of `fd`.
    private static func visit(directory fd: Int32, relativePath: String, into result: inout WalkResult) {
        guard let dir = fdopendir(fd) else {
            result.issues.append(WalkIssue(relativePath: relativePath, problem: errnoDescription()))
            close(fd)
            return
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
        if errno != 0 {
            result.issues.append(WalkIssue(relativePath: relativePath, problem: errnoDescription()))
        }

        let dirFD = dirfd(dir)
        for name in names.sorted() {
            let path = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            var info = stat()
            guard fstatat(dirFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                result.issues.append(WalkIssue(relativePath: path, problem: errnoDescription()))
                continue
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                let child = openat(dirFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else {
                    result.issues.append(WalkIssue(relativePath: path, problem: errnoDescription()))
                    continue
                }
                visit(directory: child, relativePath: path, into: &result)
            case S_IFREG:
                inspect(name, in: dirFD, relativePath: path, into: &result)
            default:
                continue // symlinks, FIFOs, sockets, devices: never followed or opened
            }
        }
    }

    private static func inspect(_ name: String, in dirFD: Int32, relativePath: String, into result: inout WalkResult) {
        let fd = openat(dirFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            result.issues.append(WalkIssue(relativePath: relativePath, problem: errnoDescription()))
            return
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            result.issues.append(WalkIssue(relativePath: relativePath, problem: errnoDescription()))
            return
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            result.issues.append(WalkIssue(relativePath: relativePath, problem: "changed type during the scan"))
            return
        }
        let size = UInt64(info.st_size)

        let header: [UInt8]
        do {
            header = try read(fd, at: 0, count: FatBinary.maxHeaderLength)
        } catch {
            result.issues.append(WalkIssue(relativePath: relativePath, problem: error.description))
            return
        }

        let parsed = FatBinary.parse(header, fileSize: size)
        var decision = Decision.architectures(parsed, fileSize: size)
        var architectures: [Arch] = []
        switch parsed {
        case .notFat:
            return
        case .malformed:
            break
        case let .fat(binary):
            architectures = binary.slices.map(\.arch)
            for slice in binary.slices {
                let bytes: [UInt8]
                do {
                    bytes = try read(fd, at: slice.offset, count: 8)
                } catch {
                    result.issues.append(WalkIssue(relativePath: relativePath, problem: error.description))
                    return
                }
                if let problem = FatBinary.checkSliceHeader(bytes, for: slice) {
                    decision = .skip(.malformed(problem))
                    break
                }
            }
            // Files with multiple hard links: replacing one path via rename would only
            // change that name, leaving other paths still pointing at the universal
            // original. Skip to avoid breaking other references.
            if case .eligible = decision, info.st_nlink > 1 {
                decision = .skip(.hardLinked)
            }
        }

        result.files.append(WalkedFile(
            relativePath: relativePath, size: size, architectures: architectures, decision: decision
        ))
    }

    private struct ReadError: Error, CustomStringConvertible {
        let description: String
    }

    /// Reads up to `count` bytes at `offset`; fewer only at end of file.
    private static func read(_ fd: Int32, at offset: UInt64, count: Int) throws(ReadError) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let n = buffer.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress! + filled, count - filled, off_t(offset) + off_t(filled))
            }
            if n > 0 {
                filled += n
            } else if n == 0 {
                break
            } else if errno != EINTR {
                throw ReadError(description: errnoDescription())
            }
        }
        return Array(buffer.prefix(filled))
    }

    private static func errnoDescription() -> String {
        String(cString: strerror(errno))
    }
}

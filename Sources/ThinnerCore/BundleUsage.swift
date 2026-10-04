import Darwin
import Foundation

/// Which processes use any file from a bundle: as their executable, mapped
/// into memory, or open. The method chosen in Phase 0 (see
/// `docs/research/phase0.md`, "Running-process detection").
///
/// A file matches by path under the bundle, or by device and inode of a
/// regular file inside it. Identity matching is required: for a hard-linked
/// file the kernel may report any of its names. Mount points of `nullfs`
/// mounts of the bundle (App Translocation) count as extra paths.
///
/// The calling process is never reported: it opens the bundle only to read
/// it. Read-only. Without root, the mapped and open files of other users'
/// processes cannot be read; `Result.uninspectable` counts them so callers
/// can report the limit instead of claiming a complete check.
public enum BundleUsage {
    public struct Use: Equatable, Sendable, CustomStringConvertible {
        public enum How: String, Sendable {
            case executable, mapped, open
        }

        public let pid: pid_t
        public let how: How
        public let path: String

        public var description: String {
            switch how {
            case .executable: "process \(pid) runs \(path)"
            case .mapped: "process \(pid) has \(path) loaded"
            case .open: "process \(pid) has \(path) open"
            }
        }
    }

    public struct Result: Sendable {
        public var uses: [Use] = []
        /// Processes whose loaded and open files could not be read.
        public var uninspectable = 0
        public var inspected = 0

        public init(uses: [Use] = [], uninspectable: Int = 0, inspected: Int = 0) {
            self.uses = uses
            self.uninspectable = uninspectable
            self.inspected = inspected
        }
    }

    public static func scan(_ bundle: URL) throws(Problem) -> Result {
        guard let real = realPath(bundle.path) else {
            throw Problem("cannot resolve \(bundle.path): \(errnoDescription())")
        }
        let matcher = Matcher(bundle: real, files: try fileIDs(under: real))
        var result = Result()

        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        // Returns a count of PIDs, not bytes.
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { throw Problem("cannot list processes: \(errnoDescription())") }

        var seen = Set<String>()
        func record(_ pid: pid_t, _ how: Use.How, _ path: String) {
            if seen.insert("\(pid)|\(how)|\(path)").inserted {
                result.uses.append(Use(pid: pid, how: how, path: path))
            }
        }

        // This process holds the bundle open only to read it.
        let me = getpid()
        for pid in pids.prefix(min(count, capacity)) where pid > 0 && pid != me {
            if let exe = executablePath(pid), matcher.matches(path: exe, id: FileKey(path: exe)) {
                record(pid, .executable, exe)
            }
            var denied = false
            switch regions(pid, matcher) {
            case .denied: denied = true
            case .gone: continue
            case .read(let paths): paths.forEach { record(pid, .mapped, $0) }
            }
            switch openFiles(pid, matcher) {
            case .denied: denied = true
            case .gone: continue
            case .read(let paths): paths.forEach { record(pid, .open, $0) }
            }
            if denied { result.uninspectable += 1 } else { result.inspected += 1 }
        }
        return result
    }

    // MARK: - Matching

    struct FileKey: Hashable {
        let device: UInt64
        let inode: UInt64

        init(device: UInt64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            self.init(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
        }

        init(_ vinfo: vinfo_stat) {
            self.init(device: UInt64(vinfo.vst_dev), inode: vinfo.vst_ino)
        }
    }

    struct Matcher {
        let prefixes: [String]
        let files: Set<FileKey>

        init(bundle: String, files: Set<FileKey>) {
            prefixes = [bundle] + translocatedPaths(of: bundle)
            self.files = files
        }

        func matches(path: String, id: FileKey?) -> Bool {
            if prefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
            return id.map(files.contains) ?? false
        }
    }

    /// Every regular file under `root`, by identity, never following a symlink.
    static func fileIDs(under root: String) throws(Problem) -> Set<FileKey> {
        guard let walker = FileManager.default.enumerator(atPath: root) else {
            throw Problem("cannot list \(root)")
        }
        var ids = Set<FileKey>()
        while let relative = walker.nextObject() as? String {
            var info = stat()
            guard lstat(root + "/" + relative, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            ids.insert(FileKey(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino)))
        }
        return ids
    }

    /// Where App Translocation exposes `bundle`: for each `nullfs` mount whose
    /// source contains the bundle, the same bundle under the mount point.
    static func translocatedPaths(of bundle: String) -> [String] {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = Int(getmntinfo(&mounts, MNT_NOWAIT))
        guard count > 0, let mounts else { return [] }
        var paths: [String] = []
        for mount in UnsafeBufferPointer(start: mounts, count: count) {
            guard cString(mount.f_fstypename) == "nullfs" else { continue }
            let source = cString(mount.f_mntfromname)
            let target = cString(mount.f_mntonname)
            if bundle == source {
                paths.append(target)
            } else if bundle.hasPrefix(source + "/") {
                paths.append(target + bundle.dropFirst(source.count))
            }
        }
        return paths
    }

    // MARK: - libproc

    enum Reading {
        case read([String])
        case denied
        case gone
    }

    /// `PROC_PIDREGIONPATHINFO2`: the next file-backed region at or after an
    /// address. Not exported by the SDK headers Swift imports.
    private static let regionPathInfo2: Int32 = 22

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func regions(_ pid: pid_t, _ matcher: Matcher) -> Reading {
        var info = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        var address: UInt64 = 0
        var first = true
        var paths: [String] = []
        while true {
            errno = 0
            let n = proc_pidinfo(pid, regionPathInfo2, address, &info, size)
            if n <= 0 {
                if first && errno == EPERM { return .denied }
                if first && errno == ESRCH { return .gone }
                break
            }
            first = false
            let path = cString(info.prp_vip.vip_path)
            if matcher.matches(path: path, id: FileKey(info.prp_vip.vip_vi.vi_stat)) { paths.append(path) }
            let next = info.prp_prinfo.pri_address &+ info.prp_prinfo.pri_size
            guard next > address else { break }
            address = next
        }
        return .read(paths)
    }

    static func openFiles(_ pid: pid_t, _ matcher: Matcher) -> Reading {
        errno = 0
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else {
            if errno == ESRCH { return .gone }
            return errno == EPERM ? .denied : .read([])
        }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
        let got = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard got > 0 else { return errno == EPERM ? .denied : .gone }

        var paths: [String] = []
        let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vnode = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, infoSize) == infoSize else { continue }
            let path = cString(vnode.pvip.vip_path)
            if matcher.matches(path: path, id: FileKey(vnode.pvip.vip_vi.vi_stat)) { paths.append(path) }
        }
        return .read(paths)
    }
}

/// A fixed-size C character array imported as a tuple, up to its first NUL.
func cString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
}

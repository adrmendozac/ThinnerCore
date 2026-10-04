import Foundation

/// Copies POSIX metadata from one file to another using explicit system calls,
/// then reads it back and verifies every field matches. `FileManager.replaceItem`
/// is not used because it puts its backup inside the bundle and has undocumented
/// failure modes.
///
/// Metadata that cannot be reproduced (e.g. owner change without root, protected
/// BSD flags) causes a preflight failure before the swap, never a surprise after.
enum MetadataCopier {
    /// The one xattr the read-back ignores. macOS sets `com.apple.provenance`
    /// from the process that writes a file and silently ignores writes to it,
    /// so a thinned or restored file can never carry the original's (Phase 0,
    /// 2026-10-03). Every other xattr must match exactly, with nothing extra.
    static let unreproducibleXattrs: Set<String> = ["com.apple.provenance"]

    struct Metadata: Equatable {
        var uid: uid_t
        var gid: gid_t
        var mode: mode_t
        var flags: UInt32
        var acl: String
        var xattrs: [String: Data]
    }

    /// Reads the POSIX metadata of an open file descriptor.
    static func read(fd: Int32) throws(Problem) -> Metadata {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Problem("fstat: \(errnoDescription())") }
        return Metadata(uid: info.st_uid, gid: info.st_gid,
                        mode: info.st_mode & 0o7777, flags: UInt32(info.st_flags),
                        acl: try readACL(fd), xattrs: try readXattrs(fd))
    }

    /// Applies `source`'s metadata to `dest`, then reads it back and verifies.
    /// Copies owner, group, mode, BSD flags, ACLs, and xattrs.
    ///
    /// Returns a problem description if any field cannot be reproduced on the
    /// destination. Callers must treat this as a preflight failure: the file is
    /// not eligible for the swap.
    static func copy(from sourcePath: String, to destPath: String,
                     sourceFD: Int32, destFD: Int32) throws(Problem) -> String? {
        let source = try read(fd: sourceFD)

        // Owner and group.
        if fchown(destFD, source.uid, source.gid) != 0 {
            return "cannot set owner: \(errnoDescription())"
        }

        // Mode bits.
        if fchmod(destFD, source.mode) != 0 {
            return "cannot set mode: \(errnoDescription())"
        }

        // Copy ACLs and xattrs through the already-open descriptors.
        let copyFlags = copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR | COPYFILE_NOFOLLOW)
        if fcopyfile(sourceFD, destFD, nil, copyFlags) != 0 {
            return "cannot copy ACLs and xattrs: \(errnoDescription())"
        }

        // copyfile(3) rewrites the timestamp in `com.apple.quarantine`, so set
        // every reproducible xattr again with the source's exact bytes.
        for (name, value) in source.xattrs where !unreproducibleXattrs.contains(name) {
            let status = value.withUnsafeBytes { fsetxattr(destFD, name, $0.baseAddress, $0.count, 0, 0) }
            if status != 0 {
                return "cannot set xattr \(name): \(errnoDescription())"
            }
        }

        // BSD flags last: an immutable flag would block the xattr writes.
        // chflags(2) cannot set system flags without root, so report inability
        // rather than silently losing them.
        if fchflags(destFD, source.flags) != 0 {
            return "cannot set BSD flags 0x\(String(source.flags, radix: 16)): \(errnoDescription())"
        }

        return try verify(fd: destFD, expected: source)
    }

    /// Whether `actual` reproduces `expected`: every field equal, ignoring
    /// only `unreproducibleXattrs`.
    static func matches(_ actual: Metadata, _ expected: Metadata) -> Bool {
        func comparable(_ metadata: Metadata) -> Metadata {
            var metadata = metadata
            metadata.xattrs = metadata.xattrs.filter { !unreproducibleXattrs.contains($0.key) }
            return metadata
        }
        return comparable(actual) == comparable(expected)
    }

    static func verify(fd: Int32, expected: Metadata) throws(Problem) -> String? {
        matches(try read(fd: fd), expected) ? nil : "metadata mismatch after copy (owner, mode, flags, ACL or xattrs differ)"
    }
    private static func readACL(_ fd: Int32) throws(Problem) -> String {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return "" } // descriptor has no extended ACL
            throw Problem("cannot read ACL: \(errnoDescription())")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length = 0
        guard let text = acl_to_text(acl, &length) else {
            throw Problem("cannot serialize ACL: \(errnoDescription())")
        }
        defer { acl_free(text) }
        return String(decoding: UnsafeRawBufferPointer(start: text, count: length), as: UTF8.self)
    }

    private static func readXattrs(_ fd: Int32) throws(Problem) -> [String: Data] {
        let count = flistxattr(fd, nil, 0, 0)
        guard count >= 0 else { throw Problem("cannot list xattrs: \(errnoDescription())") }
        var names = [CChar](repeating: 0, count: count)
        let actual = names.withUnsafeMutableBufferPointer { flistxattr(fd, $0.baseAddress, count, 0) }
        guard actual == count else { throw Problem("xattr list changed or could not be read") }
        var values: [String: Data] = [:]
        for bytes in names.split(separator: 0) {
            let name = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let size = fgetxattr(fd, name, nil, 0, 0, 0)
            guard size >= 0 else { throw Problem("cannot read xattr \(name): \(errnoDescription())") }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, size, 0, 0) }
            guard read == size else { throw Problem("xattr \(name) changed or could not be read") }
            values[name] = data
        }
        return values
    }

}

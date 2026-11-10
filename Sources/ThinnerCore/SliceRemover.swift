import Darwin

/// Removes slices from a universal binary in-process, writing exactly what
/// `lipo <input> -remove <arch>… -output <output>` writes (decided 2026-11-09):
/// a fat header (`FAT_MAGIC`, or `FAT_MAGIC_64` only when needed; see
/// `FatBinary.Layout`) listing the kept slices in their original order, even
/// when only one is left, then
/// each kept slice copied byte for byte at its own alignment, zero-filled in
/// between, with nothing after the last one. `FatBinary.size(removing:)`
/// models the same layout, and a test compares the output with `lipo`'s.
///
/// Replaces running `lipo`, which needs the developer tools and, under
/// `sudo`, would run a binary from outside the system volume as root.
///
/// It never touches `input`. It refuses to leave a file without an ordinary
/// arm64 slice, and to remove an architecture the file does not contain.
/// The caller still verifies the result: size, slices, and the hash of
/// every kept slice against the original.
enum SliceRemover {
    static func remove(_ architectures: Set<Arch>, from input: String, to output: String) throws(Problem) {
        let source = open(input, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { throw Problem("cannot open \(input): \(errnoDescription())") }
        defer { close(source) }
        var info = stat()
        guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw Problem("\(input) is not a regular file")
        }
        let fileSize = UInt64(clamping: info.st_size)

        let header = try read(source, at: 0, count: FatBinary.maxHeaderLength, path: input)
        guard case let .fat(binary) = FatBinary.parse(header, fileSize: fileSize) else {
            throw Problem("\(input) is not a well-formed universal binary")
        }
        let present = Set(binary.slices.map(\.arch))
        guard !architectures.isEmpty, architectures.isSubset(of: present) else {
            throw Problem("\(input) does not contain every slice to remove")
        }
        let kept = binary.slices.filter { !architectures.contains($0.arch) }
        guard kept.contains(where: { $0.arch == .arm64 }) else {
            throw Problem("removing these slices would leave \(input) without an arm64 slice")
        }

        // The one layout the size estimate also uses.
        let layout = binary.layout(removing: architectures)
        let placed = layout.offsets
        let end = layout.size
        let fileOrder = kept.indices.sorted { kept[$0].offset < kept[$1].offset }

        var newHeader = be32(layout.is64 ? FatBinary.magic64 : FatBinary.magic) + be32(UInt32(kept.count))
        for (i, slice) in kept.enumerated() {
            newHeader += be32(UInt32(bitPattern: slice.cpuType)) + be32(UInt32(bitPattern: slice.cpuSubtype))
            if layout.is64 {
                newHeader += be64(placed[i]) + be64(slice.size) + be32(slice.align) + be32(0)
            } else {
                // The layout chose 32 bits only because these fit.
                newHeader += be32(UInt32(placed[i])) + be32(UInt32(slice.size)) + be32(slice.align)
            }
        }

        let dest = open(output, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard dest >= 0 else { throw Problem("cannot create \(output): \(errnoDescription())") }
        var finished = false
        defer {
            close(dest)
            if !finished { unlink(output) }
        }

        var position: UInt64 = 0
        try write(dest, newHeader, path: output, position: &position)
        for i in fileOrder {
            let slice = kept[i]
            let offset = placed[i]
            try write(dest, [UInt8](repeating: 0, count: Int(offset - position)), path: output, position: &position)
            var copied: UInt64 = 0
            while copied < slice.size {
                let chunk = try read(source, at: slice.offset + copied,
                                     count: Int(min(slice.size - copied, 1 << 20)), path: input)
                guard !chunk.isEmpty else { throw Problem("\(input) shrank while being thinned") }
                try write(dest, chunk, path: output, position: &position)
                copied += UInt64(chunk.count)
            }
        }
        guard position == end else { throw Problem("wrote \(position) bytes to \(output), expected \(end)") }
        finished = true
    }

    /// Up to `count` bytes at `offset`; fewer only at end of file.
    private static func read(_ fd: Int32, at offset: UInt64, count: Int, path: String) throws(Problem) -> [UInt8] {
        guard offset <= UInt64(Int64.max) else { throw Problem("\(path): offset out of range") }
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
                throw Problem("cannot read \(path): \(errnoDescription())")
            }
        }
        return Array(buffer.prefix(filled))
    }

    private static func write(_ fd: Int32, _ bytes: [UInt8], path: String, position: inout UInt64) throws(Problem) {
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress! + done, raw.count - done) }
            if n > 0 {
                done += n
            } else if n == 0 || errno != EINTR {
                throw Problem("cannot write \(path): \(n == 0 ? "short write" : errnoDescription())")
            }
        }
        position += UInt64(bytes.count)
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    private static func be64(_ value: UInt64) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }
}

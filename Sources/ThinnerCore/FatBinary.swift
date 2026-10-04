/// One architecture slice of a universal binary, as its `fat_arch` entry
/// describes it.
public struct FatSlice: Equatable, Sendable {
    public let arch: Arch
    public let cpuType: Int32
    public let cpuSubtype: Int32
    public let offset: UInt64
    public let size: UInt64
    public let align: UInt32
}

public enum FatParseResult: Equatable, Sendable {
    /// Not a universal binary. Includes Java class files, which share the magic.
    case notFat
    case fat(FatBinary)
    /// Has a universal header that cannot be trusted. Never thin these.
    case malformed(String)
}

/// A parsed universal (fat) Mach-O header. Parsing is pure: callers supply the
/// bytes, so every rule here is testable without touching the filesystem.
public struct FatBinary: Equatable, Sendable {
    public let is64: Bool
    public let slices: [FatSlice]

    public static let magic: UInt32 = 0xCAFE_BABE
    public static let magic64: UInt32 = 0xCAFE_BABF

    /// Java class files also start with 0xCAFEBABE. Their version fields sit
    /// where `nfat_arch` would be and read as 45 or more; universal binaries
    /// carry a handful of slices.
    public static let maxSlices: UInt32 = 30

    /// Largest slice alignment accepted: 2^16. Real slices use 2^12 (x86_64)
    /// or 2^14 (arm64).
    public static let maxAlign: UInt32 = 16

    /// Enough leading bytes to hold any header `parse` accepts.
    public static let maxHeaderLength = headerLength(is64: true, count: Int(maxSlices))

    static func headerLength(is64: Bool, count: Int) -> Int {
        8 + (is64 ? 32 : 20) * count
    }

    /// Parses a fat header from the leading bytes of a file.
    public static func parse(_ header: [UInt8], fileSize: UInt64) -> FatParseResult {
        guard header.count >= 8 else { return .notFat }
        let magic = readBE32(header, 0)
        guard magic == Self.magic || magic == Self.magic64 else { return .notFat }
        let is64 = magic == Self.magic64

        let count = readBE32(header, 4)
        guard (1...maxSlices).contains(count) else { return .notFat }

        let headerSize = headerLength(is64: is64, count: Int(count))
        guard header.count >= headerSize, UInt64(headerSize) <= fileSize else {
            return .malformed("header is truncated")
        }

        var slices: [FatSlice] = []
        for index in 0..<Int(count) {
            let base = 8 + index * (is64 ? 32 : 20)
            let cpuType = Int32(bitPattern: readBE32(header, base))
            let cpuSubtype = Int32(bitPattern: readBE32(header, base + 4))
            let offset, size: UInt64
            let align: UInt32
            if is64 {
                offset = readBE64(header, base + 8)
                size = readBE64(header, base + 16)
                align = readBE32(header, base + 24)
            } else {
                offset = UInt64(readBE32(header, base + 8))
                size = UInt64(readBE32(header, base + 12))
                align = readBE32(header, base + 16)
            }

            let slice = FatSlice(
                arch: Arch(cpuType: cpuType, cpuSubtype: cpuSubtype),
                cpuType: cpuType, cpuSubtype: cpuSubtype,
                offset: offset, size: size, align: align
            )
            let problem: String? =
                if align > maxAlign { "alignment 2^\(align) is out of range" }
                else if size == 0 { "is empty" }
                else if offset < UInt64(headerSize) { "overlaps the fat header" }
                else if offset % (UInt64(1) << align) != 0 { "is not aligned to 2^\(align)" }
                else if offset > fileSize || size > fileSize - offset { "extends past the end of the file" }
                else { nil }
            if let problem {
                return .malformed("slice \(index) (\(slice.arch)) \(problem)")
            }
            slices.append(slice)
        }

        let byOffset = slices.sorted { $0.offset < $1.offset }
        for (a, b) in zip(byOffset, byOffset.dropFirst()) where a.offset + a.size > b.offset {
            return .malformed("slices \(a.arch) and \(b.arch) overlap")
        }
        if Set(slices.map(\.arch)).count != slices.count {
            return .malformed("an architecture appears twice")
        }

        return .fat(FatBinary(is64: is64, slices: slices))
    }

    /// Checks the leading bytes at a slice's offset: they must be a Mach-O
    /// header whose `cputype` matches the fat entry. Returns the problem, or
    /// nil if the slice is what the header says it is.
    public static func checkSliceHeader(_ bytes: [UInt8], for slice: FatSlice) -> String? {
        guard bytes.count >= 8 else { return "slice \(slice.arch) is truncated" }
        let cpuType: Int32
        switch readBE32(bytes, 0) {
        case 0xCFFA_EDFE, 0xCEFA_EDFE: // MH_MAGIC_64 / MH_MAGIC, little-endian on disk
            cpuType = Int32(bitPattern: readLE32(bytes, 4))
        case 0xFEED_FACF, 0xFEED_FACE:
            cpuType = Int32(bitPattern: readBE32(bytes, 4))
        default:
            return "slice \(slice.arch) is not a Mach-O image"
        }
        guard cpuType == slice.cpuType else {
            return "slice \(slice.arch) contains code for a different CPU"
        }
        return nil
    }

    /// The file size `lipo -remove` produces: a fat header for the slices that
    /// remain, then each one at its alignment, in their original order. lipo
    /// keeps a fat header even when only one slice is left.
    public func size(removing archs: Set<Arch>) -> UInt64 {
        let kept = slices.filter { !archs.contains($0.arch) }.sorted { $0.offset < $1.offset }
        var end = UInt64(Self.headerLength(is64: is64, count: kept.count))
        for slice in kept {
            let alignment = UInt64(1) << slice.align
            end = (end + alignment - 1) / alignment * alignment + slice.size
        }
        return end
    }
}

func readBE32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
    bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
}

func readLE32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
    bytes[at..<at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
}

private func readBE64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
    bytes[at..<at + 8].reduce(0) { $0 << 8 | UInt64($1) }
}

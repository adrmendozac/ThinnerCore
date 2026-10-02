import ThinnerCore

/// Builders for synthetic universal headers, shared by parser and classifier
/// tests so every rule can be exercised without touching the filesystem.

let cpuARM64: Int32 = 0x0100_000C
let cpuX86_64: Int32 = 0x0100_0007

/// One `fat_arch` entry for a synthetic header.
struct Entry {
    var cpuType: Int32
    var cpuSubtype: Int32
    var offset: UInt64
    var size: UInt64
    var align: UInt32

    static func x86_64(offset: UInt64 = 4096, size: UInt64 = 8000, align: UInt32 = 12) -> Entry {
        Entry(cpuType: cpuX86_64, cpuSubtype: 3, offset: offset, size: size, align: align)
    }

    static func arm64(offset: UInt64 = 16384, size: UInt64 = 10000, align: UInt32 = 14) -> Entry {
        Entry(cpuType: cpuARM64, cpuSubtype: 0, offset: offset, size: size, align: align)
    }
}

/// The layout `lipo -create` produces for x86_64 + arm64: header, x86_64 at
/// 2^12, arm64 at 2^14. The file ends exactly where the arm64 slice does.
let standardEntries = [Entry.x86_64(), Entry.arm64()]
let standardFileSize: UInt64 = 16384 + 10000

/// Builds a big-endian fat header. `count` overrides `nfat_arch` so tests can
/// declare more entries than they supply.
func fatHeader(fat64: Bool = false, count: UInt32? = nil, _ entries: [Entry]) -> [UInt8] {
    var bytes = be32(fat64 ? FatBinary.magic64 : FatBinary.magic) + be32(count ?? UInt32(entries.count))
    for entry in entries {
        bytes += be32(UInt32(bitPattern: entry.cpuType)) + be32(UInt32(bitPattern: entry.cpuSubtype))
        if fat64 {
            bytes += be64(entry.offset) + be64(entry.size) + be32(entry.align) + be32(0) // reserved
        } else {
            bytes += be32(UInt32(entry.offset)) + be32(UInt32(entry.size)) + be32(entry.align)
        }
    }
    return bytes
}

func be32(_ value: UInt32) -> [UInt8] {
    (0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}

func be64(_ value: UInt64) -> [UInt8] {
    (0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}

extension FatParseResult {
    var fat: FatBinary? {
        if case let .fat(binary) = self { binary } else { nil }
    }
}

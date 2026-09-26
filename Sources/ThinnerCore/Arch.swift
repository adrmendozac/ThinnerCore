/// A slice's architecture, decoded from the `cputype`/`cpusubtype` pair in its
/// `fat_arch` entry.
public enum Arch: Hashable, Sendable, CustomStringConvertible {
    case arm64
    case arm64e
    case x86_64
    case x86_64h
    /// Anything else. Kept so reports can name it; never removed, and never
    /// counted as runnable on Apple Silicon.
    case other(cpuType: Int32, cpuSubtype: Int32)

    static let cpuTypeX86_64: Int32 = 0x0100_0007
    static let cpuTypeARM64: Int32 = 0x0100_000C

    /// The top byte of `cpusubtype` holds capability bits (for example the
    /// arm64e pointer-authentication ABI flag), not the subtype itself.
    static let subtypeMask: Int32 = 0x00FF_FFFF

    public init(cpuType: Int32, cpuSubtype: Int32) {
        switch (cpuType, cpuSubtype & Self.subtypeMask) {
        case (Self.cpuTypeARM64, 0), (Self.cpuTypeARM64, 1): self = .arm64 // ALL, V8
        case (Self.cpuTypeARM64, 2): self = .arm64e
        case (Self.cpuTypeX86_64, 3): self = .x86_64 // ALL
        case (Self.cpuTypeX86_64, 8): self = .x86_64h
        default: self = .other(cpuType: cpuType, cpuSubtype: cpuSubtype)
        }
    }

    /// Intel slices are the ones the thinner removes.
    public var isIntel: Bool {
        self == .x86_64 || self == .x86_64h
    }

    /// The name `lipo` uses for this architecture.
    public var description: String {
        switch self {
        case .arm64: "arm64"
        case .arm64e: "arm64e"
        case .x86_64: "x86_64"
        case .x86_64h: "x86_64h"
        case let .other(cpuType, cpuSubtype):
            "cputype 0x\(String(UInt32(bitPattern: cpuType), radix: 16)) "
                + "subtype 0x\(String(UInt32(bitPattern: cpuSubtype), radix: 16))"
        }
    }
}

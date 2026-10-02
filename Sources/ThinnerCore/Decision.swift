/// What the classifier decided for one file.
public enum Decision: Equatable, Sendable {
    /// Statically eligible: removing these slices leaves an ordinary arm64
    /// slice and shrinks the file by `savedBytes` (logical, not physical).
    /// Not authorization to modify; the write path rechecks with fresh inputs.
    case eligible(removing: Set<Arch>, savedBytes: UInt64)
    case skip(SkipReason)
}

/// Why a file is left alone.
public enum SkipReason: Hashable, Sendable, CustomStringConvertible {
    /// Not a universal binary; there is nothing to thin.
    case notUniversal
    /// The universal header or a slice cannot be trusted.
    case malformed(String)
    /// No ordinary arm64 slice. arm64e alone is not proof the file runs.
    case noARM64
    /// Universal, but without an Intel slice to remove.
    case noIntel
    /// Alignment padding absorbs the Intel slices, so removing them would not
    /// shrink the file. Thinning would be all risk and no gain.
    case noSavings
    /// The file has other hard links. Replacing it by rename would change only
    /// this name and leave the others pointing at the universal original.
    case hardLinked
    /// An enclosing bundle seals the file's bytes (`hash`/`hash2`), so any
    /// change breaks that bundle's signature. `by` is the bundle's path
    /// relative to the scanned bundle; empty for the scanned bundle itself.
    case sealedAsData(by: String)
    /// No enclosing seal accounts for the file as code. Absence from a seal
    /// never makes a file eligible.
    case unsealed(String)
    /// Signature metadata is missing, unreadable, or ambiguous. Skip, never
    /// guess.
    case signatureMetadata(String)

    /// A stable identifier for reports. Never changes once published.
    public var code: String {
        switch self {
        case .notUniversal: "notUniversal"
        case .malformed: "malformed"
        case .noARM64: "noARM64"
        case .noIntel: "noIntel"
        case .noSavings: "noSavings"
        case .hardLinked: "hardLinked"
        case .sealedAsData: "sealedAsData"
        case .unsealed: "unsealed"
        case .signatureMetadata: "signatureMetadata"
        }
    }

    public var description: String {
        switch self {
        case .notUniversal: "not a universal binary"
        case let .malformed(problem): "malformed universal binary: \(problem)"
        case .noARM64: "no arm64 slice"
        case .noIntel: "no Intel slice to remove"
        case .noSavings: "removing the Intel slices would not shrink the file"
        case .hardLinked: "has other hard links"
        case let .sealedAsData(by):
            "sealed as data by \(by.isEmpty ? "the bundle" : by); thinning would break its signature"
        case let .unsealed(detail): "not sealed as code: \(detail)"
        case let .signatureMetadata(detail): "signature metadata missing or unreadable: \(detail)"
        }
    }
}

extension Decision {
    public var isEligible: Bool {
        if case .eligible = self { true } else { false }
    }

    /// Logical bytes removing the slices would save; zero when skipped.
    public var savedBytes: UInt64 {
        if case let .eligible(_, saved) = self { saved } else { 0 }
    }

    /// The architecture rule on its own: a file is eligible only if it has an
    /// ordinary arm64 slice and at least one Intel slice, and removing every
    /// Intel slice makes it smaller. Other architectures are always kept.
    public static func architectures(_ parsed: FatParseResult, fileSize: UInt64) -> Decision {
        let binary: FatBinary
        switch parsed {
        case .notFat: return .skip(.notUniversal)
        case let .malformed(problem): return .skip(.malformed(problem))
        case let .fat(fat): binary = fat
        }

        let archs = Set(binary.slices.map(\.arch))
        guard archs.contains(.arm64) else { return .skip(.noARM64) }
        let intel = archs.filter(\.isIntel)
        guard !intel.isEmpty else { return .skip(.noIntel) }

        let thinned = binary.size(removing: intel)
        guard thinned < fileSize else { return .skip(.noSavings) }
        return .eligible(removing: intel, savedBytes: fileSize - thinned)
    }
}

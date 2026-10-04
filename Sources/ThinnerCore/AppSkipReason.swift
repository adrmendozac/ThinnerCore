/// Why a whole app is left alone, whatever its files' decisions.
public enum AppSkipReason: Hashable, Sendable, CustomStringConvertible {
    /// Under `/System`, on the sealed system volume, or on a read-only volume.
    case protectedLocation(String)
    /// The app is, or is inside, a path the user excluded.
    case excluded(String)
    /// A path the user excluded is inside the app. The whole app is skipped:
    /// excluding more than asked is safe, less is not.
    case containsExclusion(String)
    /// `Info.plist` or the main executable cannot be read or trusted.
    case bundleMetadata(String)
    /// The main executable is not a Mach-O binary. macOS may run such apps
    /// under Rosetta, so no code in them is thinned.
    case scriptOnly(String)
    /// The user set "Open using Rosetta" for this app. A user choice, with the
    /// standing of an exclusion.
    case rosettaFlagged(user: String)
    /// The "Open using Rosetta" setting could not be read, so it may be set.
    case rosettaInconclusive(String)
    /// The main executable has no ordinary arm64 slice, so the app runs under
    /// Rosetta; removing x86_64 from its other code would break it. Applies
    /// to thin Intel executables, which the walker never lists.
    case noNativeMainExecutable([String])
    /// `LSArchitecturePriority` in `Info.plist` does not select the main
    /// executable's arm64 slice: the first listed architecture the executable
    /// contains is Intel (the app runs under Rosetta, Phase 0), another
    /// non-arm64 slice, or none. Thinning would force native execution, so no
    /// force option overrides this.
    case intelArchitecturePriority([String])
    /// `codesign --verify --deep --strict --all-architectures` rejects the app
    /// as it is. Thinning must start from a valid signature.
    case signatureInvalid(String)

    /// A stable identifier for reports. Never changes once published.
    public var code: String {
        switch self {
        case .protectedLocation: "protectedLocation"
        case .excluded: "excluded"
        case .containsExclusion: "containsExclusion"
        case .bundleMetadata: "bundleMetadata"
        case .scriptOnly: "scriptOnly"
        case .rosettaFlagged: "rosettaFlagged"
        case .rosettaInconclusive: "rosettaInconclusive"
        case .noNativeMainExecutable: "noNativeMainExecutable"
        case .intelArchitecturePriority: "intelArchitecturePriority"
        case .signatureInvalid: "signatureInvalid"
        }
    }

    public var description: String {
        switch self {
        case let .protectedLocation(detail): "protected location: \(detail)"
        case let .excluded(path): "excluded by the user (\(path))"
        case let .containsExclusion(path): "contains a path excluded by the user (\(path))"
        case let .bundleMetadata(detail): "bundle metadata missing or unreadable: \(detail)"
        case let .scriptOnly(detail): "no executable binary (script-only app): \(detail)"
        case let .rosettaFlagged(user): "set to Open using Rosetta in \(user)'s preferences"
        case let .rosettaInconclusive(detail): "cannot tell whether it is set to Open using Rosetta: \(detail)"
        case let .noNativeMainExecutable(archs):
            "the main executable has no arm64 slice (\(archs.joined(separator: ", "))), so the app runs under Rosetta"
        case let .intelArchitecturePriority(archs):
            "LSArchitecturePriority does not select the arm64 slice (\(archs.joined(separator: ", ")))"
        case let .signatureInvalid(detail): "fails code signature verification: \(detail)"
        }
    }
}

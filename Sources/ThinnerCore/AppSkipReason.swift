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
    /// The app contains code with an Intel slice and no arm64 slice: a
    /// helper, plugin, or library that runs only under Rosetta and may load
    /// the universal code thinning would change. Skipped whole (decided
    /// 2026-10-05). Bundle-relative paths.
    case intelOnlyCode([String])
    /// The app's bundle identifier is on the user's skip list. A user choice,
    /// with the standing of an exclusion.
    case skipListed(String)
    /// The skip list exists but cannot be read, so any app may be on it.
    case skipListUnreadable(String)
    /// The user's allow list has entries and none names this app. A user
    /// choice, with the standing of an exclusion.
    case notOnAllowList
    /// The allow list exists but cannot be read, so it is unknown which apps
    /// it allows.
    case allowListUnreadable(String)
    /// `codesign --verify --deep --strict --all-architectures` rejects the app
    /// as it is. Thinning must start from a valid signature.
    case signatureInvalid(String)
    /// Advisory: a Mac App Store app (it has `Contents/_MASReceipt`). How the
    /// App Store's updates and receipt checks treat thinned files is
    /// unmeasured. In the 2026-11-09 corpus no App Store app had an eligible
    /// file (all carried flags a thinned copy cannot keep), so the default
    /// costs nothing there.
    case masApp
    /// Advisory: the app embeds a system extension, DriverKit extension, or
    /// kernel extension (network, VPN, antivirus, endpoint security). macOS
    /// activates those from the app bundle, and a broken one is costly. The
    /// extensions' own files were sealed as data in the 2026-11-09 corpus, so
    /// they were never thinnable; this also leaves the rest of the app alone.
    /// Bundle-relative paths.
    case embedsSystemExtension([String])

    /// True for a skip Phase 7 chose as a default, on compatibility grounds
    /// rather than a safety rule. Only these may ever be lifted, by a future
    /// force option (decided 2026-11-09; there is no such option yet). Every
    /// other reason is a hard rule, a user choice, or an unreadable input.
    public var isAdvisory: Bool {
        switch self {
        case .masApp, .embedsSystemExtension: true
        default: false
        }
    }

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
        case .intelOnlyCode: "intelOnlyCode"
        case .signatureInvalid: "signatureInvalid"
        case .skipListed: "skipListed"
        case .skipListUnreadable: "skipListUnreadable"
        case .notOnAllowList: "notOnAllowList"
        case .allowListUnreadable: "allowListUnreadable"
        case .masApp: "masApp"
        case .embedsSystemExtension: "embedsSystemExtension"
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
        case let .intelOnlyCode(paths):
            "contains Intel-only code that runs under Rosetta and may load the code thinning would change ("
                + paths.prefix(3).joined(separator: ", ") + (paths.count > 3 ? ", and \(paths.count - 3) more" : "") + ")"
        case let .signatureInvalid(detail): "fails code signature verification: \(detail)"
        case let .skipListed(id): "on the user's skip list (\(id))"
        case let .skipListUnreadable(detail): "cannot read the skip list, so it may list this app: \(detail)"
        case .notOnAllowList: "not on the user's allow list, which names the only apps to thin"
        case let .allowListUnreadable(detail): "cannot read the allow list, so it is unknown which apps it allows: \(detail)"
        case .masApp: "a Mac App Store app (advisory default: App Store updates and receipt checks on thinned apps are unmeasured)"
        case let .embedsSystemExtension(paths):
            "embeds a system or kernel extension, as VPN and security software does (advisory default): "
                + paths.prefix(3).joined(separator: ", ") + (paths.count > 3 ? ", and \(paths.count - 3) more" : "")
        }
    }
}

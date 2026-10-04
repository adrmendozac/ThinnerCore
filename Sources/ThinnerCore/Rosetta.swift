import Foundation

/// What the scan learned about Rosetta, reported once per scan.
public struct RosettaStatus: Equatable, Sendable {
    public enum Preferences: Equatable, Sendable {
        /// No LaunchServices preferences file: no app is set to use Rosetta.
        case absent
        /// Read; `flagged` bundle IDs have an "Open using Rosetta" entry.
        case read(flagged: Int)
        /// Unreadable or in an unexpected format. Every app is skipped as
        /// inconclusive.
        case unreadable(String)
    }

    /// Signal 1: the Rosetta runtime is installed. Informational: without it
    /// nothing runs under Rosetta today, but per-app flags are still checked.
    public let installed: Bool
    /// Signal 2 reads one user's preferences; a scan cannot see other users'
    /// "Open using Rosetta" choices.
    public let preferencesPath: String
    public let preferencesUser: String
    public let preferences: Preferences
}

/// The per-app "Open using Rosetta" flags from LaunchServices preferences.
///
/// The flags live in a dictionary keyed by bundle ID; each entry holds a
/// bookmark to the flagged copy and the architecture to run. macOS 27 names
/// that dictionary `Architectures(arm64)` (Phase 0, 2026-10-03). The earlier
/// assumed name `LSArchitecturesForX86_64` is still read, since older versions
/// are unmeasured. The keys are undocumented, so anything but the expected
/// shape is inconclusive, never "not flagged".
struct RosettaFlags {
    enum Flag: Equatable {
        case notFlagged
        case flagged
        case inconclusive(String)
    }

    static let legacyKey = "LSArchitecturesForX86_64"

    /// `Architectures(<host arch>)`, or the legacy name.
    static func isFlagKey(_ key: String) -> Bool {
        key == legacyKey || (key.hasPrefix("Architectures(") && key.hasSuffix(")"))
    }

    let status: RosettaStatus
    private let entries: [String: Flag]?
    private let unreadable: String?

    /// Where the macOS translation runtime lives. The directory also exists
    /// without it (Rosetta for Linux VMs installs `RosettaLinux` there), so
    /// only the runtime itself counts.
    static let runtime = "/Library/Apple/usr/libexec/oah/libRosettaRuntime"

    static func defaultPreferences() -> URL {
        let home = getpwuid(geteuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(filePath: home).appending(path: "Library/Preferences/com.apple.LaunchServices/com.apple.LaunchServices.plist")
    }

    init(preferences url: URL, runtime: String = Self.runtime) {
        let installed = FileManager.default.fileExists(atPath: runtime) || Self.archRuns()

        var info = stat()
        let owner = stat(url.path, &info) == 0 ? info.st_uid : geteuid()
        let user = getpwuid(owner).map { String(cString: $0.pointee.pw_name) } ?? "uid \(owner)"

        var entries: [String: Flag]? = nil
        var unreadable: String? = nil
        let preferences: RosettaStatus.Preferences
        do {
            let data = try Data(contentsOf: url)
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
            guard let root = plist as? [String: Any] else {
                throw Problem("not a property list dictionary")
            }
            var found: [String: Flag] = [:]
            for key in root.keys.sorted() where Self.isFlagKey(key) {
                guard let apps = root[key] as? [String: Any] else {
                    throw Problem("\(key) is not a dictionary")
                }
                for (bundleID, value) in apps {
                    let flag: Flag = Self.mentionsIntel(value) ? .flagged : .inconclusive("its \(key) entry has an unrecognized format")
                    // A bundle ID listed under several keys: flagged anywhere is flagged.
                    if found[bundleID] != .flagged { found[bundleID] = flag }
                }
            }
            entries = found
            preferences = .read(flagged: entries?.values.count { $0 == .flagged } ?? 0)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            entries = [:]
            preferences = .absent
        } catch {
            unreadable = "\(url.path): \(error)"
            preferences = .unreadable(unreadable!)
        }

        self.entries = entries
        self.unreadable = unreadable
        status = RosettaStatus(installed: installed, preferencesPath: url.path, preferencesUser: user, preferences: preferences)
    }

    func flag(for bundleID: String?) -> Flag {
        if let unreadable { return .inconclusive(unreadable) }
        guard let entries, !entries.isEmpty else { return .notFlagged }
        guard let bundleID else {
            return .inconclusive("the app has no CFBundleIdentifier to look up")
        }
        return entries[bundleID] ?? .notFlagged
    }

    /// True if the entry names an Intel architecture anywhere.
    private static func mentionsIntel(_ value: Any) -> Bool {
        switch value {
        case let string as String: ["x86_64", "x86_64h", "i386"].contains(string)
        case let array as [Any]: array.contains(where: mentionsIntel)
        case let dictionary as [String: Any]: dictionary.values.contains(where: mentionsIntel)
        default: false
        }
    }

    /// Whether an x86_64 process can start. Without Rosetta this fails with
    /// "Bad CPU type"; it does not offer to install anything.
    private static func archRuns() -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/arch")
        process.arguments = ["-x86_64", "/usr/bin/true"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

import Foundation

/// Plugins found outside every app that run only under Rosetta.
public struct PluginReport: Codable, Equatable, Sendable {
    /// Absolute paths, sorted.
    public var intelOnly: [String] = []
    /// Plugins whose executable could not be read, so they may be
    /// Intel-only too. Absolute paths, sorted.
    public var uninspected: [String] = []
}

/// Phase 7's advisory defaults (decided 2026-11-09 from a read-only corpus
/// scan of one Mac's `/Applications`; see `PLAN.md` Phase 7). Advisory means
/// chosen on compatibility grounds, not a safety rule: only these could ever
/// be lifted by a future force option, and none can be today.
///
/// Considered and not adopted: skipping apps with an SMJobBless privileged
/// helper (in the corpus every helper was sealed as data, so never thinned,
/// and the skip would have cost five apps), and developer tools (Xcode and
/// CLion were already skipped for Intel-only code).
enum AdvisoryPolicy {
    /// The advisory reason to skip the app read through `tree`, or nil.
    /// Never follows a symlink; a directory it cannot list throws, and the
    /// caller skips the app.
    static func skip(_ tree: FileTree) throws(Problem) -> AppSkipReason? {
        if try tree.status(["Contents", "_MASReceipt"]) != nil {
            return .masApp
        }
        var found: [String] = []
        // System and DriverKit extensions, and kernel extensions.
        for (dir, suffixes) in [(["Contents", "Library", "SystemExtensions"], [".systemextension", ".dext"]),
                                (["Contents", "Library", "Extensions"], [".kext"])] {
            guard try tree.kind(dir) == .directory else { continue }
            for entry in try tree.entries(dir) where suffixes.contains(where: entry.name.hasSuffix) {
                found.append((dir + [entry.name]).joined(separator: "/"))
            }
        }
        return found.isEmpty ? nil : .embedsSystemExtension(found.sorted())
    }

    // MARK: - Intel-only plugins

    /// Folders of plugins that apps load into their own process: Audio Unit,
    /// VST, and VST3 hosts (digital audio workstations and editors). A host
    /// can load an Intel-only plugin only while it runs under Rosetta, which
    /// a thinned host can no longer do. QuickLook, Spotlight, and Core Audio
    /// HAL plugins are left out: system processes load those, and thinning
    /// an app does not change them. No folder maps a plugin to the apps that
    /// host it, so this warns and never skips.
    static func pluginFolders(home: String) -> [URL] {
        ["Components", "VST", "VST3"].flatMap { kind in
            ["/Library/Audio/Plug-Ins/\(kind)", home + "/Library/Audio/Plug-Ins/\(kind)"].map { URL(filePath: $0) }
        }
    }

    static let pluginSuffixes = [".component", ".vst", ".vst3"]

    /// Read-only. A missing folder holds nothing; an unreadable one is
    /// reported as uninspected.
    static func plugins(in folders: [URL]) -> PluginReport {
        var report = PluginReport()
        for folder in folders {
            var info = stat()
            guard lstat(folder.path, &info) == 0 else { continue }
            guard info.st_mode & S_IFMT == S_IFDIR, let tree = try? FileTree(folder),
                  let entries = try? tree.entries([]) else {
                report.uninspected.append(folder.path)
                continue
            }
            for entry in entries where entry.kind == .directory && pluginSuffixes.contains(where: entry.name.hasSuffix) {
                let path = folder.appending(path: entry.name).path
                do {
                    let plugin = try FileTree(folder.appending(path: entry.name))
                    let archs = try AppInfo(tree: plugin).mainExecutableArchitectures(tree: plugin)
                    if !archs.contains(.arm64), archs.contains(where: \.isIntel) {
                        report.intelOnly.append(path)
                    }
                } catch {
                    report.uninspected.append(path)
                }
            }
        }
        report.intelOnly.sort()
        report.uninspected.sort()
        return report
    }
}

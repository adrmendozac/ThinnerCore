import Foundation

/// The dry-run report, in the stable schema that `--json` prints. Both the
/// JSON and the human-readable report are rendered from this one value, so
/// their numbers cannot disagree.
///
/// Byte counts are integers: estimated logical bytes, never physical space
/// freed. Arrays are in a fixed order (apps, files, and paths sorted by path;
/// architectures in header order, removed ones sorted by name). Optional
/// fields are omitted when absent. Bump `currentSchemaVersion` on any change
/// a consumer could notice.
public struct ScanReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 5

    public struct Tool: Codable, Equatable, Sendable {
        public let name: String
        public let version: String
    }

    /// A skip reason: `code` is stable, `detail` is for people.
    public struct Reason: Codable, Equatable, Sendable {
        public let code: String
        public let detail: String
        /// True for a Phase 7 advisory default (`AppSkipReason.isAdvisory`),
        /// the only kind a future force option could lift; omitted otherwise.
        /// Schema 5.
        public var advisory: Bool? = nil
    }

    public struct Rosetta: Codable, Equatable, Sendable {
        /// Signal 1.
        public let installed: Bool
        /// Whose "Open using Rosetta" choices were read; other users' are not
        /// visible to the scan.
        public let preferencesUser: String
        public let preferencesPath: String
        /// "absent", "read", or "unreadable".
        public let preferences: String
        public let flaggedApps: Int?
        public let problem: String?
    }

    public struct File: Codable, Equatable, Sendable {
        /// Relative to the app.
        public let path: String
        public let size: UInt64
        public let architectures: [String]
        public let eligible: Bool
        /// The slices thinning would remove; present when eligible.
        public let removing: [String]?
        public let savedBytes: UInt64
        public let skip: Reason?
    }

    public struct Issue: Codable, Equatable, Sendable {
        public let path: String
        public let problem: String
    }

    public struct App: Codable, Equatable, Sendable {
        /// Relative to the scan root, or the app's name when the root is the app.
        public let path: String
        public let bundleIdentifier: String?
        /// Present when the whole app is skipped; its counts are then zero.
        public let skip: Reason?
        public let universalFiles: Int
        public let eligibleFiles: Int
        public let removableBytes: UInt64
        public let files: [File]
        /// Paths in the app that could not be read, relative to the app.
        public let issues: [Issue]
        /// Code with an Intel slice and no arm64 slice, relative to the app;
        /// omitted when there is none. Schema 4.
        public let intelOnlyCode: [String]?
    }

    public struct SkippedPath: Codable, Equatable, Sendable {
        public let path: String
        public let reason: Reason
    }

    public struct Totals: Codable, Equatable, Sendable {
        public let apps: Int
        public let skippedApps: Int
        public let universalFiles: Int
        public let eligibleFiles: Int
        public let removableBytes: UInt64
        public let issues: Int
    }

    public let pendingOperations: PendingOperations
    /// Backups kept for the scanned apps, beside the bytes thinning removed.
    public let backups: RetainedBackups
    public let schemaVersion: Int
    public let tool: Tool
    /// Always true for a scan: nothing on disk was changed.
    public let dryRun: Bool
    public let root: String
    /// False when a path could not be read; counts are then lower bounds.
    public let complete: Bool
    public let excludes: [String]
    public let missingExclusions: [String]
    public let rosetta: Rosetta
    public let totals: Totals
    public let apps: [App]
    /// Directories not searched because they are excluded or protected.
    public let skippedPaths: [SkippedPath]
    /// Paths that could not be searched for apps, relative to the root.
    public let issues: [Issue]
    /// Intel-only Audio Unit, VST, and VST3 plugins outside every app. Hosts
    /// that are thinned can no longer load them. A warning; skips nothing.
    /// Schema 5.
    public let plugins: PluginReport
    /// The allow list in force; omitted when there is none. Schema 5.
    public let allowList: AllowListStatus?

    public init(root: URL, excludes: [URL], result: ScanResult) {
        schemaVersion = Self.currentSchemaVersion
        tool = Tool(name: "thinnercore", version: ThinnerCore.version)
        dryRun = true
        self.root = root.path
        (pendingOperations, backups) = PendingOperations.snapshot(root: root, apps: result.apps.map(\.url))
        complete = result.isComplete && pendingOperations.problems.isEmpty
        self.excludes = excludes.map(\.path)
        missingExclusions = result.missingExclusions

        let status = result.rosetta
        let (preferences, flagged, problem): (String, Int?, String?) = switch status.preferences {
        case .absent: ("absent", 0, nil)
        case let .read(count): ("read", count, nil)
        case let .unreadable(problem): ("unreadable", nil, problem)
        }
        rosetta = Rosetta(installed: status.installed, preferencesUser: status.preferencesUser,
                          preferencesPath: status.preferencesPath, preferences: preferences,
                          flaggedApps: flagged, problem: problem)

        let totals = result.totals
        self.totals = Totals(apps: totals.apps, skippedApps: totals.skippedApps, universalFiles: totals.universalFiles,
                             eligibleFiles: totals.eligibleFiles, removableBytes: totals.removableBytes,
                             issues: totals.issues)

        apps = result.apps.map { app in
            App(path: app.relativePath,
                bundleIdentifier: app.bundleIdentifier,
                skip: app.skip.map { Reason(code: $0.code, detail: $0.description, advisory: $0.isAdvisory ? true : nil) },
                universalFiles: app.universalCount,
                eligibleFiles: app.eligibleCount,
                removableBytes: app.removableBytes,
                files: app.files.map(File.init),
                issues: app.issues.map(Issue.init),
                intelOnlyCode: app.intelOnlyCode.isEmpty ? nil : app.intelOnlyCode)
        }
        skippedPaths = result.skippedPaths.map {
            SkippedPath(path: $0.relativePath, reason: Reason(code: $0.reason.code, detail: $0.reason.description))
        }
        issues = result.issues.map(Issue.init)
        plugins = result.plugins
        allowList = result.allowList
    }

    /// Pretty-printed with sorted keys, so equal reports print identically.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

extension ScanReport.File {
    init(_ file: WalkedFile) {
        path = file.relativePath
        size = file.size
        architectures = file.architectures.map(\.description)
        switch file.decision {
        case let .eligible(removing, saved):
            eligible = true
            self.removing = removing.map(\.description).sorted()
            savedBytes = saved
            skip = nil
        case let .skip(reason):
            eligible = false
            removing = nil
            savedBytes = 0
            skip = ScanReport.Reason(code: reason.code, detail: reason.description)
        }
    }
}

extension ScanReport.Issue {
    init(_ issue: WalkIssue) {
        path = issue.relativePath
        problem = issue.problem
    }
}

import Foundation

/// What the scan should leave out and where to read user settings.
public struct ScanOptions: Sendable {
    /// Paths the user excluded. Each excludes itself, everything below it,
    /// and any app that contains it. Matched by file identity, so symlinks,
    /// firmlinks, and letter case do not matter.
    public var excludes: [URL]
    /// The LaunchServices preferences holding "Open using Rosetta" flags.
    /// Defaults to the effective user's.
    public var launchServicesPreferences: URL

    public init(excludes: [URL] = [], launchServicesPreferences: URL? = nil) {
        self.excludes = excludes
        self.launchServicesPreferences = launchServicesPreferences ?? RosettaFlags.defaultPreferences()
    }
}

/// One app bundle, classified.
public struct AppScan: Equatable, Sendable {
    /// Where the app sits relative to the scanned directory, or the app's own
    /// name when the scan root is the app.
    public let relativePath: String
    public let url: URL
    public let bundleIdentifier: String?
    /// Why the whole app is left alone, or nil if its eligible files count.
    public let skip: AppSkipReason?
    /// Every universal file in the app with its own decision, sorted by path.
    /// Paths are relative to the app. Empty for an app skipped before it was
    /// read (protected or excluded); otherwise kept even when the app is
    /// skipped, so a report can say what would have been eligible.
    public let files: [WalkedFile]
    /// Paths in the app that could not be read, relative to the app. An app
    /// with issues was scanned incompletely; its counts are lower bounds.
    public let issues: [WalkIssue]

    public var universalCount: Int { files.count }
    /// Files that pass every file-level rule. Zero when the app is skipped.
    public var eligibleCount: Int {
        skip == nil ? files.count { $0.decision.isEligible } : 0
    }
    /// Estimated logical bytes removable: the slices removed, adjusted for the
    /// thinned file's alignment. Not physical space freed. Zero when the app
    /// is skipped.
    public var removableBytes: UInt64 {
        skip == nil ? files.reduce(0) { $0 + $1.decision.savedBytes } : 0
    }
}

/// A directory the scan did not search, and why.
public struct SkippedPath: Equatable, Sendable {
    /// Relative to the scan root; empty for the root itself.
    public let relativePath: String
    public let reason: AppSkipReason
}

public struct ScanTotals: Equatable, Sendable {
    public var apps = 0
    public var skippedApps = 0
    public var universalFiles = 0
    public var eligibleFiles = 0
    public var removableBytes: UInt64 = 0
    /// Discovery issues plus every app's issues.
    public var issues = 0
}

public struct ScanResult: Equatable, Sendable {
    /// Sorted by path, skipped apps included.
    public var apps: [AppScan] = []
    /// Paths that could not be searched for apps, relative to the scan root.
    /// Apps below them are missing from `apps`.
    public var issues: [WalkIssue] = []
    /// Directories not searched because they are excluded or protected. Apps
    /// below them are not listed.
    public var skippedPaths: [SkippedPath] = []
    /// Exclusions naming nothing on disk. They match nothing.
    public var missingExclusions: [String] = []
    public var rosetta: RosettaStatus

    /// True when every directory that should be searched was, and every app
    /// read in full.
    public var isComplete: Bool {
        issues.isEmpty && apps.allSatisfy(\.issues.isEmpty)
    }

    public var totals: ScanTotals {
        apps.reduce(into: ScanTotals(issues: issues.count)) { totals, app in
            totals.apps += 1
            totals.skippedApps += app.skip == nil ? 0 : 1
            totals.universalFiles += app.universalCount
            totals.eligibleFiles += app.eligibleCount
            totals.removableBytes += app.removableBytes
            totals.issues += app.issues.count
        }
    }
}

/// Finds the app bundles under a directory and classifies each one. Read-only.
///
/// A scan root that is itself an `.app` is scanned as that one app. Otherwise
/// every directory below the root is searched, without following symlinks,
/// and each `.app` directory found is one app. The search does not descend
/// into an app, an excluded directory, or a protected one: helper apps and
/// everything else inside belong to the app that contains them.
///
/// Each app is then checked, and skipped whole for the first reason that
/// applies: protected location, user exclusion, unreadable metadata,
/// script-only, "Open using Rosetta", Intel-first `LSArchitecturePriority`,
/// and, if any file is eligible, failing `codesign --verify`.
public enum AppScanner {
    /// `progress` is called with each app's relative path before it is read.
    public static func scan(_ root: URL, options: ScanOptions = ScanOptions(),
                            progress: (String) -> Void = { _ in }) -> ScanResult {
        let scan = Scan(rosetta: RosettaFlags(preferences: options.launchServicesPreferences),
                        exclusions: Exclusions(options.excludes))
        var result = ScanResult(rosetta: scan.rosetta.status)
        result.missingExclusions = scan.exclusions.missing

        let tree: FileTree
        do {
            tree = try FileTree(root)
        } catch {
            var problem = error.description
            var info = stat()
            if lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                problem = "is a symbolic link"
            }
            result.issues.append(WalkIssue(relativePath: "", problem: problem))
            return result
        }
        guard let rootReal = realPath(root.path) else {
            result.issues.append(WalkIssue(relativePath: "", problem: errnoDescription()))
            return result
        }

        // The root, or a directory above it, may itself be excluded or protected.
        let rootSkip = (ancestors(of: rootReal) + [rootReal]).lazy.compactMap(scan.skipBeforeReading).first

        if isApp(root.lastPathComponent) {
            let name = root.lastPathComponent
            progress(name)
            result.apps = [rootSkip.map { .skipped(root, name, $0) } ?? scan.app(root, real: rootReal, relativePath: name)]
            return result
        }
        if let rootSkip {
            result.skippedPaths = [SkippedPath(relativePath: "", reason: rootSkip)]
            return result
        }

        var found: [(path: [String], skip: AppSkipReason?)] = []
        scan.discover(in: tree, at: [], rootReal: rootReal, apps: &found, result: &result)
        result.apps = found
            .map { app in
                let relative = app.path.joined(separator: "/")
                let url = root.appending(path: relative)
                if let skip = app.skip { return .skipped(url, relative, skip) }
                progress(relative)
                return scan.app(url, real: join(rootReal, relative), relativePath: relative)
            }
            .sorted { $0.relativePath < $1.relativePath }
        result.issues.sort { $0.relativePath < $1.relativePath }
        result.skippedPaths.sort { $0.relativePath < $1.relativePath }
        return result
    }

    static func isApp(_ name: String) -> Bool {
        name.count > 4 && name.lowercased().hasSuffix(".app")
    }

    private static func join(_ base: String, _ relative: String) -> String {
        base == "/" ? "/\(relative)" : "\(base)/\(relative)"
    }

    private struct Scan {
        let rosetta: RosettaFlags
        let exclusions: Exclusions

        /// Skips decided from the path alone, before anything is read.
        func skipBeforeReading(_ realPath: String) -> AppSkipReason? {
            if let id = FileID(path: realPath), let exclusion = exclusions.exclusion(for: id) {
                return .excluded(exclusion)
            }
            if let prefix = ProtectedLocations.protectedPrefix(of: realPath) {
                return .protectedLocation("under \(prefix)")
            }
            return nil
        }

        func discover(in tree: FileTree, at path: [String], rootReal: String,
                      apps: inout [(path: [String], skip: AppSkipReason?)], result: inout ScanResult) {
            let entries: [(name: String, kind: FileTree.Kind)]
            do {
                entries = try tree.entries(path)
            } catch {
                result.issues.append(WalkIssue(relativePath: path.joined(separator: "/"), problem: error.description))
                return
            }
            for entry in entries where entry.kind == .directory {
                // Backup trees are operation storage, never app-discovery roots.
                if PendingOperations.isStagingName(entry.name) { continue }
                let child = path + [entry.name]
                let skip = skipBeforeReading(join(rootReal, child.joined(separator: "/")))
                if isApp(entry.name) {
                    apps.append((child, skip))
                } else if let skip {
                    result.skippedPaths.append(SkippedPath(relativePath: child.joined(separator: "/"), reason: skip))
                } else {
                    discover(in: tree, at: child, rootReal: rootReal, apps: &apps, result: &result)
                }
            }
        }

        func app(_ url: URL, real: String, relativePath: String) -> AppScan {
            if let reason = ProtectedLocations.reason(forRealPath: real) {
                return .skipped(url, relativePath, .protectedLocation(reason))
            }
            if let id = FileID(path: real), let exclusion = exclusions.exclusion(below: id) {
                return .skipped(url, relativePath, .containsExclusion(exclusion))
            }

            let classified = BundleClassifier.classify(url)
            var bundleIdentifier: String?
            var skip: AppSkipReason?
            do {
                let tree = try FileTree(url)
                let info = try AppInfo(tree: tree)
                bundleIdentifier = info.bundleIdentifier
                if let reason = try info.scriptOnlyReason(tree: tree) {
                    skip = .scriptOnly(reason)
                } else if case let .inconclusive(detail) = rosetta.flag(for: info.bundleIdentifier) {
                    skip = .rosettaInconclusive(detail)
                } else if rosetta.flag(for: info.bundleIdentifier) == .flagged {
                    skip = .rosettaFlagged(user: rosetta.status.preferencesUser)
                } else if let priority = info.architecturePriority,
                          let main = classified.files.first(where: { $0.relativePath == "Contents/MacOS/\(info.executable)" }),
                          info.prioritySelection(from: main.architectures) != .arm64 {
                    // Only the ordinary arm64 slice is known to launch natively;
                    // an unmatched list is unmeasured, so it skips too.
                    skip = .intelArchitecturePriority(priority)
                }
            } catch {
                skip = .bundleMetadata(error.description)
            }
            // Slow on large apps, so only where something could be thinned.
            if skip == nil, classified.files.contains(where: \.isEligible), let problem = Codesign.verify(url) {
                skip = .signatureInvalid(problem)
            }
            return AppScan(relativePath: relativePath, url: url, bundleIdentifier: bundleIdentifier, skip: skip,
                           files: classified.files, issues: classified.issues)
        }
    }
}

extension AppScan {
    /// An app skipped before it was read.
    static func skipped(_ url: URL, _ relativePath: String, _ reason: AppSkipReason) -> AppScan {
        AppScan(relativePath: relativePath, url: url, bundleIdentifier: nil, skip: reason, files: [], issues: [])
    }
}

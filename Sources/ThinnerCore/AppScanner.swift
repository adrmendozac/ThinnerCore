import Foundation

/// What the scan should leave out and where to read user settings.
public struct ScanOptions: Sendable {
    /// Paths the user excluded. Each excludes itself, everything below it,
    /// and any app that contains it. Matched by file identity, so symlinks,
    /// firmlinks, and letter case do not matter.
    public var excludes: [URL]
    /// The LaunchServices preferences holding "Open using Rosetta" flags.
    /// Defaults to the effective user's, or under `sudo` to the invoking
    /// user's: root's own preferences never hold the user's choices.
    public var launchServicesPreferences: URL
    /// Whose preferences the default names, for the report.
    var preferencesOwner: uid_t?
    /// Why no default could be chosen; every app is then inconclusive.
    var preferencesProblem: String?
    /// The user whose home `~/` list entries and the plugin folders refer
    /// to: the effective user, or under `sudo` the invoking one. Kept apart
    /// from `preferencesOwner`, which is nil when a preferences file is
    /// named explicitly; falling back to the effective user there would mean
    /// root's home under `sudo`, and `~/` skip-list entries would exclude
    /// nothing.
    var homeOwner: uid_t?
    /// The user's skip list (see `SkipList`). Its paths act like `excludes`;
    /// its bundle identifiers skip matching apps wherever they are.
    public var skipList = SkipList()
    /// Why the skip list file could not be read. Every app is then refused:
    /// an unreadable list never means "nothing excluded".
    public var skipListProblem: String?
    /// Where to look for Intel-only audio plugins (`AdvisoryPolicy`). Nil
    /// means the standard folders, the user's own under that user's home.
    public var pluginFolders: [URL]? = nil
    /// The user's allow list (see `AllowListFile`). When it has entries,
    /// only the apps it names are thinned.
    public var allowList = SkipList()
    /// Why the allow list file could not be read. Every app is then refused.
    public var allowListProblem: String?
    /// Where the allow list was read from, for the report.
    public var allowListPath: String?

    /// Loads the allow list at `url`; a missing file is an empty list, which
    /// allows every app.
    public mutating func loadAllowList(_ url: URL) {
        allowListPath = url.path
        do {
            allowList = try SkipList.load(url, home: SkipList.home(of: homeOwner ?? geteuid()))
        } catch {
            allowListProblem = error.description
        }
    }

    /// Loads the skip list at `url` into these options; a missing file is an
    /// empty list.
    public mutating func loadSkipList(_ url: URL) {
        do {
            skipList = try SkipList.load(url, home: SkipList.home(of: homeOwner ?? geteuid()))
        } catch {
            skipListProblem = error.description
        }
    }

    public init(excludes: [URL] = [], launchServicesPreferences: URL? = nil) {
        self.init(excludes: excludes, launchServicesPreferences: launchServicesPreferences,
                  defaultUser: RosettaFlags.defaultPreferencesUser())
    }

    init(excludes: [URL] = [], launchServicesPreferences: URL?, defaultUser: Result<uid_t, Problem>) {
        self.excludes = excludes
        if case let .success(uid) = defaultUser { homeOwner = uid }
        if let launchServicesPreferences {
            self.launchServicesPreferences = launchServicesPreferences
            return
        }
        switch defaultUser {
        case let .success(uid):
            self.launchServicesPreferences = RosettaFlags.preferences(of: uid)
            preferencesOwner = uid
        case let .failure(problem):
            self.launchServicesPreferences = RosettaFlags.preferences(of: geteuid())
            preferencesProblem = problem.description
        }
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
    /// Code in the app with an Intel slice and no arm64 slice, relative to
    /// the app. Any of it but Node modules skips the app (`intelOnlyCode`).
    public var intelOnlyCode: [String] = []

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
    /// Intel-only plugins outside every app, which thinned hosts cannot load.
    /// A warning only; it skips nothing.
    public var plugins = PluginReport()
    /// The allow list in force, or nil when there is none (every app may be
    /// thinned).
    public var allowList: AllowListStatus?

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
/// script-only, "Open using Rosetta", a main executable without an arm64
/// slice, an `LSArchitecturePriority` that does not select arm64, Intel-only
/// code anywhere in the bundle,
/// and, if any file is eligible, failing `codesign --verify`.
/// One app about to be read: its relative path and its 1-based position
/// among the apps that will be read. Apps skipped before reading (excluded or
/// protected) are not counted.
public struct ScanProgress: Codable, Equatable, Sendable {
    public let app: String
    public let index: Int
    public let total: Int
}

public enum AppScanner {
    /// `progress` is called with each app's relative path before it is read.
    public static func scan(_ root: URL, options: ScanOptions = ScanOptions(),
                            progress: (ScanProgress) -> Void = { _ in }) -> ScanResult {
        let scan = Scan(rosetta: RosettaFlags(preferences: options.launchServicesPreferences,
                                              owner: options.preferencesOwner, problem: options.preferencesProblem),
                        exclusions: Exclusions(options.excludes + options.skipList.paths.map { URL(filePath: $0) }),
                        skipList: options.skipList, skipListProblem: options.skipListProblem,
                        allowList: options.allowList, allowListProblem: options.allowListProblem,
                        allowed: Exclusions(options.allowList.paths.map { URL(filePath: $0) }))
        var result = ScanResult(rosetta: scan.rosetta.status)
        result.missingExclusions = scan.exclusions.missing
        if options.allowListProblem != nil || !options.allowList.isEmpty {
            result.allowList = AllowListStatus(path: options.allowListPath, entries: options.allowList.paths.count
                + options.allowList.bundleIdentifiers.count, problem: options.allowListProblem,
                missingPaths: scan.allowed.missing)
        }
        result.plugins = AdvisoryPolicy.plugins(in: options.pluginFolders
            ?? AdvisoryPolicy.pluginFolders(home: SkipList.home(of: options.homeOwner ?? geteuid())))

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
            progress(ScanProgress(app: name, index: 1, total: 1))
            result.apps = [rootSkip.map { .skipped(root, name, $0) } ?? scan.app(root, real: rootReal, relativePath: name)]
            return result
        }
        if let rootSkip {
            result.skippedPaths = [SkippedPath(relativePath: "", reason: rootSkip)]
            return result
        }

        var found: [(path: [String], skip: AppSkipReason?)] = []
        scan.discover(in: tree, at: [], rootReal: rootReal, apps: &found, result: &result)
        let total = found.count(where: { $0.skip == nil })
        var index = 0
        result.apps = found
            .map { app in
                let relative = app.path.joined(separator: "/")
                let url = root.appending(path: relative)
                if let skip = app.skip { return .skipped(url, relative, skip) }
                index += 1
                progress(ScanProgress(app: relative, index: index, total: total))
                return scan.app(url, real: join(rootReal, relative), relativePath: relative)
            }
            .sorted { $0.relativePath < $1.relativePath }
        result.issues.sort { $0.relativePath < $1.relativePath }
        result.skippedPaths.sort { $0.relativePath < $1.relativePath }
        return result
    }

    /// App bundles at or below `root`, found without reading them, so pending
    /// journals beside nested apps can be inspected. Protected locations are
    /// not searched; user exclusions are ignored, since reporting a journal
    /// changes nothing. Walk problems are returned so a partial walk is not
    /// mistaken for "nothing pending".
    static func appLocations(_ root: URL) -> (apps: [URL], problems: [String]) {
        if isApp(root.lastPathComponent) { return ([root], []) }
        let tree: FileTree
        do { tree = try FileTree(root) } catch { return ([], ["Cannot search \(root.path) for apps: \(error)"]) }
        guard let rootReal = realPath(root.path) else {
            return ([], ["Cannot search \(root.path) for apps: \(errnoDescription())"])
        }
        var found: [(path: [String], skip: AppSkipReason?)] = []
        var issues: [WalkIssue] = []
        var skippedPaths: [SkippedPath] = []
        discover(in: tree, at: [], rootReal: rootReal,
                 skip: { ProtectedLocations.protectedPrefix(of: $0).map { .protectedLocation("under \($0)") } },
                 apps: &found, issues: &issues, skippedPaths: &skippedPaths)
        return (found.map { root.appending(path: $0.path.joined(separator: "/")) },
                issues.map { "Cannot search \(join(root.path, $0.relativePath)) for apps: \($0.problem)" })
    }

    private static func discover(in tree: FileTree, at path: [String], rootReal: String,
                                 skip skipBeforeReading: (String) -> AppSkipReason?,
                                 apps: inout [(path: [String], skip: AppSkipReason?)],
                                 issues: inout [WalkIssue], skippedPaths: inout [SkippedPath]) {
        let entries: [(name: String, kind: FileTree.Kind)]
        do {
            entries = try tree.entries(path)
        } catch {
            issues.append(WalkIssue(relativePath: path.joined(separator: "/"), problem: error.description))
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
                skippedPaths.append(SkippedPath(relativePath: child.joined(separator: "/"), reason: skip))
            } else {
                discover(in: tree, at: child, rootReal: rootReal, skip: skipBeforeReading,
                         apps: &apps, issues: &issues, skippedPaths: &skippedPaths)
            }
        }
    }

    static func isApp(_ name: String) -> Bool {
        name.count > 4 && name.lowercased().hasSuffix(".app")
    }

    private static func join(_ base: String, _ relative: String) -> String {
        base == "/" ? "/\(relative)" : "\(base)/\(relative)"
    }

    /// A Node native module (`.node`) loads only into a Node runtime of its
    /// own architecture. Universal Electron apps ship Intel-only ones beside
    /// the arm64 ones; once the app's executables are thinned, no Intel
    /// runtime is left to load them, so they do not skip the app (decided
    /// 2026-10-05). An Intel-only executable that could host one still does.
    static func isNodeModule(_ path: String) -> Bool {
        path.hasSuffix(".node")
    }

    private struct Scan {
        let rosetta: RosettaFlags
        let exclusions: Exclusions
        let skipList: SkipList
        let skipListProblem: String?
        let allowList: SkipList
        let allowListProblem: String?
        /// The allow list's paths, matched by identity like exclusions.
        let allowed: Exclusions

        /// Whether the allow list names the app at `real`: by its bundle
        /// identifier, or by its path or a folder above it.
        func isAllowed(_ real: String, bundleIdentifier: String?) -> Bool {
            if let bundleIdentifier, allowList.bundleIdentifiers.contains(bundleIdentifier) { return true }
            return (ancestors(of: real) + [real]).contains { path in
                FileID(path: path).flatMap(allowed.exclusion(for:)) != nil
            }
        }

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
            AppScanner.discover(in: tree, at: path, rootReal: rootReal, skip: skipBeforeReading,
                                apps: &apps, issues: &result.issues, skippedPaths: &result.skippedPaths)
        }

        func app(_ url: URL, real: String, relativePath: String) -> AppScan {
            if let reason = ProtectedLocations.reason(forRealPath: real) {
                return .skipped(url, relativePath, .protectedLocation(reason))
            }
            if let id = FileID(path: real), let exclusion = exclusions.exclusion(below: id) {
                return .skipped(url, relativePath, .containsExclusion(exclusion))
            }
            if let skipListProblem {
                return .skipped(url, relativePath, .skipListUnreadable(skipListProblem))
            }
            if let allowListProblem {
                return .skipped(url, relativePath, .allowListUnreadable(allowListProblem))
            }

            let classified = BundleClassifier.classify(url)
            var bundleIdentifier: String?
            var skip: AppSkipReason?
            do {
                let tree = try FileTree(url)
                let info = try AppInfo(tree: tree)
                bundleIdentifier = info.bundleIdentifier
                if let id = info.bundleIdentifier, skipList.bundleIdentifiers.contains(id) {
                    skip = .skipListed(id)
                } else if !allowList.isEmpty, !isAllowed(real, bundleIdentifier: info.bundleIdentifier) {
                    skip = .notOnAllowList
                } else if let reason = try info.scriptOnlyReason(tree: tree) {
                    skip = .scriptOnly(reason)
                } else if case let .inconclusive(detail) = rosetta.flag(for: info.bundleIdentifier) {
                    skip = .rosettaInconclusive(detail)
                } else if rosetta.flag(for: info.bundleIdentifier) == .flagged {
                    skip = .rosettaFlagged(user: rosetta.status.preferencesUser)
                } else {
                    // Read from the executable itself: the walker lists only
                    // universal files, so a thin Intel executable is not there.
                    let main = try info.mainExecutableArchitectures(tree: tree)
                    if !main.contains(.arm64) {
                        skip = .noNativeMainExecutable(main.map(\.description))
                    } else if let priority = info.architecturePriority, info.prioritySelection(from: main) != .arm64 {
                        // Only the ordinary arm64 slice is known to launch natively;
                        // an unmatched list is unmeasured, so it skips too.
                        skip = .intelArchitecturePriority(priority)
                    } else if case let blocking = classified.intelOnlyCode.filter({ !AppScanner.isNodeModule($0) }), !blocking.isEmpty {
                        skip = .intelOnlyCode(blocking)
                    } else {
                        // Advisory defaults last, so a hard reason is always the
                        // one reported; a future override then lifts only these.
                        skip = try AdvisoryPolicy.skip(tree)
                    }
                }
            } catch {
                skip = .bundleMetadata(error.description)
            }
            // Slow on large apps, so only where something could be thinned.
            // An advisory skip leaves it out; apply rechecks it in full.
            if skip == nil, classified.files.contains(where: \.isEligible), let problem = Codesign.verify(url) {
                skip = .signatureInvalid(problem)
            }
            return AppScan(relativePath: relativePath, url: url, bundleIdentifier: bundleIdentifier, skip: skip,
                           files: classified.files, issues: classified.issues, intelOnlyCode: classified.intelOnlyCode)
        }
    }
}

extension AppScan {
    /// An app skipped before it was read.
    static func skipped(_ url: URL, _ relativePath: String, _ reason: AppSkipReason) -> AppScan {
        AppScan(relativePath: relativePath, url: url, bundleIdentifier: nil, skip: reason, files: [], issues: [])
    }
}

/// The allow list a scan applied.
public struct AllowListStatus: Codable, Equatable, Sendable {
    public let path: String?
    public let entries: Int
    /// Why it could not be read; every app is then refused.
    public let problem: String?
    /// Path entries that name nothing on disk. They allow nothing.
    public let missingPaths: [String]
}

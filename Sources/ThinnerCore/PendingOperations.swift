import Foundation

/// An unlocked, read-only snapshot of journals beside the scan root and
/// discovered apps. It is not a global restore index and may become stale.
public struct PendingOperations: Codable, Equatable, Sendable {
    public struct Operation: Codable, Equatable, Sendable {
        public let journalPath: String
        public let bundlePath: String
        public let state: String
    }
    public var operations: [Operation] = []
    public var problems: [String] = []
    public var searchedDirectories: [String] = []

    static func isStagingName(_ name: String) -> Bool {
        RestoreOperation.isStagingName(name)
    }

    /// Only journals for the requested app, or for apps under the requested
    /// directory, are reported: an app's journals sit in its parent
    /// directory, beside its siblings' journals. A journal that cannot be
    /// read cannot be attributed, so it stays a problem, as it blocks restore.
    public static func read(root: URL, apps: [URL]) -> PendingOperations {
        snapshot(root: root, apps: apps).pending
    }

    /// One unlocked pass over the journals: unfinished operations, and the
    /// backups every operation for these apps keeps.
    static func snapshot(root: URL, apps: [URL]) -> (pending: PendingOperations, backups: RetainedBackups) {
        var snapshot = PendingOperations()
        var backups = RetainedBackups()
        let rootIsApp = AppScanner.isApp(root.lastPathComponent)
        let rootPaths = Set([root.standardizedFileURL.path, realPath(root.path)].compactMap { $0 })
        func belongs(_ bundlePath: String) -> Bool {
            let candidates = Set([bundlePath, realPath(bundlePath)].compactMap { $0 })
            return candidates.contains { path in
                rootPaths.contains { rootIsApp ? path == $0 : path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
            }
        }
        let directories = Set(([AppScanner.isApp(root.lastPathComponent) ? root.deletingLastPathComponent() : root]
            + apps.map { $0.deletingLastPathComponent() }).map { $0.standardizedFileURL.path })
        for directory in directories.sorted() {
            snapshot.searchedDirectories.append(directory)
            do {
                let tree = try FileTree(URL(filePath: directory))
                for entry in try tree.entries([]) where isStagingName(entry.name) {
                    guard entry.kind == .directory else {
                        snapshot.problems.append("Cannot inspect staging path \(directory)/\(entry.name): not a directory")
                        continue
                    }
                    let journalPath = URL(filePath: directory).appending(path: entry.name).appending(path: Journal.fileName)
                    // Inspect with the no-follow reader, never trust a journal symlink.
                    do {
                        let data = try tree.read([entry.name, Journal.fileName], limit: 16 * 1024 * 1024)
                        let journal = try JSONDecoder().decode(Journal.self, from: data)
                        guard journal.schemaVersion == Journal.schemaVersion else {
                            snapshot.problems.append("Unsupported journal schema at \(journalPath.path)")
                            continue
                        }
                        guard belongs(journal.bundlePath) else { continue }
                        if journal.state == .inProgress || journal.state == .recoveryFailed {
                            snapshot.operations.append(.init(journalPath: journalPath.path, bundlePath: journal.bundlePath, state: journal.state.rawValue))
                        }
                        backups.add(journal, staging: journalPath.deletingLastPathComponent().path,
                                    restoreState: RetainedBackups.restoreState(tree, entry.name))
                    } catch {
                        snapshot.problems.append("Cannot inspect journal at \(journalPath.path): \(error)")
                    }
                }
            } catch {
                snapshot.problems.append("Cannot inspect journals in \(directory): \(error)")
            }
        }
        snapshot.operations.sort { $0.journalPath < $1.journalPath }
        snapshot.problems.sort()
        backups.sets.sort { $0.stagingPath < $1.stagingPath }
        return (snapshot, backups)
    }
}

/// Backups kept beside the scanned apps, from the same unlocked snapshot as
/// `PendingOperations`. Backups keep the original blocks allocated, so until
/// an app's backups are released, thinning adds the thinned files' size to
/// disk usage instead of saving the removed bytes. Both are logical sizes.
public struct RetainedBackups: Codable, Equatable, Sendable {
    public struct BackupSet: Codable, Equatable, Sendable {
        public let bundlePath: String
        public let stagingPath: String
        /// The operation's journal state.
        public let state: String
        /// The state of the last restore from this set, when one ran;
        /// "unreadable" when its record cannot be read.
        public let restoreState: String?
        /// The logical size of the backups kept.
        public let retainedBytes: UInt64
        /// Logical bytes the operation removed from the app and that are
        /// still removed: zero once rolled back or restored. After a restore
        /// attempt, only files matching their thinned hash count; unreadable
        /// or externally changed files contribute zero to this snapshot.
        public let removedBytes: UInt64
    }

    public var sets: [BackupSet] = []
    public var retainedBytes: UInt64 { sets.map(\.retainedBytes).saturatingSum() }
    public var removedBytes: UInt64 { sets.map(\.removedBytes).saturatingSum() }

    enum CodingKeys: String, CodingKey { case sets, retainedBytes, removedBytes }

    public init() {}

    public init(from decoder: any Decoder) throws {
        sets = try decoder.container(keyedBy: CodingKeys.self).decode([BackupSet].self, forKey: .sets)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sets, forKey: .sets)
        try container.encode(retainedBytes, forKey: .retainedBytes)
        try container.encode(removedBytes, forKey: .removedBytes)
    }

    mutating func add(_ journal: Journal, staging: String, restoreState: String?) {
        let stillRemoved = journal.state == .committed && restoreState != "restored"
        let appTree = stillRemoved && restoreState != nil ? try? FileTree(URL(filePath: journal.bundlePath)) : nil
        sets.append(BackupSet(
            bundlePath: journal.bundlePath, stagingPath: staging, state: journal.state.rawValue,
            restoreState: restoreState,
            retainedBytes: journal.entries.map(\.originalSize).saturatingSum(),
            removedBytes: stillRemoved
                ? journal.entries.filter { entry in
                    guard entry.state == .committed else { return false }
                    guard restoreState != nil else { return true }
                    // A restore can stop after a swap but before recording it.
                    // Once a restore was attempted, count only files that
                    // still match the recorded thinned contents. This also
                    // handles unreadable records and failed verification.
                    guard let expected = entry.thinnedHash else { return false }
                    return (try? appTree?.hash(entry.relativePath.components(separatedBy: "/"))) == expected
                }
                    .map { $0.originalSize - min($0.thinnedSize ?? $0.originalSize, $0.originalSize) }.saturatingSum()
                : 0))
    }

    /// Read with the no-follow reader, like the journal beside it.
    static func restoreState(_ tree: FileTree, _ staging: String) -> String? {
        let name = RestoreOperation.RestoreRecord.fileName
        let kind: FileTree.Kind?
        do { kind = try tree.kind([staging, name]) } catch { return "unreadable" }
        guard let kind else { return nil }
        guard kind == .regular,
              let data = try? tree.read([staging, name], limit: 16 << 20),
              let record = try? JSONDecoder().decode(RestoreOperation.RestoreRecord.self, from: data) else {
            return "unreadable"
        }
        return record.state.rawValue
    }
}

extension Sequence<UInt64> {
    /// The sum, capped at `UInt64.max`. Sizes recorded in a journal are
    /// untrusted input: anyone who can create a directory beside an app can
    /// write one, and `+` would trap on sizes chosen to overflow.
    func saturatingSum() -> UInt64 {
        reduce(0) { total, next in
            let (sum, overflow) = total.addingReportingOverflow(next)
            return overflow ? .max : sum
        }
    }
}

import Darwin
import Foundation

/// What `RestoreOperation.restore` did.
public struct RestoreResult: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Every thinned file is back to its original, and the app verifies.
        case restored
        /// Nothing needed restoring; nothing changed.
        case nothingToRestore(String)
        /// A check failed before anything changed.
        case refused(String)
        /// Stopped part-way: some files are original, the rest still thinned.
        /// Every file is individually valid. Run restore again to finish.
        case pending(String)
        /// A restored file or the app failed verification. Everything is
        /// kept: backups, temporary files, and the restore record.
        case recoveryFailed(String)

        /// The process exit status, per the table in `PLAN.md` Phase 5.
        public var exitCode: Int32 {
            switch self {
            case .restored, .nothingToRestore: 0
            case .refused: 1
            case .pending: 3
            case .recoveryFailed: 4
            }
        }
    }

    public var outcome: Outcome
    /// Paths relative to the app, put back by this run.
    public var restored: [String] = []
    /// Paths relative to the app that already held their original.
    public var alreadyOriginal: [String] = []
    /// Limits of the checks and other facts the user should see.
    public var notes: [String] = []
    /// Staging directories whose backups were used. Restore never deletes them.
    public var backupLocations: [String] = []

    init(_ outcome: Outcome) {
        self.outcome = outcome
    }
}

/// M3: put an app's original universal files back from the backups the write
/// path made.
///
/// Restore is a mutation, so it follows the audited write path's rules:
/// everything is checked before the first change, a durable record is written
/// before any swap, each file is replaced only by `rename(2)` from a staging
/// directory on the same volume, every restored file must hash equal to its
/// original before `codesign` runs, and nothing is ever deleted. Backups are
/// cloned back into place, never moved, so they survive the restore.
///
/// Refused, with nothing changed, when: the app is in a protected location;
/// another operation holds the app's `AppLock` or a backup set; a backup record is unreadable, of
/// unknown schema, or lacks the app identity; no backup set was recorded for
/// the app's current identity (sets from other versions are kept, reported,
/// and never restored); any recorded file matches neither its
/// original nor its thinned hash; a backup is damaged; or any process uses a
/// file from the bundle.
public enum RestoreOperation {
    /// Restore changes the app, so library clients reach it only through the
    /// same release gate as `ThinOperation.apply` and `recover`. There is
    /// deliberately no runtime override.
    public static func restore(_ app: URL) -> RestoreResult {
        RestoreResult(.refused(MutationCommands.releaseBlock))
    }

    struct Environment {
        var usage: (URL) throws(Problem) -> BundleUsage.Result = BundleUsage.scan
        var verify: (URL) -> String? = Codesign.verify
        // Internal fault-injection seams; never exposed by the CLI/library API.
        var boundary: (String, String) -> Void = { _, _ in }
        var flushDirectory: (String) -> String? = syncDirectory
    }

    /// The restore. Internal so tests can run it; library clients reach only
    /// the gated `restore`.
    static func restoreUnreleased(_ app: URL, environment: Environment = Environment()) -> RestoreResult {
        do {
            let real = try resolve(app)
            let lock = try AppLock(real)
            defer { withExtendedLifetime(lock) {} }
            return try revert(real, operation: nil, environment)
        } catch {
            return RestoreResult(.refused(error.description))
        }
    }

    /// The app's real path, refused in a protected location.
    static func resolve(_ app: URL) throws(Problem) -> String {
        guard let real = realPath(app.path) else {
            throw Problem("cannot find \(app.path): \(errnoDescription())")
        }
        if let why = ProtectedLocations.reason(forRealPath: real) {
            throw Problem("the app is in a protected location (\(why))")
        }
        return real
    }

    // MARK: - Plan

    struct BackupSet {
        let staging: URL
        let stagingReal: String
        let journal: Journal
        let identity: AppIdentity?
    }

    struct PlannedFile {
        let set: Int
        let relativePath: String
        let target: String
        let backup: String
        let originalHash: String
        let thinnedHash: String
        let identity: FileIdentity
        var temp: String?
    }

    /// Puts back the originals from every backup set made for the app at
    /// `real`, or, given `operation`, only from that operation's set: the
    /// writer's rollback and recovery undo one operation and must not be
    /// blocked by older sets. The caller holds the app's `AppLock`.
    static func revert(_ real: String, operation: String?, _ env: Environment) throws(Problem) -> RestoreResult {
        let bundle = URL(filePath: real)

        let found = try findBackupSets(for: real).filter { operation == nil || $0.journal.operationID == operation }
        guard !found.isEmpty else {
            return RestoreResult(.nothingToRestore("no backups made by this tool were found next to the app"))
        }

        // A record without the app identity might belong to this version, so
        // it blocks everything rather than being set aside.
        for set in found where set.identity == nil {
            throw Problem("the backup record in \(set.staging.path) does not say which version of the app it belongs to, so its backups cannot be trusted for this app")
        }
        // Sets made for another version stay untouched: an update undoes
        // thinning, and re-thinning the new version adds a set beside the old
        // one, which must not block restoring the new version. Rollback and
        // recovery name one operation, which must match.
        let current = try AppIdentity.of(bundle)
        let sets = found.filter { $0.identity == current }
        let otherVersions = found.filter { $0.identity != current }
        guard !sets.isEmpty, operation == nil || otherVersions.isEmpty else {
            let recorded = otherVersions.compactMap(\.identity).map(\.description).joined(separator: "; ")
            throw Problem("the app changed since it was thinned, most likely by an update (thinned: \(recorded); now: \(current)). Backups from another version are never restored into it")
        }

        // Held until this function returns.
        var locks: [StagingLock] = []
        for set in sets { locks.append(try StagingLock(set.staging)) }
        defer { withExtendedLifetime(locks) {} }

        var result = RestoreResult(.restored)
        result.backupLocations = sets.map(\.staging.path)
        result.notes += otherVersions.map {
            "kept backups from another version of the app (\($0.identity.map(\.description) ?? "")) in \($0.staging.path); they are never restored into this version"
        }
        let tree = try FileTree(bundle)
        var plan: [PlannedFile] = []
        var changed: [String] = []
        // Every set that claims each thinned file. Thinning, restoring, and
        // thinning again without an update leaves two sets for one version.
        var claims: [String: [(set: Int, entry: Journal.Entry, file: PlannedFile)]] = [:]
        var claimOrder: [String] = []

        for (index, set) in sets.enumerated() {
            for entry in set.journal.entries {
                guard let parts = safeComponents(entry.relativePath) else {
                    throw Problem("the backup record names an unsafe path: \(entry.relativePath)")
                }
                let target = real + "/" + entry.relativePath
                guard try tree.kind(parts) == .regular, let identity = FileIdentity.of(target) else {
                    changed.append(entry.relativePath)
                    continue
                }
                let hash = try SHA256.hash(file: target)
                if hash == entry.originalHash {
                    result.alreadyOriginal.append(entry.relativePath)
                    continue
                }
                guard let thinned = entry.thinnedHash, hash == thinned else {
                    changed.append(entry.relativePath)
                    continue
                }
                if claims[entry.relativePath] == nil { claimOrder.append(entry.relativePath) }
                claims[entry.relativePath, default: []].append((index, entry, PlannedFile(
                    set: index, relativePath: entry.relativePath, target: target, backup: entry.backupPath,
                    originalHash: entry.originalHash, thinnedHash: thinned, identity: identity)))
            }
        }

        for path in claimOrder {
            let candidates = claims[path]!
            // Sets that agree on both hashes hold the same original for the
            // same thinned file, so any valid one restores it. Sets that
            // disagree cannot be told apart, so nothing is restored.
            guard Set(candidates.map { "\($0.entry.originalHash)|\($0.file.thinnedHash)" }).count == 1 else {
                throw Problem("backup sets disagree about the original of \(path); restore cannot tell which is right")
            }
            // Newest first; ISO 8601 timestamps sort chronologically.
            let ordered = candidates.sorted { sets[$0.set].journal.startedAt > sets[$1.set].journal.startedAt }
            var firstProblem: Problem?
            var chosen: PlannedFile?
            for candidate in ordered {
                do {
                    try checkBackup(candidate.entry, in: sets[candidate.set])
                    chosen = candidate.file
                    break
                } catch {
                    if firstProblem == nil { firstProblem = error }
                }
            }
            guard let chosen else { throw firstProblem! }
            if candidates.count > 1 {
                result.notes.append("\(candidates.count) backup sets hold the same original of \(path); restored it from \(sets[chosen.set].staging.path)")
            }
            plan.append(chosen)
        }

        guard changed.isEmpty else {
            throw Problem("these files match neither their original nor their thinned version, so the app changed since it was thinned: \(changed.sorted().joined(separator: ", "))")
        }
        guard !plan.isEmpty else {
            // A previous process may have exited after the final rename but
            // before flushing the directory or verifying the restored app.
            for directory in Set(result.alreadyOriginal.map { (real + "/" + $0 as NSString).deletingLastPathComponent }) {
                if let problem = env.flushDirectory(directory) {
                    result.outcome = .pending("cannot flush restored directory: \(problem)")
                    return result
                }
            }
            if let problem = env.verify(bundle) {
                result.outcome = .recoveryFailed("original files are present, but restored app verification failed: \(problem)")
                return result
            }
            result.notes += closeUnfinishedRecords(sets)
            result.outcome = .nothingToRestore("every thinned file already holds its original")
            return result
        }

        try requireUnused(bundle, env, &result)

        // Record before any change.
        let runID = UUID().uuidString
        var records = sets.map { RestoreRecord(operationID: $0.journal.operationID, runID: runID) }
        for file in plan { records[file.set].files.append(.init(relativePath: file.relativePath, state: .planned)) }
        try persistRecords(records, sets)
        env.boundary("restore-journal", "")

        // Prepare every file before swapping any.
        do {
            for i in plan.indices {
                plan[i].temp = try prepare(plan[i], staging: sets[plan[i].set].staging, runID: runID)
                env.boundary("restore-prepared", plan[i].relativePath)
            }
        } catch {
            removeTemps(plan)
            try finish(&records, sets, .refused, error.description)
            throw error
        }

        for i in plan.indices {
            let file = plan[i]
            env.boundary("restore-before-swap", file.relativePath)
            var stop: String?
            if FileIdentity.of(file.target) != file.identity || (try? SHA256.hash(file: file.target)) != file.thinnedHash {
                stop = "\(file.relativePath) changed during the restore"
            } else {
                stop = ThinOperation.idleRefusal(bundle, env)
            }
            if stop == nil, FileIdentity.of(file.target) != file.identity || (try? SHA256.hash(file: file.target)) != file.thinnedHash {
                stop = "\(file.relativePath) changed immediately before restore"
            }
            if stop == nil, rename(file.temp!, file.target) != 0 {
                stop = "cannot move the original of \(file.relativePath) into place: \(errnoDescription())"
            }
            if let stop {
                removeTemps(Array(plan[i...]))
                if i == 0 {
                    try finish(&records, sets, .refused, stop)
                    throw Problem(stop)
                }
                try finish(&records, sets, .pending, stop)
                result.outcome = .pending("\(stop). Restored \(i) of \(plan.count) files; every file is individually valid. Run restore again to finish")
                return result
            }
            env.boundary("restore-swapped", file.relativePath)
            if let problem = env.flushDirectory((file.target as NSString).deletingLastPathComponent) {
                let reason = "cannot flush restored directory: \(problem); recovery is pending"
                try finish(&records, sets, .pending, reason)
                result.outcome = .pending(reason)
                return result
            }
            env.boundary("restore-directory-flushed", file.relativePath)
            guard (try? SHA256.hash(file: file.target)) == file.originalHash else {
                let reason = "\(file.relativePath) does not match its original after being restored"
                try finish(&records, sets, .recoveryFailed, reason)
                result.outcome = .recoveryFailed(reason + ". Every backup and temporary file is kept")
                return result
            }
            result.restored.append(file.relativePath)
            mark(&records, file, .restored)
            try persistRecords(records, sets)
            env.boundary("restore-recorded", file.relativePath)
        }

        if let problem = env.verify(bundle) {
            let reason = "every restored file matches its original, but the app does not verify: \(problem)"
            try finish(&records, sets, .recoveryFailed, reason)
            result.outcome = .recoveryFailed(reason + ". Every backup is kept")
            return result
        }
        env.boundary("restore-verified", "")
        // The app is restored and verified: failing to record that must not
        // be reported as a failed restore. A record left in progress is
        // finished by closeUnfinishedRecords now, or by the next run.
        do {
            try finish(&records, sets, .restored, nil)
        } catch {
            result.notes.append("every file is restored and the app verifies, but this run's restore record could not be updated: \(error.description)")
        }
        // Sets with nothing left to swap got no new record this run.
        result.notes += closeUnfinishedRecords(sets)
        env.boundary("restore-committed", "")
        return result
    }

    // MARK: - Checks

    /// Every backup set made for the app at `real`: `.thinner-*` staging
    /// directories next to it whose journal names it. A record that cannot be
    /// read might belong to this app, so it refuses the restore.
    static func findBackupSets(for real: String) throws(Problem) -> [BackupSet] {
        let parent = (real as NSString).deletingLastPathComponent
        let tree = try FileTree(URL(filePath: parent))
        var sets: [BackupSet] = []
        for entry in try tree.entries([]).sorted(by: { $0.name < $1.name }) where isStagingName(entry.name) {
            let staging = URL(filePath: parent).appending(path: entry.name)
            let journalPath = staging.appending(path: Journal.fileName).path
            guard entry.kind == .directory else {
                throw Problem("\(staging.path) is not a directory, so its backups cannot be trusted")
            }
            guard let kind = try tree.kind([entry.name, Journal.fileName]) else { continue }
            guard kind == .regular else {
                throw Problem("the backup record \(journalPath) is not a regular file")
            }
            // The no-follow reader: never trust a record reached through a symlink.
            let data = try tree.read([entry.name, Journal.fileName], limit: 16 << 20)
            let journal: Journal
            do {
                journal = try JSONDecoder().decode(Journal.self, from: data)
            } catch {
                throw Problem("cannot read the backup record \(journalPath); it may belong to this app: \(error.localizedDescription)")
            }
            guard realPath(journal.bundlePath) == real || journal.bundlePath == real else { continue }
            guard journal.schemaVersion == Journal.schemaVersion else {
                throw Problem("the backup record \(journalPath) has schema version \(journal.schemaVersion), which this version cannot read")
            }
            guard let stagingReal = realPath(staging.path) else { continue }
            sets.append(BackupSet(staging: staging, stagingReal: stagingReal, journal: journal, identity: journal.appIdentity))
        }
        return sets
    }

    /// Staging directories are named `.thinner-<operation UUID>`.
    static func isStagingName(_ name: String) -> Bool {
        name.hasPrefix(".thinner-") && UUID(uuidString: String(name.dropFirst(".thinner-".count))) != nil
    }

    /// The backup must sit inside its staging directory, be a regular file of
    /// the original's size, and hash equal to the original.
    static func checkBackup(_ entry: Journal.Entry, in set: BackupSet) throws(Problem) {
        let damaged = "the backup of \(entry.relativePath) is damaged or missing"
        guard let real = realPath(entry.backupPath), real.hasPrefix(set.stagingReal + "/") else {
            throw Problem("\(damaged): it is not inside \(set.staging.path)")
        }
        var info = stat()
        guard lstat(entry.backupPath, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw Problem("\(damaged): not a regular file")
        }
        guard UInt64(info.st_size) == entry.originalSize else {
            throw Problem("\(damaged): its size differs from the original")
        }
        guard try SHA256.hash(file: entry.backupPath) == entry.originalHash else {
            throw Problem("\(damaged): its contents differ from the original")
        }
    }

    private static func requireUnused(_ bundle: URL, _ env: Environment, _ result: inout RestoreResult) throws(Problem) {
        if let reason = ThinOperation.idleRefusal(bundle, env) { throw Problem(reason) }
    }

    /// Path components of a recorded relative path, or nil if it could escape
    /// the bundle.
    static func safeComponents(_ path: String) -> [String]? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return parts
    }

    // MARK: - Mutation

    /// Clones the backup into a fresh temporary file in staging, checks its
    /// hash, gives it the backup's metadata, and flushes it to disk.
    private static func prepare(_ file: PlannedFile, staging: URL, runID: String) throws(Problem) -> String {
        let temp = staging.appending(path: "restore-temps/\(runID)/\(file.relativePath)")
        do {
            try FileManager.default.createDirectory(at: temp.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw Problem("cannot create a temporary directory in \(staging.path): \(error.localizedDescription)")
        }
        let cloneNoFollow: UInt32 = 0x0001 // CLONE_NOFOLLOW
        guard clonefile(file.backup, temp.path, cloneNoFollow) == 0 else {
            throw Problem("cannot clone the backup of \(file.relativePath): \(errnoDescription())")
        }
        guard try SHA256.hash(file: temp.path) == file.originalHash else {
            throw Problem("the clone of the backup of \(file.relativePath) does not match the original")
        }
        let source = open(file.backup, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw Problem("cannot open the backup of \(file.relativePath): \(errnoDescription())") }
        defer { close(source) }
        let dest = open(temp.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard dest >= 0 else { throw Problem("cannot open the restored copy of \(file.relativePath): \(errnoDescription())") }
        defer { close(dest) }
        if let problem = try MetadataCopier.copy(from: file.backup, to: temp.path, sourceFD: source, destFD: dest) {
            throw Problem("cannot give the restored \(file.relativePath) its original metadata: \(problem)")
        }
        guard fcntl(dest, F_FULLFSYNC) == 0 else {
            throw Problem("cannot flush the restored \(file.relativePath) to disk: \(errnoDescription())")
        }
        return temp.path
    }

    /// Removes temporary clones this run made and did not move into the app.
    /// They are copies of backups, never the backups themselves.
    private static func removeTemps(_ files: [PlannedFile]) {
        for case let temp? in files.map(\.temp) { unlink(temp) }
    }

    // MARK: - Restore record

    /// The durable record of one restore run over one backup set, written to
    /// `restore.json` in its staging directory before any swap and after each.
    /// The write path's journal is left untouched: it stays the record of what
    /// thinning did.
    struct RestoreRecord: Codable {
        static let schemaVersion = 1
        static let fileName = "restore.json"

        enum State: String, Codable {
            case inProgress, restored, pending, refused, recoveryFailed
        }

        struct File: Codable {
            enum State: String, Codable { case planned, restored }
            let relativePath: String
            var state: State
        }

        var schemaVersion = RestoreRecord.schemaVersion
        let operationID: String
        let runID: String
        var startedAt = ISO8601DateFormatter().string(from: Date())
        var finishedAt: String?
        var state = State.inProgress
        var reason: String?
        var files: [File] = []

        init(operationID: String, runID: String) {
            self.operationID = operationID
            self.runID = runID
        }
    }

    private static func mark(_ records: inout [RestoreRecord], _ file: PlannedFile, _ state: RestoreRecord.File.State) {
        if let i = records[file.set].files.firstIndex(where: { $0.relativePath == file.relativePath }) {
            records[file.set].files[i].state = state
        }
    }

    private static func finish(_ records: inout [RestoreRecord], _ sets: [BackupSet],
                               _ state: RestoreRecord.State, _ reason: String?) throws(Problem) {
        let now = ISO8601DateFormatter().string(from: Date())
        for i in records.indices {
            records[i].state = state
            records[i].reason = reason
            records[i].finishedAt = now
        }
        try persistRecords(records, sets)
    }

    /// After a retry verifies the app with every file original, finish any
    /// record an earlier run left in progress or pending, so the history does
    /// not show unfinished work. Failed and refused records stay as they were.
    /// Runs only after the restore succeeded, so a record it cannot finish
    /// becomes a note, never a failure; each set is tried independently.
    private static func closeUnfinishedRecords(_ sets: [BackupSet]) -> [String] {
        var notes: [String] = []
        for set in sets {
            do {
                try closeUnfinishedRecord(in: set)
            } catch {
                notes.append("the app is restored and verifies, but an earlier restore record in \(set.staging.path) could not be marked finished: \(error.description)")
            }
        }
        return notes
    }

    private static func closeUnfinishedRecord(in set: BackupSet) throws(Problem) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tree = try FileTree(set.staging)
        guard let kind = try tree.kind([RestoreRecord.fileName]) else { return }
        guard kind == .regular else {
            throw Problem("the restore record in \(set.staging.path) is not a regular file")
        }
        var record: RestoreRecord
        do {
            record = try JSONDecoder().decode(RestoreRecord.self, from: tree.read([RestoreRecord.fileName], limit: 16 << 20))
        } catch {
            throw Problem("cannot read the restore record in \(set.staging.path): \(error)")
        }
        guard record.state == .inProgress || record.state == .pending else { return }
        record.state = .restored
        record.reason = "finished by a later restore run that found every file original and the app verified"
        record.finishedAt = ISO8601DateFormatter().string(from: Date())
        for i in record.files.indices { record.files[i].state = .restored }
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw Problem("cannot encode the restore record: \(error.localizedDescription)")
        }
        try durablyWrite(data, to: set.staging.appending(path: RestoreRecord.fileName))
    }

    private static func persistRecords(_ records: [RestoreRecord], _ sets: [BackupSet]) throws(Problem) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for (record, set) in zip(records, sets) where !record.files.isEmpty {
            let data: Data
            do {
                data = try encoder.encode(record)
            } catch {
                throw Problem("cannot encode the restore record: \(error.localizedDescription)")
            }
            try durablyWrite(data, to: set.staging.appending(path: RestoreRecord.fileName))
        }
    }
}

/// Holds an exclusive lock on a staging directory's `.lock` file, so two
/// operations never use the same backups at once.
final class StagingLock {
    private let fd: Int32

    init(_ staging: URL) throws(Problem) {
        let path = staging.appending(path: ".lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Problem("cannot open \(path): \(errnoDescription())") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            close(fd)
            throw Problem(busy ? "another operation is using the backups in \(staging.path)"
                               : "cannot lock \(path): \(errnoDescription())")
        }
        self.fd = fd
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// Writes `data` to `url` atomically and durably: a temporary file in the
/// same directory, `F_FULLFSYNC`, `rename(2)`, then a flush of the directory.
func durablyWrite(_ data: Data, to url: URL, flushDirectory: (String) -> String? = syncDirectory) throws(Problem) {
    let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).tmp").path
    let fd = open(temp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw Problem("cannot create \(temp): \(errnoDescription())") }
    let written = data.withUnsafeBytes { raw in write(fd, raw.baseAddress, raw.count) }
    guard written == data.count, fcntl(fd, F_FULLFSYNC) == 0 else {
        let reason = written < 0 || written == data.count ? errnoDescription() : "short write"
        close(fd)
        unlink(temp)
        throw Problem("cannot write \(url.path): \(reason)")
    }
    close(fd)
    guard rename(temp, url.path) == 0 else {
        let reason = errnoDescription()
        unlink(temp)
        throw Problem("cannot move \(url.lastPathComponent) into place: \(reason)")
    }
    if let problem = flushDirectory(url.deletingLastPathComponent().path) {
        throw Problem("cannot flush \(url.deletingLastPathComponent().path) to disk: \(problem)")
    }
}

/// Flushes a directory's entries to disk; nil on success.
func syncDirectory(_ path: String) -> String? {
    let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { return errnoDescription() }
    defer { close(fd) }
    return fcntl(fd, F_FULLFSYNC) == 0 ? nil : errnoDescription()
}

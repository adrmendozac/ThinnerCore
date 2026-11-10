import Darwin
import Foundation

/// What `ReleaseOperation.release` did.
public struct ReleaseResult: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Every backup set for the app was deleted.
        case released
        /// No backups made by this tool were found; nothing was deleted.
        case nothingToRelease(String)
        /// A check failed before anything was deleted.
        case refused(String)
        /// An unfinished thinning or restore still needs the backups. Nothing
        /// was deleted; finish it first.
        case pending(String)

        /// The process exit status, per the table in `PLAN.md` Phase 5.
        public var exitCode: Int32 {
            switch self {
            case .released, .nothingToRelease: 0
            case .refused: 1
            case .pending: 3
            }
        }
    }

    public var outcome: Outcome
    /// Staging directories deleted by this run.
    public var released: [String] = []
    /// The logical size of the backups deleted. Physical space freed can be
    /// smaller: a backup shares blocks with any file restored from it, and
    /// local snapshots can keep blocks allocated.
    public var releasedBytes: UInt64 = 0
    /// Facts the user should see, including what the release cost them.
    public var notes: [String] = []

    init(_ outcome: Outcome) {
        self.outcome = outcome
    }
}

/// Deletes an app's backup sets, the one explicit way backups are discarded
/// (Phase 0 backup policy, approved 2026-10-04). Backups keep the original
/// blocks allocated, so disk usage grows by each thinned file's size until the
/// app's backups are released.
///
/// Release never touches the app. It holds the app's `AppLock` and each set's
/// `StagingLock`, so it cannot run during apply, recover, or restore. It
/// checks every set before deleting any, and refuses, deleting nothing, when:
/// the app is in a protected location or missing; any backup record cannot be
/// read; any thinning operation is unfinished or failed recovery; any restore
/// is unfinished or failed verification; or another user's run made a set.
///
/// Each set is first renamed to `.thinner-released-<UUID>`, which no operation
/// treats as a backup set, and that rename is flushed. Only then is it
/// deleted, so a set is either whole and usable or out of use. A deletion cut
/// short is finished by the next release.
public enum ReleaseOperation {
    public static let warning = "Released backups are gone: restore can no longer put the original universal files back. Only reinstalling or re-downloading the app, while the vendor still distributes a universal build, brings back its Intel code."

    static let releasedPrefix = ".thinner-released-"

    /// Deleting backups is held back by the same release gate as `apply` and
    /// `restore`. There is deliberately no runtime override.
    public static func release(_ app: URL) -> ReleaseResult {
        guard MutationReleaseGate.isOpen else { return ReleaseResult(.refused(MutationCommands.releaseBlock)) }
        return releaseUnreleased(app)
    }

    /// What `release` would delete, read-only and unlocked, like a scan: the
    /// same checks, with `released` listing the sets that would go. Not
    /// gated, since it changes nothing. A later release rechecks everything.
    public static func preview(_ app: URL) -> ReleaseResult {
        preview(app, environment: .init())
    }

    static func preview(_ app: URL, environment env: RestoreOperation.Environment) -> ReleaseResult {
        do throws(Problem) {
            var real = try RestoreOperation.missingAppPath(app)
            if real == nil { real = try RestoreOperation.resolve(app) }
            return try release(real!, env, delete: false)
        } catch {
            return ReleaseResult(.refused("Nothing would be deleted: \(error.description)"))
        }
    }

    /// The release. Internal so tests can run it; library clients reach only
    /// the gated `release`.
    static func releaseUnreleased(_ app: URL, environment env: RestoreOperation.Environment = .init()) -> ReleaseResult {
        do {
            // A deleted app's backups can still be released; with no app
            // there is nothing to lock, and each set's lock is still taken.
            if let missing = try RestoreOperation.missingAppPath(app) {
                return try release(missing, env, delete: true)
            }
            let real = try RestoreOperation.resolve(app)
            let lock = try AppLock(real)
            defer { withExtendedLifetime(lock) {} }
            return try release(real, env, delete: true)
        } catch {
            return ReleaseResult(.refused("Nothing was deleted: \(error.description)"))
        }
    }

    private static func release(_ real: String, _ env: RestoreOperation.Environment, delete: Bool) throws(Problem) -> ReleaseResult {
        let parent = (real as NSString).deletingLastPathComponent
        let earlier = delete ? finishEarlierReleases(of: real, in: parent, env) : []
        func reporting(_ outcome: ReleaseResult.Outcome) -> ReleaseResult {
            var result = ReleaseResult(outcome)
            result.notes = earlier
            return result
        }
        let sets = try RestoreOperation.findBackupSets(for: real)
        guard !sets.isEmpty else {
            return reporting(.nothingToRelease("no backups made by this tool were found next to the app"))
        }

        let quoted = StagingOwner.shellQuoted(real)
        // Why these sets must not be deleted now, or nil.
        func blocked(_ sets: [RestoreOperation.BackupSet]) throws(Problem) -> ReleaseResult? {
            let unfinished = sets.filter { $0.journal.state == .inProgress || $0.journal.state == .recoveryFailed }
            guard unfinished.isEmpty else {
                return reporting(.pending("an unfinished operation still needs its backups (\(unfinished.map(\.staging.path).joined(separator: ", "))). Run thinnercore recover \(quoted) first. Nothing was deleted"))
            }
            for set in sets {
                switch try restoreState(set) {
                case .inProgress?, .pending?:
                    return reporting(.pending("a restore from \(set.staging.path) did not finish. Run thinnercore restore \(quoted) first. Nothing was deleted"))
                case .recoveryFailed?:
                    // The app may be part restored and not verify; these backups
                    // are its only way back.
                    return reporting(.pending("a restore from \(set.staging.path) failed verification, so the app may still need these backups. Run thinnercore restore \(quoted) until it succeeds first. Nothing was deleted"))
                case .restored?, .refused?, nil:
                    break
                }
                if let refusal = StagingOwner.refusal(set.staging, euid: env.euid(), rerun: "release", app: real) {
                    throw Problem(refusal)
                }
            }
            return nil
        }
        if let refusal = try blocked(sets) { return refusal }

        guard delete else {
            var result = reporting(.released)
            result.released = sets.map(\.staging.path)
            result.releasedBytes = sets.flatMap(\.journal.entries).map(\.originalSize).saturatingSum()
            result.notes.append(warning)
            return result
        }

        var locks: [StagingLock] = []
        for set in sets { locks.append(try StagingLock(set.staging)) }
        defer { withExtendedLifetime(locks) {} }

        // Checked again now that no other operation can use these backups:
        // without the app's lock (a missing app has none to take), the app
        // can come back and a restore can run between the first check and
        // the locks. Read every record afresh, and stop if the sets changed.
        let locked = try RestoreOperation.findBackupSets(for: real)
        guard locked.map(\.staging.path) == sets.map(\.staging.path) else {
            return reporting(.pending("the app's backup sets changed during the release. Nothing was deleted; run release again"))
        }
        if let refusal = try blocked(locked) { return refusal }

        let current = try? AppIdentity.of(URL(filePath: real))
        var result = reporting(.released)
        for set in sets {
            let releasedPath = parent + "/" + releasedPrefix + String(set.staging.lastPathComponent.dropFirst(".thinner-".count))
            guard rename(set.staging.path, releasedPath) == 0 else {
                result.outcome = result.released.isEmpty
                    ? .refused("Nothing was deleted: cannot take \(set.staging.path) out of use: \(errnoDescription())")
                    : .refused("cannot take \(set.staging.path) out of use: \(errnoDescription()); its backups are kept, the sets listed as released are gone")
                break
            }
            if let problem = env.flushDirectory(parent) {
                // Not durable: put it back rather than delete a set that a
                // crash could bring back half deleted.
                let restored = rename(releasedPath, set.staging.path) == 0
                let kept = restored ? "its backups are kept in \(set.staging.path)" : "its backups are kept in \(releasedPath), where restore cannot find them; run release again to finish deleting them"
                result.outcome = .refused("cannot flush \(parent) to disk: \(problem); \(kept)")
                break
            }
            result.released.append(set.staging.path)
            result.releasedBytes = ([result.releasedBytes] + set.journal.entries.map(\.originalSize)).saturatingSum()
            if let current, set.identity != current {
                result.notes.append("\(set.staging.path) held backups from another version of the app (\(set.identity.map(\.description) ?? "unrecorded"))")
            }
            do {
                try FileManager.default.removeItem(atPath: releasedPath)
            } catch {
                result.notes.append("\(set.staging.path) is out of use, but deleting \(releasedPath) stopped: \(error.localizedDescription). Run release again to finish")
            }
        }
        if !result.released.isEmpty { result.notes.append(warning) }
        return result
    }

    /// The state of a set's restore record, or nil when none was written.
    private static func restoreState(_ set: RestoreOperation.BackupSet) throws(Problem) -> RestoreOperation.RestoreRecord.State? {
        let tree = try FileTree(set.staging)
        let name = RestoreOperation.RestoreRecord.fileName
        guard let kind = try tree.kind([name]) else { return nil }
        guard kind == .regular else {
            throw Problem("the restore record in \(set.staging.path) is not a regular file")
        }
        do {
            return try JSONDecoder().decode(RestoreOperation.RestoreRecord.self, from: tree.read([name], limit: 16 << 20)).state
        } catch {
            throw Problem("cannot read the restore record in \(set.staging.path), so it may describe an unfinished restore: \(error)")
        }
    }

    /// Deletes what an earlier release of this app took out of use but did
    /// not finish deleting. Read without following symlinks; a directory whose
    /// journal cannot be read, names another app, or belongs to another user
    /// is left alone and reported.
    private static func finishEarlierReleases(of real: String, in parent: String, _ env: RestoreOperation.Environment) -> [String] {
        guard let tree = try? FileTree(URL(filePath: parent)), let entries = try? tree.entries([]) else { return [] }
        var notes: [String] = []
        for entry in entries where isReleasedName(entry.name) && entry.kind == .directory {
            let path = parent + "/" + entry.name
            guard let data = try? tree.read([entry.name, Journal.fileName], limit: 16 << 20),
                  let journal = try? JSONDecoder().decode(Journal.self, from: data) else {
                notes.append("left \(path) alone: its record cannot be read")
                continue
            }
            guard RestoreOperation.canonicalBundlePath(journal.bundlePath) == real else { continue }
            if let refusal = StagingOwner.refusal(URL(filePath: path), euid: env.euid(), rerun: "release", app: real) {
                notes.append(refusal)
                continue
            }
            do {
                try FileManager.default.removeItem(atPath: path)
                notes.append("finished deleting \(path), left by an earlier release")
            } catch {
                notes.append("cannot finish deleting \(path): \(error.localizedDescription)")
            }
        }
        return notes
    }

    static func isReleasedName(_ name: String) -> Bool {
        name.hasPrefix(releasedPrefix) && UUID(uuidString: String(name.dropFirst(releasedPrefix.count))) != nil
    }
}

import Foundation
import Darwin

public enum ThinOperation {
    public enum Outcome: Equatable {
        case committed
        case rolledBack(reason: String)
        case recoveryFailed(reason: String)
        case pending(reason: String)
        case skipped(reason: String)
        /// The operation's app is gone or was replaced; see
        /// `Journal.OperationState.superseded`. Nothing was changed.
        case superseded(reason: String)
    }

    /// What tests replace: process inspection, `codesign --verify`, step
    /// boundaries, and directory flushes.
    typealias Environment = RestoreOperation.Environment

    public static func apply(to bundleURL: URL) throws(Problem) -> Outcome {
        guard MutationReleaseGate.isOpen else { return .skipped(reason: MutationCommands.releaseBlock) }
        return try applyUnreleased(to: bundleURL)
    }

    /// Recovers interrupted operations on the app at `app`. Recovery changes
    /// the app, so it is held back by the same release gate as `apply`.
    public static func recover(_ app: URL) -> Outcome {
        guard MutationReleaseGate.isOpen else { return .skipped(reason: MutationCommands.releaseBlock) }
        return recoverUnreleased(app)
    }

    // MARK: - Writer

    /// The writer. Internal so tests can run it; library clients reach only
    /// the gated `apply`.
    static func applyUnreleased(to app: URL, options: ScanOptions = ScanOptions(),
                                environment env: Environment = Environment()) throws(Problem) -> Outcome {
        if let refusal = env.host() {
            return .skipped(reason: refusal.description)
        }
        let real: String
        let lock: AppLock
        do {
            real = try RestoreOperation.resolve(app)
            lock = try AppLock(real)
        } catch {
            return .skipped(reason: error.description)
        }
        defer { withExtendedLifetime(lock) {} }
        let bundle = URL(filePath: real)

        // Every app-level rule, read fresh: protected location, user
        // exclusions, Rosetta signals, script-only, unreadable metadata, and
        // the initial signature check. A saved scan never authorizes this.
        var scan = AppScanner.scan(bundle, options: options)
        guard scan.apps.count == 1, var target = scan.apps.first else {
            return .skipped(reason: "cannot read \(real) as one app")
        }
        // A broken signature can be the reason recovery is needed. All other
        // app policies still refuse before any recovery mutation.
        if let skip = target.skip, case .signatureInvalid = skip {} else if let skip = target.skip {
            return .skipped(reason: skip.description)
        }
        let pending = try RestoreOperation.findBackupSets(for: real)
            .filter { $0.journal.state == .inProgress || $0.journal.state == .recoveryFailed }
        if !pending.isEmpty {
            // Pending only when a recovery is actually waiting; otherwise an
            // unreadable app is an ordinary skip, below.
            guard target.issues.isEmpty else {
                return .pending(reason: "cannot inspect the complete app before recovery")
            }
            for set in pending {
                if let refusal = StagingOwner.refusal(set.staging, euid: env.euid(), rerun: "recover", app: real) {
                    return .pending(reason: refusal)
                }
            }
            if let busy = idleRefusal(bundle, env) { return .pending(reason: busy) }
            for set in pending {
                let outcome = try recover(set, bundle: bundle, env: env)
                // Do not immediately retry an operation that just rolled back.
                // A superseded one belonged to another version: thin this one.
                if case .superseded = outcome { continue }
                guard outcome == .committed else { return outcome }
            }
            scan = AppScanner.scan(bundle, options: options)
            guard let refreshed = scan.apps.first, scan.apps.count == 1 else {
                return .pending(reason: "cannot re-scan app after recovery")
            }
            target = refreshed
        }
        if let skip = target.skip { return .skipped(reason: skip.description) }
        guard target.issues.isEmpty else {
            return .skipped(reason: "parts of the app cannot be read: \(target.issues.map(\.relativePath).joined(separator: ", "))")
        }
        let eligibleFiles = target.files.filter(\.isEligible)
        guard !eligibleFiles.isEmpty else {
            return .skipped(reason: "no eligible files")
        }

        if let busy = idleRefusal(bundle, env) {
            return .skipped(reason: busy)
        }
        if let verifyError = env.verify(bundle) {
            return .skipped(reason: "app signature is invalid before thinning: \(verifyError)")
        }

        let identity: AppIdentity
        do {
            identity = try AppIdentity.of(bundle)
        } catch {
            return .skipped(reason: "cannot record which version of the app this is: \(error.description)")
        }

        let requiredBytes = eligibleFiles.map {
            if case let .eligible(_, savedBytes) = $0.decision {
                return $0.size - savedBytes
            }
            return 0
        }.reduce(0, +)

        StagingArea.removeAbandonedPreparations(of: real, euid: env.euid())
        let operationID = UUID().uuidString
        let staging = try StagingArea(bundlePath: bundle, operationID: operationID, requiredBytes: requiredBytes,
                                      freeSpace: env.freeSpace)

        // Recorded before the first backup, so rollback, recovery, and
        // restore can always find the operation and prove the app's version.
        var journal = Journal(
            operationID: operationID,
            bundlePath: real,
            bundleIdentifier: identity.bundleIdentifier,
            startedAt: ISO8601DateFormatter().string(from: Date()),
            appIdentity: identity,
            plannedFiles: eligibleFiles.compactMap {
                if case .eligible = $0.decision { return $0.relativePath }
                return nil
            }
        )
        try staging.activate(with: journal, boundary: { env.boundary($0, "") })
        env.boundary("operation-journal", "")

        // The app this operation set out to thin: the same directory, at
        // the same version. An updater can replace the bundle between steps
        // while nothing from it runs, and a path alone would then lead the
        // writer into the new version under the old version's checks.
        let sameApp = { () -> String? in
            guard lock.stillHolds(real) else { return "\(real) was replaced by another directory" }
            guard let now = try? AppIdentity.of(bundle) else { return "cannot read the identity of \(real)" }
            return now == identity ? nil : "the app changed during the operation (then: \(identity); now: \(now))"
        }

        do {
            try executeSwaps(journal: &journal, eligibleFiles: eligibleFiles, staging: staging, bundle: bundle,
                             sameApp: sameApp, env: env)
        } catch {
            return rollback(&journal, journalPath: staging.journalPath, bundle: bundle, env: env, reason: "mutation failed: \(error.description)")
        }

        // Verify app after swaps
        if let verifyError = env.verify(bundle) {
            return rollback(&journal, journalPath: staging.journalPath, bundle: bundle, env: env, reason: "verification failed after thinning: \(verifyError)")
        }
        if let changed = sameApp() {
            return rollback(&journal, journalPath: staging.journalPath, bundle: bundle, env: env, reason: changed)
        }

        // Check thinned hashes
        for entry in journal.entries where entry.state == .replaced {
            let targetPath = bundle.appending(path: entry.relativePath).path
            do {
                let currentHash = try SHA256.hash(file: targetPath)
                if currentHash != entry.thinnedHash {
                    return rollback(&journal, journalPath: staging.journalPath, bundle: bundle, env: env, reason: "hash mismatch for \(entry.relativePath)")
                }
            } catch {
                return rollback(&journal, journalPath: staging.journalPath, bundle: bundle, env: env, reason: "cannot hash \(entry.relativePath): \(error.description)")
            }
        }

        for i in journal.entries.indices where journal.entries[i].state == .replaced {
            journal.entries[i].state = .committed
        }
        env.boundary("verified", "")
        journal.state = .committed
        do {
            try journal.persist(to: staging.journalPath, flushDirectory: env.flushDirectory)
        } catch {
            // The rename may already expose a committed journal even though
            // its directory flush failed. The app has changed; an unlocked
            // search for unfinished journals cannot establish durability.
            return .pending(reason: "App thinned and verified, but the commit journal could not be durably saved: \(error.description). Keep all backups and inspect \(staging.journalPath.path) before retrying.")
        }
        env.boundary("committed", "")
        return .committed
    }

    private static func executeSwaps(journal: inout Journal, eligibleFiles: [WalkedFile], staging: StagingArea,
                                     bundle: URL, sameApp: () -> String?, env: Environment) throws(Problem) {
        let CLONE_NOFOLLOW: UInt32 = 1

        for file in eligibleFiles {
            let targetPath = bundle.appending(path: file.relativePath).path
            let backupURL = try staging.backupPath(for: file.relativePath)
            let tempURL = try staging.tempPath(for: file.relativePath)

            guard case let .eligible(removals, savedBytes) = file.decision else { continue }

            // 1. SHA-256 original + arm64 slice + file identity
            let originalHash = try SHA256.hash(file: targetPath)

            // Need arm64 slice offset and size for hashing. Parse header again.
            let headerData = try readHeader(targetPath)
            let parsedOriginalFatBinary = FatBinary.parse(headerData, fileSize: file.size)
            guard case let .fat(fatBinary) = parsedOriginalFatBinary else {
                throw Problem("Failed to parse fat binary at \(targetPath)")
            }
            // Every slice that stays, arm64 among them, must come out of lipo
            // byte for byte: their signatures are what keeps the file valid.
            let kept = fatBinary.slices.filter { !removals.contains($0.arch) }
            guard kept.contains(where: { $0.arch == .arm64 }) else {
                throw Problem("Missing arm64 slice in \(targetPath)")
            }
            var keptHashes: [Arch: String] = [:]
            for slice in kept {
                keptHashes[slice.arch] = try SHA256.hash(file: targetPath, offset: slice.offset, count: slice.size)
            }
            let originalArm64Hash = keptHashes[.arm64]!
            guard let identity = FileIdentity.of(targetPath) else {
                throw Problem("Cannot stat \(targetPath)")
            }

            env.boundary("original-hashed", file.relativePath)
            // 2. clonefile backup
            if clonefile(targetPath, backupURL.path, CLONE_NOFOLLOW) != 0 {
                throw Problem("cannot back up \(file.relativePath): \(PermissionDiagnostic.describe(errno, path: backupURL.path))")
            }
            let backupHash = try SHA256.hash(file: backupURL.path)
            guard backupHash == originalHash else {
                throw Problem("Backup hash mismatch for \(targetPath)")
            }

            env.boundary("backup-verified", file.relativePath)
            // 3. remove the slices, as `lipo -remove` would
            try SliceRemover.remove(removals, from: targetPath, to: tempURL.path)

            env.boundary("lipo-written", file.relativePath)
            // 4. validate temp
            let thinnedSize = file.size - savedBytes
            guard let tempIdentity = FileIdentity.of(tempURL.path) else {
                throw Problem("Cannot stat temp file \(tempURL.path)")
            }
            guard tempIdentity.size == thinnedSize else {
                throw Problem("Thinned size mismatch for \(tempURL.path). Expected \(thinnedSize), got \(tempIdentity.size)")
            }

            let tempHeaderData = try readHeader(tempURL.path)
            let parsedTempFatBinary = FatBinary.parse(tempHeaderData, fileSize: thinnedSize)
            guard case let .fat(tempFatBinary) = parsedTempFatBinary else {
                throw Problem("Failed to parse thinned fat binary at \(tempURL.path)")
            }
            guard Set(tempFatBinary.slices.map(\.arch)) == Set(kept.map(\.arch)) else {
                throw Problem("thinned file \(tempURL.path) has slices \(tempFatBinary.slices.map(\.arch)), expected \(kept.map(\.arch))")
            }
            for slice in tempFatBinary.slices {
                let hash = try SHA256.hash(file: tempURL.path, offset: slice.offset, count: slice.size)
                guard hash == keptHashes[slice.arch] else {
                    throw Problem("\(slice.arch) slice hash changed after thinning \(targetPath)")
                }
            }

            let thinnedHash = try SHA256.hash(file: tempURL.path)

            let srcFD = open(targetPath, O_RDONLY | O_NOFOLLOW)
            guard srcFD >= 0 else { throw Problem("cannot open source for metadata copy") }
            defer { close(srcFD) }

            let dstFD = open(tempURL.path, O_RDWR | O_NOFOLLOW)
            guard dstFD >= 0 else { throw Problem("cannot open dest for metadata copy") }
            defer { close(dstFD) }

            if let metadataError = try MetadataCopier.copy(from: targetPath, to: tempURL.path, sourceFD: srcFD, destFD: dstFD) {
                throw Problem("metadata copy failed: \(metadataError)")
            }

            guard fcntl(dstFD, F_FULLFSYNC) == 0 else {
                throw Problem("F_FULLFSYNC failed on temp file: \(errnoDescription())")
            }

            env.boundary("temp-verified", file.relativePath)
            // 5. journal
            let entry = Journal.Entry(
                relativePath: file.relativePath,
                originalHash: originalHash,
                thinnedHash: thinnedHash,
                arm64SliceHash: originalArm64Hash,
                backupPath: backupURL.path,
                tempPath: tempURL.path,
                originalSize: file.size,
                thinnedSize: thinnedSize,
                state: .ready
            )
            journal.entries.append(entry)
            try journal.persist(to: staging.journalPath)

            env.boundary("ready-journal", file.relativePath)
            // Process inspection may be slow. Recheck bytes and identity after
            // it, immediately before rename, including after hashing.
            if let busy = idleRefusal(bundle, env) {
                throw Problem("stopped before replacing \(file.relativePath): \(busy)")
            }
            if let changed = sameApp() {
                throw Problem("stopped before replacing \(file.relativePath): \(changed)")
            }
            guard FileIdentity.of(targetPath) == identity,
                  try SHA256.hash(file: targetPath) == originalHash,
                  FileIdentity.of(targetPath) == identity else {
                throw Problem("File identity or SHA-256 changed before swap for \(targetPath)")
            }

            if let problem = PathSafety.renameNoFollow(tempURL.path, targetPath) {
                throw Problem("cannot move the thinned \(file.relativePath) into place: \(problem)")
            }

            env.boundary("swapped", file.relativePath)
            if let problem = env.flushDirectory((targetPath as NSString).deletingLastPathComponent) {
                throw Problem("cannot flush replaced directory: \(problem)")
            }
            env.boundary("directory-flushed", file.relativePath)

            let idx = journal.entries.count - 1
            journal.entries[idx].state = .replaced
            try journal.persist(to: staging.journalPath)
            env.boundary("replacement-recorded", file.relativePath)
        }
    }

    // MARK: - Rollback

    /// Puts the originals back after a failed operation, through restore's
    /// validated path, scoped to this operation: each backup is checked
    /// against the original's hash, cloned (never moved) into place only if
    /// the file still holds its thinned version, and checked again before
    /// `codesign` runs. Every backup is kept. The caller holds the `AppLock`.
    private static func rollback(_ journal: inout Journal, journalPath: URL, bundle: URL,
                                 env: Environment, reason: String) -> Outcome {
        if let busy = idleRefusal(bundle, env) {
            try? journal.persist(to: journalPath)
            return .pending(reason: "Rollback waits: \(busy). Quit it and run recover. Original error: \(reason)")
        }

        let result: RestoreResult
        do {
            try journal.persist(to: journalPath)
            result = try RestoreOperation.revert(bundle.path, operation: journal.operationID, env)
        } catch {
            journal.state = .recoveryFailed
            try? journal.persist(to: journalPath)
            return .recoveryFailed(reason: "Rollback refused, nothing was put back: \(error.description). Every backup is kept. Original error: \(reason)")
        }

        let restored = Set(result.restored)
        for i in journal.entries.indices where restored.contains(journal.entries[i].relativePath) {
            journal.entries[i].state = .restored
        }
        let outcome: Outcome
        switch result.outcome {
        case .restored, .nothingToRestore:
            journal.state = .rolledBack
            outcome = .rolledBack(reason: reason)
        case let .pending(why):
            outcome = .pending(reason: "\(why). Original error: \(reason)")
        case let .refused(why), let .recoveryFailed(why):
            journal.state = .recoveryFailed
            outcome = .recoveryFailed(reason: "\(why). Original error: \(reason)")
        }
        do {
            try journal.persist(to: journalPath)
        } catch {
            return .recoveryFailed(reason: "cannot record the rollback: \(error.description). Every backup is kept. Original error: \(reason)")
        }
        return outcome
    }

    // MARK: - Recovery

    /// Resolves interrupted operations on the app at `app`. Internal so tests
    /// can run it; library clients reach only the gated `recover`.
    ///
    /// Operations are found as restore finds them: `.thinner-<UUID>` staging
    /// directories next to the app, read without following symlinks, whose
    /// journal names this app and has a known schema. A journal is never
    /// trusted to name another location: every recorded path must stay inside
    /// the app, and backups inside their staging directory. Each file is then
    /// judged by its hash: original means not swapped; thinned means swapped,
    /// so the app is verified and committed, or put back through restore's
    /// validated path; anything else means something else changed the file,
    /// so nothing is touched and every backup is kept.
    static func recoverUnreleased(_ app: URL, environment env: Environment = Environment()) -> Outcome {
        if let refusal = env.host() {
            return .skipped(reason: refusal.description)
        }
        let real: String
        let lock: AppLock
        do {
            if let missing = try RestoreOperation.missingAppPath(app) {
                return supersede(missingApp: missing, env: env)
            }
            real = try RestoreOperation.resolve(app)
            lock = try AppLock(real)
        } catch {
            return .pending(reason: "Cannot recover yet, nothing was changed: \(error.description)")
        }
        defer { withExtendedLifetime(lock) {} }
        let bundle = URL(filePath: real)

        do {
            let sets = try RestoreOperation.findBackupSets(for: real)
                .filter { $0.journal.state == .inProgress || $0.journal.state == .recoveryFailed }
            guard !sets.isEmpty else {
                return .skipped(reason: "no unfinished operation was found for \(real)")
            }
            for set in sets {
                if let refusal = StagingOwner.refusal(set.staging, euid: env.euid(), rerun: "recover", app: real) {
                    return .pending(reason: refusal)
                }
            }
            if let busy = idleRefusal(bundle, env) {
                return .pending(reason: "Cannot recover yet, nothing was changed: \(busy)")
            }
            var outcomes: [Outcome] = []
            for set in sets {
                let outcome = try recover(set, bundle: bundle, env: env)
                outcomes.append(outcome)
                if severity(outcome) >= 3 { return outcome }
            }
            return outcomes.max { severity($0) < severity($1) }!
        } catch {
            return .recoveryFailed(reason: "Recovery refused, nothing was changed: \(error.description). Every backup is kept")
        }
    }

    private static func recover(_ set: RestoreOperation.BackupSet, bundle: URL, env: Environment) throws(Problem) -> Outcome {
        var journal = set.journal
        let journalPath = set.staging.appending(path: Journal.fileName)

        guard let recorded = set.identity else {
            throw Problem("the journal in \(set.staging.path) does not record which version of the app it belongs to")
        }
        let current = try AppIdentity.of(bundle)
        guard recorded == current else {
            return try supersede(set, journal: &journal, at: journalPath, bundle: bundle, recorded: recorded, current: current)
        }

        let tree = try FileTree(bundle)
        var swapped: [Int] = []
        var untouched: [Int] = []
        var changed: [String] = []
        for (i, entry) in journal.entries.enumerated() {
            guard let parts = RestoreOperation.safeComponents(entry.relativePath) else {
                throw Problem("the journal names an unsafe path: \(entry.relativePath)")
            }
            guard try tree.kind(parts) == .regular else {
                changed.append(entry.relativePath)
                continue
            }
            do { try RestoreOperation.checkBackup(entry, in: set) } catch {
                journal.state = .recoveryFailed
                try journal.persist(to: journalPath)
                throw error
            }
            let hash = try SHA256.hash(file: bundle.path + "/" + entry.relativePath)
            if hash == entry.originalHash { untouched.append(i); continue }
            if let thinned = entry.thinnedHash, hash == thinned {
                swapped.append(i)
            } else {
                changed.append(entry.relativePath)
            }
        }

        guard changed.isEmpty else {
            journal.state = .recoveryFailed
            try journal.persist(to: journalPath)
            return .recoveryFailed(reason: "these files match neither their original nor their thinned version, so something else changed them: \(changed.sorted().joined(separator: ", ")). Nothing was changed; every backup in \(set.staging.path) is kept")
        }
        // A previous crash may have happened between rename and directory
        // flush. Re-establish durability before resolving the journal.
        for directory in Set(journal.entries.map { (bundle.path + "/" + $0.relativePath as NSString).deletingLastPathComponent }) {
            if let problem = env.flushDirectory(directory) { return .pending(reason: "cannot flush recovered directory: \(problem)") }
        }
        for i in untouched { journal.entries[i].state = .restored }
        guard !swapped.isEmpty else {
            journal.state = .rolledBack
            try journal.persist(to: journalPath)
            return .rolledBack(reason: "the interrupted operation had not replaced any file")
        }
        // The writer stopped part way through: some entries still hold their
        // original, or some planned files never got an entry. Committing
        // would report files it never reached as done and leave nothing to
        // resume, so put the replaced ones back and let the user rerun it.
        let planned = journal.plannedFiles.map(Set.init)
        let reachedAll = planned == Set(journal.entries.map(\.relativePath))
        guard untouched.isEmpty, reachedAll else {
            let of = planned.map { "\($0.count) planned" } ?? "an unrecorded number of"
            return rollback(&journal, journalPath: journalPath, bundle: bundle, env: env,
                            reason: "the interrupted operation replaced \(swapped.count) of \(of) files; rolled back so it can be rerun")
        }
        if env.verify(bundle) == nil {
            for i in swapped { journal.entries[i].state = .committed }
            journal.state = .committed
            try journal.persist(to: journalPath)
            return .committed
        }
        return rollback(&journal, journalPath: journalPath, bundle: bundle, env: env,
                        reason: "the app does not verify after the interrupted operation")
    }

    /// An update replaced the app since the interrupted operation. If none of
    /// the operation's thinned files is still in it, there is nothing left to
    /// recover: mark the operation superseded so it stops blocking. If one
    /// is, the operation's change is still in the app and cannot be undone
    /// into a different version, so recovery fails as before.
    private static func supersede(_ set: RestoreOperation.BackupSet, journal: inout Journal, at journalPath: URL,
                                  bundle: URL, recorded: AppIdentity, current: AppIdentity) throws(Problem) -> Outcome {
        let tree = try FileTree(bundle)
        var stillThinned: [String] = []
        for entry in journal.entries {
            guard let parts = RestoreOperation.safeComponents(entry.relativePath) else {
                throw Problem("the journal names an unsafe path: \(entry.relativePath)")
            }
            guard try tree.kind(parts) == .regular, let thinned = entry.thinnedHash else { continue }
            if try SHA256.hash(file: bundle.path + "/" + entry.relativePath) == thinned {
                stillThinned.append(entry.relativePath)
            }
        }
        guard stillThinned.isEmpty else {
            return .recoveryFailed(reason: "the app changed since the interrupted operation, most likely by an update (then: \(recorded); now: \(current)), but still holds thinned files from it: \(stillThinned.sorted().joined(separator: ", ")). Its backups belong to the earlier version and are never restored into this one. Reinstall the app, then run recover again. Nothing was changed; every backup in \(set.staging.path) is kept")
        }
        journal.state = .superseded
        try journal.persist(to: journalPath)
        return .superseded(reason: "the app was replaced since the interrupted operation, most likely by an update (then: \(recorded); now: \(current)), and none of its thinned files remain, so there is nothing to recover. Nothing was changed; its backups are kept in \(set.staging.path) until you release them")
    }

    /// The app an unfinished operation changed no longer exists. Nothing can
    /// use or change it, so the operations stop blocking; the backups are
    /// kept. Each set's `StagingLock` excludes a concurrent recover, restore,
    /// or release of the same backups.
    private static func supersede(missingApp real: String, env: Environment) -> Outcome {
        do {
            let sets = try RestoreOperation.findBackupSets(for: real)
                .filter { $0.journal.state == .inProgress || $0.journal.state == .recoveryFailed }
            guard !sets.isEmpty else {
                return .skipped(reason: "no unfinished operation was found for \(real)")
            }
            for set in sets {
                if let refusal = StagingOwner.refusal(set.staging, euid: env.euid(), rerun: "recover", app: real) {
                    return .pending(reason: refusal)
                }
            }
            var locks: [StagingLock] = []
            for set in sets { locks.append(try StagingLock(set.staging)) }
            defer { withExtendedLifetime(locks) {} }
            // It may have come back while the locks were taken.
            guard try RestoreOperation.missingAppPath(URL(filePath: real)) != nil else {
                return .pending(reason: "\(real) appeared while recovering; nothing was changed. Run recover again")
            }
            for set in sets {
                var journal = set.journal
                journal.state = .superseded
                try journal.persist(to: set.staging.appending(path: Journal.fileName))
            }
            let kept = sets.map(\.staging.path).joined(separator: ", ")
            return .superseded(reason: "the app is no longer at \(real), so its unfinished operation no longer applies. Nothing was changed; its backups are kept in \(kept). If you moved the app, move it back and run thinnercore restore to put its original files back; otherwise run thinnercore release \(StagingOwner.shellQuoted(real)) to delete them")
        } catch {
            return .recoveryFailed(reason: "Recovery refused, nothing was changed: \(error.description). Every backup is kept")
        }
    }

    /// Exit-code order: the worst outcome across operations wins.
    private static func severity(_ outcome: Outcome) -> Int {
        switch outcome {
        case .committed, .skipped, .superseded: 0
        case .rolledBack: 1
        case .pending: 3
        case .recoveryFailed: 4
        }
    }

    // MARK: - Checks

    /// Why the app cannot be treated as idle, or nil. Fails closed: a process
    /// whose files cannot be inspected might be using the app, so incomplete
    /// visibility refuses, as `MutationCommands.apply` does.
    static func idleRefusal(_ bundle: URL, _ env: Environment) -> String? {
        do {
            let usage = try env.usage(bundle)
            if !usage.uses.isEmpty {
                return "the app is in use: " + usage.uses.prefix(3).map(\.description).joined(separator: "; ")
            }
            if usage.uninspectable > 0 {
                return "cannot establish that the app is idle: \(usage.uninspectable) processes could not be inspected; run as root"
            }
            return nil
        } catch {
            return "cannot check whether the app is in use: \(error.description)"
        }
    }

    private static func readHeader(_ path: String) throws(Problem) -> [UInt8] {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Problem("cannot open \(path) for header reading: \(errnoDescription())") }
        defer { close(fd) }

        var buffer = [UInt8](repeating: 0, count: FatBinary.maxHeaderLength)
        let n = buffer.withUnsafeMutableBytes { raw in
            pread(fd, raw.baseAddress!, raw.count, 0)
        }
        guard n >= 0 else { throw Problem("failed to read header from \(path): \(errnoDescription())") }
        return Array(buffer.prefix(n))
    }
}

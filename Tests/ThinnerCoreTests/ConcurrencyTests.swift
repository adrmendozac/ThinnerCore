import Darwin
import Foundation
import Testing
@testable import ThinnerCore

/// Another process holding an app's `AppLock`: `perl` opens the bundle
/// directory and takes `flock(2)` on it, as a second thinner process would.
/// Stopped by `stop()`.
struct HeldAppLock {
    let process = Process()

    init(_ app: URL) throws {
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/perl")
        process.arguments = ["-e", """
            use Fcntl qw(:flock);
            open(my $fh, "<", $ARGV[0]) or die "open: $!";
            flock($fh, LOCK_EX | LOCK_NB) or die "flock: $!";
            $| = 1; print "locked\\n"; sleep 60;
            """, app.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        try #require(line.contains("locked"), "the holder could not lock \(app.path)")
    }

    /// Whether another process can take the lock right now.
    static func otherProcessCanLock(_ app: URL) throws -> Bool {
        let result = try Shell.run("/usr/bin/perl", "-e", """
            use Fcntl qw(:flock);
            open(my $fh, "<", $ARGV[0]) or die "open: $!";
            print(flock($fh, LOCK_EX | LOCK_NB) ? "acquired" : "busy");
            """, app.path)
        try #require(result.status == 0, "\(result.output)")
        return result.output == "acquired"
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
    }
}

/// Damaged backups, updates that land while an operation runs, and locking
/// between processes. Disposable fixture copies only.
@Suite struct ConcurrencyTests {
    /// The staging directory of the fixture's one operation.
    func staging(_ fixture: ThinOperationTests) throws -> URL {
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.dir.path).filter(RestoreOperation.isStagingName)
        return fixture.dir.appending(path: try #require(names.count == 1 ? names.first : nil))
    }

    func isThinned(_ app: URL, _ path: String) throws -> Bool {
        try Shell.run("/usr/bin/lipo", "-archs", app.appending(path: path).path).output
            .trimmingCharacters(in: .whitespacesAndNewlines) == "arm64"
    }

    // MARK: - Damaged backups

    /// A backup damaged after the swaps: rollback must refuse before putting
    /// anything back, leave every file individually valid, keep every other
    /// backup, and leave the operation for manual attention.
    @Test func rollbackRefusesADamagedBackup() throws {
        let fixture = try ThinOperationTests()
        defer { fixture.cleanUp() }
        let paths = try fixture.eligibleHashes().keys.sorted()
        try #require(paths.count >= 2)

        var env = idleEnvironment
        var swaps = 0
        var damaged: String?
        env.boundary = { name, path in
            guard name == "replacement-recorded" else { return }
            swaps += 1
            guard swaps == paths.count, let staging = try? staging(fixture) else { return }
            let backup = staging.appending(path: "backups/\(path)")
            try? Data("damaged".utf8).write(to: backup)
            damaged = path
        }
        env.verify = verifyFailing(on: [2])   // before thinning passes, after fails

        let outcome = try ThinOperation.applyUnreleased(to: fixture.app, options: fixture.options, environment: env)
        guard case .recoveryFailed(let reason) = outcome else {
            Issue.record("expected recoveryFailed, got \(outcome)")
            return
        }
        let damagedPath = try #require(damaged)
        #expect(reason.contains("damaged"))
        for path in paths { #expect(try isThinned(fixture.app, path), "nothing was put back: \(path)") }
        #expect(Codesign.verify(fixture.app) == nil, "every file is individually valid")
        let journal = try fixture.stagingJournal()
        #expect(journal.state == .recoveryFailed)
        for entry in journal.entries where entry.relativePath != damagedPath {
            #expect(try SHA256.hash(file: entry.backupPath) == entry.originalHash)
        }

        // Later runs refuse the damaged backup too, and change nothing.
        let restore = RestoreOperation.restore(fixture.app, environment: idleEnvironment)
        guard case .refused(let why) = restore.outcome else {
            Issue.record("expected restore to refuse, got \(restore.outcome)")
            return
        }
        #expect(why.contains("damaged"))
        guard case .recoveryFailed = ThinOperation.recoverUnreleased(fixture.app, environment: idleEnvironment) else {
            Issue.record("expected recovery to refuse the damaged backup")
            return
        }
        for path in paths { #expect(try isThinned(fixture.app, path)) }
    }

    // MARK: - Updates during an operation

    /// An update replaces a thinned file after the swaps, before the app is
    /// verified. The writer must not commit, must not put an old original
    /// over the update, and must keep every backup.
    @Test func writerLeavesAFileUpdatedAfterItsSwap() throws {
        let fixture = try ThinOperationTests()
        defer { fixture.cleanUp() }
        let paths = try fixture.eligibleHashes().keys.sorted()

        var env = idleEnvironment
        var swaps = 0
        var updated: (path: String, hash: String)?
        env.boundary = { name, _ in
            guard name == "replacement-recorded" else { return }
            swaps += 1
            guard swaps == paths.count, let path = paths.first else { return }
            // An updater writes a new file and renames it into place.
            let target = fixture.app.appending(path: path)
            let incoming = fixture.dir.appending(path: "incoming")
            try? Data("version 2".utf8).write(to: incoming)
            guard rename(incoming.path, target.path) == 0, let hash = try? SHA256.hash(file: target.path) else { return }
            updated = (path, hash)
        }

        let outcome = try ThinOperation.applyUnreleased(to: fixture.app, options: fixture.options, environment: env)
        guard case .recoveryFailed = outcome else {
            Issue.record("expected recoveryFailed, got \(outcome)")
            return
        }
        let update = try #require(updated)
        #expect(try SHA256.hash(file: fixture.app.appending(path: update.path).path) == update.hash, "the update survives")
        let journal = try fixture.stagingJournal()
        #expect(journal.state == .recoveryFailed)
        for entry in journal.entries {
            #expect(try SHA256.hash(file: entry.backupPath) == entry.originalHash)
        }

        // Recovery leaves it too.
        guard case .recoveryFailed(let reason) = ThinOperation.recoverUnreleased(fixture.app, environment: idleEnvironment) else {
            Issue.record("expected recovery to leave the updated file")
            return
        }
        #expect(reason.contains("something else changed"))
        #expect(try SHA256.hash(file: fixture.app.appending(path: update.path).path) == update.hash)
    }

    /// An update replaces a still-thinned file part-way through a restore.
    /// Restore stops before that file, keeps the update, and reports pending.
    @Test func restoreStopsAtAFileUpdatedDuringIt() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try #require(copy.entries.count >= 2)

        var env = idleEnvironment
        var updated: (path: String, hash: String)?
        var swaps = 0
        env.boundary = { name, path in
            guard name == "restore-before-swap" else { return }
            swaps += 1
            guard swaps == 2 else { return }
            let target = copy.app.appending(path: path)
            let incoming = copy.dir.appending(path: "incoming")
            try? Data("version 2".utf8).write(to: incoming)
            guard rename(incoming.path, target.path) == 0, let hash = try? SHA256.hash(file: target.path) else { return }
            updated = (path, hash)
        }

        let result = RestoreOperation.restore(copy.app, environment: env)
        guard case .pending(let reason) = result.outcome else {
            Issue.record("expected pending, got \(result.outcome)")
            return
        }
        let update = try #require(updated)
        #expect(reason.contains("changed"))
        #expect(result.restored.count == 1)
        #expect(try copy.hash(update.path) == update.hash, "the update survives")
        for entry in copy.entries {
            #expect(try SHA256.hash(file: entry.backupPath) == entry.originalHash)
        }
    }

    // MARK: - Locking between processes

    /// Regression: the writer and recovery locked a file beside the app while
    /// restore locked its staging directory, so they did not exclude each
    /// other. Every operation now refuses while another process holds the app.
    @Test func everyOperationWaitsForAnotherProcessHoldingTheApp() throws {
        let fixture = try ThinOperationTests()
        defer { fixture.cleanUp() }
        let originals = try fixture.eligibleHashes()
        let holder = try HeldAppLock(fixture.app)

        let apply = try ThinOperation.applyUnreleased(to: fixture.app, options: fixture.options, environment: idleEnvironment)
        let recover = ThinOperation.recoverUnreleased(fixture.app, environment: idleEnvironment)
        let restore = RestoreOperation.restore(fixture.app, environment: idleEnvironment)
        holder.stop()

        guard case .skipped(let applyReason) = apply else { Issue.record("apply: \(apply)"); return }
        #expect(applyReason.contains("another operation"))
        guard case .pending(let recoverReason) = recover else { Issue.record("recover: \(recover)"); return }
        #expect(recoverReason.contains("another operation"))
        guard case .refused(let restoreReason) = restore.outcome else { Issue.record("restore: \(restore.outcome)"); return }
        #expect(restoreReason.contains("another operation"))
        #expect(try fixture.eligibleHashes() == originals)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.dir.path) == ["Signed.app"])

        // Once the other process exits, the lock is free.
        #expect(try ThinOperation.applyUnreleased(to: fixture.app, options: fixture.options, environment: idleEnvironment) == .committed)
    }

    /// The lock needs only read access to the app: no lock file is created,
    /// so it works where the user cannot write the app or its parent, as for
    /// a root-owned app in `/Applications`, and it still excludes other
    /// processes there. Contention between root and a user needs root, so
    /// it is checked manually by `scripts/phase0/lock-contention.sh`, which
    /// passed in both directions (docs/research/phase0.md).
    @Test func lockWorksWithoutWriteAccessAndExcludesOtherProcesses() throws {
        let fixture = try ThinOperationTests()
        defer {
            chmod(fixture.app.path, 0o755)
            chmod(fixture.dir.path, 0o755)
            fixture.cleanUp()
        }
        try #require(chmod(fixture.app.path, 0o555) == 0 && chmod(fixture.dir.path, 0o555) == 0)

        #expect(try HeldAppLock.otherProcessCanLock(fixture.app))
        let lock = try AppLock(try #require(realPath(fixture.app.path)))
        #expect(try !HeldAppLock.otherProcessCanLock(fixture.app))
        withExtendedLifetime(lock) {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.dir.path) == ["Signed.app"])
    }
}

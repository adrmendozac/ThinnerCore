import Darwin
import Foundation
import Testing
@testable import ThinnerCore

/// Releasing an app's backups: the one explicit way they are discarded.
/// Disposable fixture copies only.
@Suite struct ReleaseTests {
    func entries(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    @Test func publicReleaseIsGated() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        #expect(ReleaseOperation.release(copy.app).outcome == .refused(MutationCommands.releaseBlock))
        #expect(FileManager.default.fileExists(atPath: copy.journalURL.path))
    }

    @Test func deletesEveryBackupAndLeavesTheAppThinned() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let stagingReal = try #require(realPath(copy.staging.path))
        let result = ReleaseOperation.releaseUnreleased(copy.app, environment: idleEnvironment)

        #expect(result.outcome == .released)
        #expect(result.released == [stagingReal])
        #expect(result.releasedBytes == copy.entries.map(\.originalSize).reduce(0, +))
        #expect(result.notes.contains(ReleaseOperation.warning))
        #expect(try entries(in: copy.dir) == [copy.app.lastPathComponent])
        #expect(try copy.allStillThinned())
        #expect(Codesign.verify(copy.app) == nil)
        // Afterwards there is nothing left to restore from.
        if case .nothingToRestore = RestoreOperation.restoreUnreleased(copy.app, environment: idleEnvironment).outcome {} else {
            Issue.record("restore found backups after release")
        }
        #expect(ReleaseOperation.releaseUnreleased(copy.app, environment: idleEnvironment).outcome
            == .nothingToRelease("no backups made by this tool were found next to the app"))
    }

    @Test func waitsForAnUnfinishedOperation() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try copy.editJournal { $0["state"] = "inProgress" }
        let before = try Data(contentsOf: copy.journalURL)

        let outcome = ReleaseOperation.releaseUnreleased(copy.app, environment: idleEnvironment).outcome
        guard case let .pending(reason) = outcome else { Issue.record("\(outcome)"); return }
        #expect(reason.contains("thinnercore recover"))
        #expect(try Data(contentsOf: copy.journalURL) == before)
        #expect(try copy.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.backupPath) })
    }

    @Test func keepsBackupsAfterARecoveryFailure() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try copy.editJournal { $0["state"] = "recoveryFailed" }
        guard case .pending = ReleaseOperation.releaseUnreleased(copy.app, environment: idleEnvironment).outcome else {
            Issue.record("released the backups of a failed recovery"); return
        }
        #expect(FileManager.default.fileExists(atPath: copy.journalURL.path))
    }

    @Test(arguments: ["inProgress", "pending"])
    func waitsForAnUnfinishedRestore(_ state: String) throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        var record = RestoreOperation.RestoreRecord(operationID: "x", runID: "y")
        record.state = try #require(.init(rawValue: state))
        try JSONEncoder().encode(record).write(to: copy.staging.appending(path: RestoreOperation.RestoreRecord.fileName))

        let outcome = ReleaseOperation.releaseUnreleased(copy.app, environment: idleEnvironment).outcome
        guard case let .pending(reason) = outcome else { Issue.record("\(outcome)"); return }
        #expect(reason.contains("thinnercore restore"))
        #expect(FileManager.default.fileExists(atPath: copy.journalURL.path))
    }

    /// Regression: a restore that failed verification may leave the app
    /// part restored, and release deleted the backups it still needs. A
    /// later restore that verifies the app lifts the hold.
    @Test func keepsBackupsAfterAFailedRestoreUntilARestoreSucceeds() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        var failing = idleEnvironment
        failing.verify = { _ in "injected verification failure" }
        #expect(RestoreOperation.restoreUnreleased(copy.app, environment: failing).outcome.exitCode == 4)
        #expect(try copy.restoreRecord()["state"] as? String == "recoveryFailed")

        let held = ReleaseOperation.releaseUnreleased(copy.app, environment: idleEnvironment).outcome
        guard case let .pending(reason) = held else { Issue.record("released after a failed restore: \(held)"); return }
        #expect(reason.contains("failed verification"))
        #expect(copy.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.backupPath) })

        // Every file is already original, so this run only verifies the app
        // and closes the failed record.
        #expect(RestoreOperation.restoreUnreleased(copy.app, environment: idleEnvironment).outcome.exitCode == 0)
        #expect(try copy.restoreRecord()["state"] as? String == "restored")
        #expect(ReleaseOperation.releaseUnreleased(copy.app, environment: idleEnvironment).outcome == .released)
    }

    /// Regression (CodeRabbit review, 2026-11-10): release checked the
    /// restore records before locking the backup sets, so a restore that
    /// failed in between went unnoticed and its backups were deleted. The
    /// failure is written during the first check, through the euid seam,
    /// which runs after each set's record has been read.
    @Test func rechecksTheRecordsAfterLockingTheSets() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        var env = idleEnvironment
        var written = false
        env.euid = {
            if !written {
                written = true
                var record = RestoreOperation.RestoreRecord(operationID: "x", runID: "y")
                record.state = .recoveryFailed
                try? JSONEncoder().encode(record).write(to: copy.staging.appending(path: RestoreOperation.RestoreRecord.fileName))
            }
            return geteuid()
        }
        let outcome = ReleaseOperation.releaseUnreleased(copy.app, environment: env).outcome
        guard case let .pending(reason) = outcome else { Issue.record("released after a restore failed: \(outcome)"); return }
        #expect(reason.contains("failed verification"))
        #expect(written)
        #expect(copy.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.backupPath) })
    }

    @Test func releasesAfterAFinishedRestore() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        #expect(RestoreOperation.restoreUnreleased(copy.app, environment: idleEnvironment).outcome == .restored)
        let originals = try copy.entries.map { try copy.hash($0.relativePath) }

        #expect(ReleaseOperation.releaseUnreleased(copy.app, environment: idleEnvironment).outcome == .released)
        #expect(try copy.entries.map { try copy.hash($0.relativePath) } == originals)
        #expect(try entries(in: copy.dir) == [copy.app.lastPathComponent])
    }

    @Test func waitsForAnotherProcessHoldingTheApp() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let holder = try HeldAppLock(copy.app)
        let outcome = ReleaseOperation.releaseUnreleased(copy.app, environment: idleEnvironment).outcome
        holder.stop()

        guard case let .refused(reason) = outcome else { Issue.record("\(outcome)"); return }
        #expect(reason.contains("another operation"))
        #expect(FileManager.default.fileExists(atPath: copy.journalURL.path))
    }

    /// A record that cannot be read might be an unfinished operation for
    /// this app, so nothing is deleted.
    @Test func refusesAnUnreadableRecord() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let other = copy.dir.appending(path: ".thinner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try Data("not json".utf8).write(to: other.appending(path: Journal.fileName))

        guard case .refused = ReleaseOperation.releaseUnreleased(copy.app, environment: idleEnvironment).outcome else {
            Issue.record("released despite an unreadable record"); return
        }
        #expect(FileManager.default.fileExists(atPath: copy.journalURL.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func leavesASiblingAppsBackups() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let sibling = copy.dir.appending(path: ".thinner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        var journal = Journal(operationID: UUID().uuidString, bundlePath: copy.dir.appending(path: "Other.app").path,
                              startedAt: ISO8601DateFormatter().string(from: Date()))
        journal.state = .committed
        try JSONEncoder().encode(journal).write(to: sibling.appending(path: Journal.fileName))

        #expect(ReleaseOperation.releaseUnreleased(copy.app, environment: idleEnvironment).outcome == .released)
        #expect(!FileManager.default.fileExists(atPath: copy.staging.path))
        #expect(FileManager.default.fileExists(atPath: sibling.appending(path: Journal.fileName).path))
    }

    /// If taking the set out of use cannot be made durable, it is put back
    /// rather than deleted: a crash could otherwise return it half deleted.
    @Test func keepsTheSetWhenTheRenameCannotBeFlushed() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        var env = idleEnvironment
        env.flushDirectory = { _ in "simulated flush failure" }

        let outcome = ReleaseOperation.releaseUnreleased(copy.app, environment: env).outcome
        guard case let .refused(reason) = outcome else { Issue.record("\(outcome)"); return }
        #expect(reason.contains("simulated flush failure"))
        #expect(try copy.entries.allSatisfy { try SHA256.hash(file: $0.backupPath) == $0.originalHash })
        #expect(try entries(in: copy.dir).filter(ReleaseOperation.isReleasedName).isEmpty)
        #expect(RestoreOperation.restoreUnreleased(copy.app, environment: idleEnvironment).outcome == .restored)
    }

    /// A release cut short after taking the set out of use is finished by
    /// the next one.
    @Test func finishesAnEarlierReleaseCutShort() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let released = copy.dir.appending(path: ReleaseOperation.releasedPrefix + copy.staging.lastPathComponent.dropFirst(".thinner-".count))
        try #require(rename(copy.staging.path, released.path) == 0)

        let result = ReleaseOperation.releaseUnreleased(copy.app, environment: idleEnvironment)
        #expect(result.outcome == .nothingToRelease("no backups made by this tool were found next to the app"))
        #expect(result.notes.contains { $0.contains("finished deleting") })
        #expect(try entries(in: copy.dir) == [copy.app.lastPathComponent])
    }

    @Test func refusesASetAnotherUserMade() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        var env = idleEnvironment
        env.euid = { 0 }

        let outcome = ReleaseOperation.releaseUnreleased(copy.app, environment: env).outcome
        guard case let .refused(reason) = outcome else { Issue.record("\(outcome)"); return }
        #expect(reason.contains("without sudo") && reason.contains("thinnercore release"))
        #expect(try entries(in: copy.dir) == [copy.staging.lastPathComponent, copy.app.lastPathComponent].sorted())
    }
}

import Foundation
import Testing
@testable import ThinnerCore

/// No process uses the app, visibility is complete; codesign is real.
var idleEnvironment: RestoreOperation.Environment {
    RestoreOperation.Environment(usage: { _ throws(Problem) in BundleUsage.Result() })
}

/// `codesign --verify` fails on the given calls (1-based) and is real otherwise.
func verifyFailing(on failing: Set<Int>) -> (URL) -> String? {
    let calls = Counter()
    return { url in
        calls.value += 1
        return failing.contains(calls.value) ? "simulated verification failure" : Codesign.verify(url)
    }
}

/// Recovery of interrupted operations. Each copy is thinned the way the writer
/// thins, then its journal is set back to `inProgress`, as a crash would leave it.
@Suite struct RecoveryTests {
    func interrupted(_ copy: ThinnedCopy) throws {
        try copy.editJournal { $0["state"] = "inProgress" }
    }

    func journalState(_ copy: ThinnedCopy) throws -> String? {
        try (JSONSerialization.jsonObject(with: Data(contentsOf: copy.journalURL)) as? [String: Any])?["state"] as? String
    }

    @Test func publicRecoverIsGated() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try interrupted(copy)
        #expect(ThinOperation.recover(copy.app) == .skipped(reason: MutationCommands.releaseBlock))
        #expect(try copy.allStillThinned())
        #expect(try journalState(copy) == "inProgress")
    }

    @Test func commitsASwappedOperationThatVerifies() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try interrupted(copy)

        #expect(ThinOperation.recoverUnreleased(copy.app, environment: idleEnvironment) == .committed)
        #expect(try copy.allStillThinned())
        #expect(try journalState(copy) == "committed")
    }

    /// Regression: a writer that stopped after replacing some files left the
    /// rest unthinned, and recovery marked the whole operation committed.
    @Test func rollsBackAPartlyReplacedOperation() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try #require(copy.entries.count >= 2)
        try interrupted(copy)
        let unreached = try #require(copy.entries.first)
        let target = copy.app.appending(path: unreached.relativePath)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: URL(filePath: unreached.backupPath), to: target)

        let outcome = ThinOperation.recoverUnreleased(copy.app, environment: idleEnvironment)
        guard case .rolledBack(let reason) = outcome else {
            Issue.record("expected rolledBack, got \(outcome)")
            return
        }
        #expect(reason.contains("rerun"))
        for entry in copy.entries {
            #expect(try copy.hash(entry.relativePath) == entry.originalHash)
            #expect(try SHA256.hash(file: entry.backupPath) == entry.originalHash, "the backup survives")
        }
        #expect(Codesign.verify(copy.app) == nil)
        #expect(try journalState(copy) == "rolledBack")
    }

    /// Regression: rollback renamed each backup into the app, consuming it.
    @Test func rollsBackByCloningAndKeepsEveryBackup() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try interrupted(copy)
        var env = idleEnvironment
        env.verify = verifyFailing(on: [1])

        let outcome = ThinOperation.recoverUnreleased(copy.app, environment: env)
        guard case .rolledBack = outcome else {
            Issue.record("expected rolledBack, got \(outcome)")
            return
        }
        for entry in copy.entries {
            #expect(try copy.hash(entry.relativePath) == entry.originalHash)
            #expect(try SHA256.hash(file: entry.backupPath) == entry.originalHash, "the backup survives")
        }
        #expect(Codesign.verify(copy.app) == nil)
        #expect(try journalState(copy) == "rolledBack")
    }

    /// Regression: a journal path with `..` was joined onto the app and
    /// renamed over, so a malformed journal could write outside the app.
    @Test func refusesAJournalPathOutsideTheApp() throws {
        let copy = try ThinnedCopy(relativePathOverride: "../escape")
        defer { copy.remove() }
        try interrupted(copy)
        let victim = copy.dir.appending(path: "escape")
        try Data("victim".utf8).write(to: victim)
        var env = idleEnvironment
        env.verify = { _ in "simulated verification failure" }

        let outcome = ThinOperation.recoverUnreleased(copy.app, environment: env)
        guard case .recoveryFailed(let reason) = outcome else {
            Issue.record("expected recoveryFailed, got \(outcome)")
            return
        }
        #expect(reason.contains("unsafe path"))
        #expect(try Data(contentsOf: victim) == Data("victim".utf8))
        // The journal's paths are overridden, so check the app directly.
        let exe = copy.app.appending(path: "Contents/MacOS/Signed").path
        #expect(try Shell.run("/usr/bin/lipo", "-archs", exe).output.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64")
    }

    /// Regression: a journal's backup path was renamed into the app unchecked.
    @Test func refusesABackupOutsideItsStagingDirectory() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let outside = copy.dir.appending(path: "elsewhere")
        let entry = try #require(copy.entries.first)
        try FileManager.default.copyItem(at: URL(filePath: entry.backupPath), to: outside)
        try copy.editJournal { journal in
            var entries = journal["entries"] as! [[String: Any]]
            entries[0]["backupPath"] = outside.path
            journal["entries"] = entries
            journal["state"] = "inProgress"
        }
        var env = idleEnvironment
        env.verify = verifyFailing(on: [1])

        let outcome = ThinOperation.recoverUnreleased(copy.app, environment: env)
        guard case .recoveryFailed(let reason) = outcome else {
            Issue.record("expected recoveryFailed, got \(outcome)")
            return
        }
        #expect(reason.contains("not inside"))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(try copy.allStillThinned())
        #expect(try journalState(copy) == "recoveryFailed")
    }

    @Test func leavesAFileSomethingElseChanged() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try interrupted(copy)
        let entry = try #require(copy.entries.first)
        let target = copy.app.appending(path: entry.relativePath)
        try Data("updated".utf8).write(to: target)

        let outcome = ThinOperation.recoverUnreleased(copy.app, environment: idleEnvironment)
        guard case .recoveryFailed(let reason) = outcome else {
            Issue.record("expected recoveryFailed, got \(outcome)")
            return
        }
        #expect(reason.contains("something else changed"))
        #expect(try Data(contentsOf: target) == Data("updated".utf8))
        #expect(try SHA256.hash(file: entry.backupPath) == entry.originalHash)
    }

    @Test func refusesAnAppUpdatedSinceTheOperation() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try interrupted(copy)
        let plist = copy.app.appending(path: "Contents/Info.plist")
        var info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        info["CFBundleShortVersionString"] = "2.0"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)

        let outcome = ThinOperation.recoverUnreleased(copy.app, environment: idleEnvironment)
        guard case .recoveryFailed(let reason) = outcome else {
            Issue.record("expected recoveryFailed, got \(outcome)")
            return
        }
        #expect(reason.contains("app changed"))
        #expect(try copy.allStillThinned())
    }

    @Test func refusesAJournalWithoutAppIdentity() throws {
        let copy = try ThinnedCopy(recordIdentity: false)
        defer { copy.remove() }
        try interrupted(copy)
        let outcome = ThinOperation.recoverUnreleased(copy.app, environment: idleEnvironment)
        guard case .recoveryFailed(let reason) = outcome else {
            Issue.record("expected recoveryFailed, got \(outcome)")
            return
        }
        #expect(reason.contains("does not record which version"))
        #expect(try copy.allStillThinned())
    }

    /// Regression: incomplete process visibility was treated as idle.
    @Test func waitsWhileProcessVisibilityIsIncomplete() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try interrupted(copy)
        var env = idleEnvironment
        env.usage = { _ throws(Problem) in BundleUsage.Result(uninspectable: 1) }

        let outcome = ThinOperation.recoverUnreleased(copy.app, environment: env)
        guard case .pending(let reason) = outcome else {
            Issue.record("expected pending, got \(outcome)")
            return
        }
        #expect(reason.contains("could not be inspected"))
        #expect(try journalState(copy) == "inProgress")
    }

    /// Regression: recovery and restore took different locks.
    @Test func waitsWhileAnotherOperationHoldsTheApp() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try interrupted(copy)
        let lock = try AppLock(try #require(realPath(copy.app.path)))

        let outcome = ThinOperation.recoverUnreleased(copy.app, environment: idleEnvironment)
        withExtendedLifetime(lock) {}
        guard case .pending(let reason) = outcome else {
            Issue.record("expected pending, got \(outcome)")
            return
        }
        #expect(reason.contains("another operation"))
        #expect(try journalState(copy) == "inProgress")
    }

    @Test func restoreAlsoWaitsForTheAppLock() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let lock = try AppLock(try #require(realPath(copy.app.path)))
        let result = RestoreOperation.restoreUnreleased(copy.app, environment: idleEnvironment)
        withExtendedLifetime(lock) {}
        guard case .refused(let reason) = result.outcome else {
            Issue.record("expected refused, got \(result.outcome)")
            return
        }
        #expect(reason.contains("another operation"))
        #expect(try copy.allStillThinned())
    }

    @Test func nothingToRecover() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        guard case .skipped = ThinOperation.recoverUnreleased(copy.app, environment: idleEnvironment) else {
            Issue.record("expected skipped")
            return
        }
        #expect(try copy.allStillThinned())
    }
}

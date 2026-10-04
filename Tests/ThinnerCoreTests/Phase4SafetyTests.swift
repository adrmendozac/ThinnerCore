import Darwin
import Foundation
import Testing
import XCTest
@testable import ThinnerCore

/// A separate xctest process exits inside the production transaction, without
/// unwinding Swift frames, rolling back, or running defer cleanup.
final class Phase4CrashWorker: XCTestCase {
    func testCrashBoundary() throws {
        let vars = ProcessInfo.processInfo.environment
        guard let path = vars["THINNER_CRASH_APP"], let boundary = vars["THINNER_CRASH_BOUNDARY"] else { return }
        let app = URL(filePath: path)
        var env = idleEnvironment
        let pieces = boundary.split(separator: "#")
        let point = String(pieces[0])
        let occurrence = pieces.count > 1 ? Int(pieces[1])! : 1
        var seen = 0
        env.boundary = { name, _ in
            if name == point { seen += 1; if seen == occurrence { _exit(77) } }
        }
        if vars["THINNER_CRASH_MODE"] == "rollback" { env.verify = verifyFailing(on: [2]) }
        if vars["THINNER_CRASH_MODE"] == "restore" {
            _ = RestoreOperation.restoreUnreleased(app, environment: env)
        } else {
            let prefs = app.deletingLastPathComponent().appending(path: "absent.plist")
            _ = try ThinOperation.applyUnreleased(to: app, options: ScanOptions(launchServicesPreferences: prefs), environment: env)
        }
        XCTFail("The transaction never reached \(boundary)")
    }
}

@Suite(.serialized) struct Phase4SafetyTests {
    @Test(arguments: ["operation-journal", "verified", "committed"] +
          ["original-hashed", "backup-verified", "lipo-written", "temp-verified", "ready-journal", "swapped", "directory-flushed", "replacement-recorded"].flatMap { point in (1...3).map { "\(point)#\($0)" } })
    func writerSurvivesProcessExit(_ boundary: String) throws {
        let fixture = try ThinOperationTests()
        defer { fixture.cleanUp() }
        let originals = try fixture.eligibleHashes()
        try crash(app: fixture.app, mode: "apply", at: boundary)
        let outcome = ThinOperation.recoverUnreleased(fixture.app, environment: idleEnvironment)
        switch outcome {
        case .committed, .rolledBack, .skipped: break
        default: Issue.record("recovery after \(boundary): \(outcome)")
        }
        #expect(Codesign.verify(fixture.app) == nil)
        let sets = try RestoreOperation.findBackupSets(for: try #require(realPath(fixture.app.path)))
        #expect(sets.count == 1)
        for set in sets {
            #expect(set.journal.state == .committed || set.journal.state == .rolledBack)
            for entry in set.journal.entries {
                #expect(try SHA256.hash(file: entry.backupPath) == entry.originalHash)
            }
        }
        let restored = RestoreOperation.restoreUnreleased(fixture.app, environment: idleEnvironment)
        #expect(restored.outcome.exitCode == 0)
        #expect(try fixture.eligibleHashes() == originals)
    }

    @Test(arguments: ["restore-journal", "restore-verified", "restore-committed"] +
          ["restore-prepared", "restore-before-swap", "restore-swapped", "restore-directory-flushed", "restore-recorded"].flatMap { point in (1...3).map { "\(point)#\($0)" } })
    func restoreSurvivesProcessExit(_ boundary: String) throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try crash(app: copy.app, mode: "restore", at: boundary)
        let result = RestoreOperation.restoreUnreleased(copy.app, environment: idleEnvironment)
        #expect(result.outcome.exitCode == 0)
        #expect(Codesign.verify(copy.app) == nil)
        for entry in copy.entries {
            #expect(try copy.hash(entry.relativePath) == entry.originalHash)
            #expect(try SHA256.hash(file: entry.backupPath) == entry.originalHash)
        }
    }

    @Test(arguments: ["restore-journal", "restore-prepared#2", "restore-swapped#1", "restore-swapped#2", "restore-recorded#2", "restore-verified"])
    func rollbackSurvivesProcessExit(_ boundary: String) throws {
        let fixture = try ThinOperationTests()
        defer { fixture.cleanUp() }
        let originals = try fixture.eligibleHashes()
        try crash(app: fixture.app, mode: "rollback", at: boundary)
        let outcome = ThinOperation.recoverUnreleased(fixture.app, environment: idleEnvironment)
        #expect(outcome == .committed || { if case .rolledBack = outcome { return true }; return false }())
        #expect(RestoreOperation.restoreUnreleased(fixture.app, environment: idleEnvironment).outcome.exitCode == 0)
        #expect(try fixture.eligibleHashes() == originals)
        for entry in try fixture.stagingJournal().entries {
            #expect(try SHA256.hash(file: entry.backupPath) == entry.originalHash)
        }
    }

    private func crash(app: URL, mode: String, at boundary: String) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "ThinnerCoreTests.Phase4CrashWorker/testCrashBoundary", Bundle(for: Phase4CrashWorker.self).bundlePath]
        var vars = ProcessInfo.processInfo.environment
        vars["THINNER_CRASH_APP"] = app.path
        vars["THINNER_CRASH_MODE"] = mode
        vars["THINNER_CRASH_BOUNDARY"] = boundary
        process.environment = vars
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 77, "\(boundary): \(String(decoding: output, as: UTF8.self))")
    }

    @Test func restoreRefusesIncompleteVisibilityBeforeAndBetweenSwaps() throws {
        for stopAt in [1, 2, 3] {
            let copy = try ThinnedCopy()
            defer { copy.remove() }
            var env = idleEnvironment
            var calls = 0
            env.usage = { _ throws(Problem) in
                calls += 1
                return BundleUsage.Result(uninspectable: calls >= stopAt ? 1 : 0)
            }
            let result = RestoreOperation.restoreUnreleased(copy.app, environment: env)
            #expect(result.outcome.exitCode == (stopAt <= 2 ? 1 : 3))
            #expect(result.restored.count == max(0, stopAt - 2))
            if stopAt <= 2 { #expect(try copy.allStillThinned()) }
            #expect(RestoreOperation.restoreUnreleased(copy.app, environment: idleEnvironment).outcome == .restored)
        }
    }

    @Test func writerDetectsByteChangesWithUnchangedIdentity() throws {
        let fixture = try ThinOperationTests()
        defer { fixture.cleanUp() }
        var changedPath: String?
        var changedHash: String?
        var changeError: String?
        var env = idleEnvironment
        env.boundary = { name, path in
            guard name == "ready-journal", changedPath == nil else { return }
            let target = fixture.app.appending(path: path).path
            changedPath = target
            let fd = open(target, O_RDWR)
            defer { close(fd) }
            var info = stat()
            guard fd >= 0, fstat(fd, &info) == 0 else { changeError = "stat"; return }
            var byte: UInt8 = 0
            guard pread(fd, &byte, 1, info.st_size - 1) == 1 else { changeError = "read"; return }
            byte ^= 1
            guard pwrite(fd, &byte, 1, info.st_size - 1) == 1 else { changeError = "write"; return }
            var times = [info.st_atimespec, info.st_mtimespec]
            guard futimens(fd, &times) == 0 else { changeError = "mtime"; return }
            changedHash = try? SHA256.hash(file: target)
        }
        let result = try ThinOperation.applyUnreleased(to: fixture.app, options: fixture.options, environment: env)
        #expect(changeError == nil)
        #expect(result != .committed)
        let path = try #require(changedPath)
        #expect(try SHA256.hash(file: path) == changedHash)
        #expect(try fixture.stagingJournal().entries.allSatisfy { $0.state != .replaced && $0.state != .committed })
    }

    @Test func applyResolvesPendingBeforeNewOperation() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try copy.editJournal { $0["state"] = "inProgress" }
        let options = ScanOptions(launchServicesPreferences: copy.dir.appending(path: "absent.plist"))
        _ = try ThinOperation.applyUnreleased(to: copy.app, options: options, environment: idleEnvironment)
        #expect(try Journal.load(from: copy.journalURL)?.state == .committed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: copy.dir.path).filter(RestoreOperation.isStagingName).count == 1)
    }

    @Test func applyStopsAtUnresolvedPendingOperation() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try copy.editJournal { object in
            object["state"] = "inProgress"
            var entries = object["entries"] as! [[String: Any]]
            entries[0]["thinnedHash"] = "does-not-match"
            object["entries"] = entries
        }
        let outcome = try ThinOperation.applyUnreleased(to: copy.app,
            options: ScanOptions(launchServicesPreferences: copy.dir.appending(path: "absent.plist")), environment: idleEnvironment)
        guard case .recoveryFailed = outcome else { Issue.record("expected recovery failure, got \(outcome)"); return }
        #expect(try copy.allStillThinned())
        #expect(try FileManager.default.contentsOfDirectory(atPath: copy.dir.path).filter(RestoreOperation.isStagingName).count == 1)
    }

    @Test func rollbackStopsWhenVisibilityBecomesIncomplete() throws {
        let fixture = try ThinOperationTests()
        defer { fixture.cleanUp() }
        var env = idleEnvironment
        var blocked = false
        env.verify = verifyFailing(on: [2])
        env.boundary = { name, _ in if name == "restore-swapped" { blocked = true } }
        env.usage = { _ throws(Problem) in BundleUsage.Result(uninspectable: blocked ? 1 : 0) }
        let outcome = try ThinOperation.applyUnreleased(to: fixture.app, options: fixture.options, environment: env)
        guard case .pending = outcome else { Issue.record("expected pending, got \(outcome)"); return }
        let journal = try fixture.stagingJournal()
        #expect(journal.state == .inProgress)
        #expect(journal.entries.filter { $0.state == .restored }.count == 1)
        for entry in journal.entries { #expect(try SHA256.hash(file: entry.backupPath) == entry.originalHash) }
        _ = ThinOperation.recoverUnreleased(fixture.app, environment: idleEnvironment)
        #expect(Codesign.verify(fixture.app) == nil)
    }

    @Test func retryAfterLastRestoreSwapStillRequiresFlushAndVerification() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        var env = idleEnvironment
        var calls = 0
        env.flushDirectory = { _ in
            calls += 1
            return calls == copy.entries.count ? "last directory flush failed" : nil
        }
        #expect(RestoreOperation.restoreUnreleased(copy.app, environment: env).outcome.exitCode == 3)
        #expect(try copy.restoreRecord()["state"] as? String == "pending")
        var retry = idleEnvironment
        retry.flushDirectory = { _ in "still failing" }
        #expect(RestoreOperation.restoreUnreleased(copy.app, environment: retry).outcome.exitCode == 3)
        retry = idleEnvironment
        retry.verify = { _ in "invalid restored signature" }
        #expect(RestoreOperation.restoreUnreleased(copy.app, environment: retry).outcome.exitCode == 4)
        #expect(RestoreOperation.restoreUnreleased(copy.app, environment: idleEnvironment).outcome.exitCode == 0)
        // Regression: the successful retry left the record pending.
        let record = try copy.restoreRecord()
        #expect(record["state"] as? String == "restored")
        #expect((record["files"] as? [[String: Any]])?.allSatisfy { $0["state"] as? String == "restored" } == true)
    }

    @Test func writerDirectoryFlushFailureKeepsBackupsAndCannotCommit() throws {
        let fixture = try ThinOperationTests()
        defer { fixture.cleanUp() }
        var env = idleEnvironment
        env.flushDirectory = { _ in "injected writer flush failure" }
        let outcome = try ThinOperation.applyUnreleased(to: fixture.app, options: fixture.options, environment: env)
        #expect(outcome != .committed)
        let journal = try fixture.stagingJournal()
        #expect(journal.state != .committed)
        for entry in journal.entries { #expect(try SHA256.hash(file: entry.backupPath) == entry.originalHash) }
        _ = ThinOperation.recoverUnreleased(fixture.app, environment: idleEnvironment)
        #expect(Codesign.verify(fixture.app) == nil)
    }

    @Test func failedDirectoryFlushNeverReportsSuccess() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        var env = idleEnvironment
        env.flushDirectory = { _ in "injected I/O failure" }
        let result = RestoreOperation.restoreUnreleased(copy.app, environment: env)
        #expect(result.outcome.exitCode == 3)
        #expect(copy.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.backupPath) })
        #expect(RestoreOperation.restoreUnreleased(copy.app, environment: idleEnvironment).outcome.exitCode == 0)
        // Regression: the successful retry left the record pending.
        let record = try copy.restoreRecord()
        #expect(record["state"] as? String == "restored")
        #expect((record["files"] as? [[String: Any]])?.allSatisfy { $0["state"] as? String == "restored" } == true)
    }
}

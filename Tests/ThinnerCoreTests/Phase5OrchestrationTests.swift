import Foundation
import Testing
@testable import ThinnerCore

@Suite struct Phase5OrchestrationTests {
    private func options() -> ScanOptions {
        ScanOptions(launchServicesPreferences: FileManager.default.temporaryDirectory
            .appending(path: "absent-\(UUID()).plist"))
    }

    @Test func batchUsesWriterForEligibleFixtureApps() throws {
        let root = try Fixtures.url("bundles")
        var called: [String] = []
        let report = MutationCommands.applyUnreleased(root, options: options()) { app, _ in
            called.append(app.lastPathComponent)
            return .committed
        }
        #expect(report.exitCode == 0)
        #expect(called.sorted() == ["Electron.app", "Nested.app", "Signed.app"])
        #expect(report.apps.allSatisfy { $0.outcome == .committed })
    }

    @Test func exclusionNeverCallsWriter() throws {
        let app = try Fixtures.url("bundles/Signed.app")
        var called = false
        let report = MutationCommands.applyUnreleased(app,
            options: ScanOptions(excludes: [app], launchServicesPreferences: FileManager.default.temporaryDirectory
                .appending(path: "absent-\(UUID()).plist"))) { _, _ in
            called = true
            return .committed
        }
        #expect(!called)
        #expect(report.apps.first?.outcome == .skipped)
        #expect(report.exitCode == 0)
    }

    @Test func pendingJournalStopsBatchBeforeWriter() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "phase5-pending-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Fixture.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        let stage = root.appending(path: ".thinner-00000000-0000-0000-0000-000000000005")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let journal = Journal(operationID: "test", bundlePath: app.path,
                              bundleIdentifier: "fixture", startedAt: "test")
        try JSONEncoder().encode(journal).write(to: stage.appending(path: Journal.fileName))

        var called = false
        let report = MutationCommands.applyUnreleased(root, options: options()) { _, _ in
            called = true
            return .committed
        }
        #expect(!called)
        #expect(report.apps.contains { $0.path == app.path && $0.outcome == .recoveryPending })
        #expect(report.exitCode == 3)
    }

    @Test func invalidBundleIsARefusalRatherThanAPolicySkip() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "phase5-invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Broken.app/Contents"),
                                                withIntermediateDirectories: true)
        var called = false
        let report = MutationCommands.applyUnreleased(root, options: options()) { _, _ in
            called = true
            return .committed
        }
        #expect(!called)
        #expect(report.apps.first?.outcome == .refused)
        #expect(report.exitCode == 1)
    }

    /// A disposable copy of the fixture apps, so a test can leave journals
    /// beside them without touching the shared fixtures.
    private func copiedBundles() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "phase5-copy-\(UUID())")
        try #require(try Shell.run("/usr/bin/ditto", try Fixtures.url("bundles").path, root.path).status == 0)
        return root
    }

    private func writeJournal(for app: URL, beside root: URL, id: Int) throws {
        let stage = root.appending(path: String(format: ".thinner-00000000-0000-0000-0000-%012d", id))
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let journal = Journal(operationID: "test", bundlePath: try #require(realPath(app.path)),
                              bundleIdentifier: "fixture", startedAt: "test")
        try JSONEncoder().encode(journal).write(to: stage.appending(path: Journal.fileName))
    }

    @Test func writerFailureAfterItsJournalReportsPendingAndStopsBatch() throws {
        let root = try copiedBundles()
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let fail: MutationCommands.ApplyOperation = { app, _ throws(Problem) in
            calls += 1
            try? writeJournal(for: app, beside: root, id: 6)
            throw Problem("injected journal write failure")
        }
        let report = MutationCommands.applyUnreleased(root, options: options(), operation: fail)
        #expect(calls == 1)
        #expect(report.apps.first?.outcome == .recoveryPending)
        #expect(report.exitCode == 3)
        #expect(report.apps.dropFirst().allSatisfy { $0.outcome == .refused })
    }

    /// Regression: a preflight failure before any journal (low disk space,
    /// for example) was reported as recovery pending and stopped the batch.
    @Test func writerFailureBeforeAnyJournalIsARefusal() throws {
        let root = try copiedBundles()
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let fail: MutationCommands.ApplyOperation = { _, _ throws(Problem) in
            calls += 1
            throw Problem("insufficient free space")
        }
        let report = MutationCommands.applyUnreleased(root, options: options(), operation: fail)
        #expect(calls == 3, "the batch continues: nothing was written")
        #expect(report.apps.allSatisfy { $0.outcome == .refused })
        #expect(report.exitCode == 1)
    }

    /// Regression: the writer records the real path (/private/var/...), the
    /// scan the given one (/var/...), so a pending app was listed twice.
    @Test func pendingAppIsListedOnceWhateverItsPathSpelling() throws {
        let root = try copiedBundles()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Signed.app")
        try #require(realPath(app.path) != app.path, "needs a temporary directory reached through a symlink")
        try writeJournal(for: app, beside: root, id: 7)

        let report = MutationCommands.applyUnreleased(root, options: options()) { _, _ in .committed }
        let mentions = report.apps.filter { (realPath($0.path) ?? $0.path) == realPath(app.path) }
        #expect(mentions.map(\.outcome) == [.recoveryPending])
    }
}

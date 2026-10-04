import Foundation
import Testing
@testable import ThinnerCore

@Suite struct MutationCommandsTests {
    @Test func exitCodesHaveDefinedPrecedence() {
        let outcomes: [MutationReport.Outcome] = [.committed, .skipped, .nothingToDo, .refused, .rolledBack, .recoveryPending, .recoveryFailed]
        #expect(outcomes.map(\.exitCode) == [0, 0, 0, 1, 1, 3, 4])
        let report = MutationReport(command: "apply", apps: outcomes.map {
            .init(path: "fixture.app", outcome: $0, reason: "test")
        }, problems: ["test"])
        #expect(report.exitCode == 4)
    }

    @Test func journalSnapshotDoesNotWriteOrFollowSymlinks() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pending-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stage = dir.appending(path: ".thinner-00000000-0000-0000-0000-000000000001")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let journalURL = stage.appending(path: "journal.json")
        let journal = Journal(operationID: "test", bundlePath: dir.appending(path: "Fixture.app").path,
                              bundleIdentifier: "test", startedAt: "test")
        let bytes = try JSONEncoder().encode(journal)
        try bytes.write(to: journalURL)
        let snapshot = PendingOperations.read(root: dir, apps: [])
        #expect(snapshot.operations.count == 1)
        #expect(snapshot.problems.isEmpty)
        #expect(try Data(contentsOf: journalURL) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: stage.path) == ["journal.json"])
        let outside = dir.appending(path: "outside.json")
        try bytes.write(to: outside)
        try FileManager.default.removeItem(at: journalURL)
        try FileManager.default.createSymbolicLink(at: journalURL, withDestinationURL: outside)
        let unsafe = PendingOperations.read(root: dir, apps: [])
        #expect(unsafe.operations.isEmpty)
        #expect(!unsafe.problems.isEmpty)
    }

    @Test func applyRefusesAnOpenBundleFile() throws {
        let app = try Fixtures.url("bundles/Signed.app")
        let executable = app.appending(path: "Contents/MacOS/Signed")
        let handle = try FileHandle(forReadingFrom: executable)
        defer { try? handle.close() }
        let prefs = FileManager.default.temporaryDirectory.appending(path: "absent-\(UUID()).plist")
        let report = MutationCommands.apply(app, options: ScanOptions(launchServicesPreferences: prefs))
        #expect(report.apps.first?.outcome == .refused)
        #expect(report.apps.first?.reason.contains("process") == true)
        #expect(report.exitCode == 1)
    }

    @Test func applyReportsExclusionsAndRemainsGated() throws {
        let app = try Fixtures.url("bundles/Signed.app")
        let report = MutationCommands.apply(app, options: ScanOptions(excludes: [app]))
        #expect(report.apps.first?.outcome == .skipped)
        #expect(report.apps.first?.reason.contains("excluded") == true)
        #expect(report.exitCode == 1)
        #expect(report.problems.contains(MutationCommands.releaseBlock))
    }
}

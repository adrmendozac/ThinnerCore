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

    /// Regression: text reports printed paths and reasons with raw terminal
    /// controls, so a crafted path or journal could rewrite the display.
    @Test func textEscapesTerminalControls() throws {
        let report = MutationReport(command: "restore", apps: [
            .init(path: "Evil\u{1B}[2J.app", outcome: .refused, reason: "bad\rname")
        ], problems: ["journal \u{9B}31m"])
        #expect(report.text == "Evil\\u{1B}[2J.app: refused — bad\\u{0D}name\njournal \\u{9B}31m")
        #expect(try report.json().contains("\\u001b[2J"), "JSON keeps the original string")
    }

    /// Regression: recover on a directory inspected only the directory
    /// itself, so a journal beside a nested app was never reported.
    @Test func recoverReportFindsJournalsBesideNestedApps() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "nested-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appending(path: "Vendor/Tools")
        try FileManager.default.createDirectory(at: folder.appending(path: "Fixture.app/Contents"), withIntermediateDirectories: true)
        let stage = folder.appending(path: ".thinner-00000000-0000-0000-0000-000000000003")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let journal = Journal(operationID: "test", bundlePath: folder.appending(path: "Fixture.app").path,
                              bundleIdentifier: "test", startedAt: "test")
        try JSONEncoder().encode(journal).write(to: stage.appending(path: "journal.json"))

        let report = MutationCommands.unavailable("recover", root: dir)
        #expect(report.apps.map(\.outcome) == [.recoveryPending])
        #expect(report.apps.first?.path == journal.bundlePath)
        #expect(report.exitCode == 3)
    }

    /// Regression: a single-app report searched the app's parent directory
    /// and reported every journal there, including a sibling app's.
    @Test func singleAppReportIgnoresASiblingsJournal() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sibling-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["Mine.app", "Sibling.app"] {
            try FileManager.default.createDirectory(at: dir.appending(path: "\(name)/Contents"), withIntermediateDirectories: true)
        }
        let stage = dir.appending(path: ".thinner-00000000-0000-0000-0000-000000000004")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let journal = Journal(operationID: "test", bundlePath: dir.appending(path: "Sibling.app").path,
                              bundleIdentifier: "test", startedAt: "test")
        try JSONEncoder().encode(journal).write(to: stage.appending(path: "journal.json"))

        let mine = MutationCommands.unavailable("restore", root: dir.appending(path: "Mine.app"))
        #expect(mine.apps.map(\.outcome) == [.refused], "only the release gate, no pending operation")
        #expect(PendingOperations.read(root: dir.appending(path: "Mine.app"), apps: []).operations.isEmpty)
        let sibling = PendingOperations.read(root: dir.appending(path: "Sibling.app"), apps: [])
        #expect(sibling.operations.count == 1)
        #expect(PendingOperations.read(root: dir, apps: []).operations.count == 1, "a directory report includes it")
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

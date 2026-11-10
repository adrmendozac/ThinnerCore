import Foundation
import Testing
@testable import ThinnerCore

/// `release` deletes the only way back to an app's Intel code, so it is a
/// dry run unless `--apply` is passed, like thinning.
@Suite struct ReleaseCommandTests {
    @Test func previewListsWhatWouldGoAndDeletesNothing() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let report = MutationCommands.release(copy.app, apply: false)
        #expect(report.exitCode == 0)
        let app = try #require(report.apps.first)
        #expect(app.outcome == .nothingToDo)
        let details = try #require(app.release)
        #expect(details.dryRun)
        #expect(details.released.map { realPath($0) } == [realPath(copy.staging.path)])
        #expect(details.releasedBytes == copy.entries.map(\.originalSize).reduce(0, +))
        #expect(details.notes.contains(ReleaseOperation.warning))
        #expect(report.text.contains("Would delete: "))
        #expect(copy.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.backupPath) })
        #expect(FileManager.default.fileExists(atPath: copy.journalURL.path))
    }

    @Test func previewReportsAnUnfinishedOperation() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try copy.editJournal { $0["state"] = "inProgress" }
        let report = MutationCommands.release(copy.app, apply: false)
        #expect(report.apps.first?.outcome == .recoveryPending)
        #expect(report.exitCode == 3)
    }

    /// The gate is closed in this build: applying deletes nothing.
    @Test func applyIsGated() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let report = MutationCommands.release(copy.app, apply: true)
        #expect(report.exitCode == 1)
        #expect(report.apps.first?.reason.contains(MutationCommands.releaseBlock) == true)
        #expect(copy.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.backupPath) })
    }

    @Test func appliedReleaseReport() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let result = ReleaseOperation.releaseUnreleased(copy.app, environment: idleEnvironment)
        let report = MutationCommands.releaseReport(copy.app, result, dryRun: false)
        #expect(report.apps.first?.outcome == .committed)
        #expect(report.apps.first?.release?.dryRun == false)
        #expect(report.text.contains("Deleted: "))
        let decoded = try JSONDecoder().decode(MutationReport.self, from: Data(try report.json().utf8))
        #expect(decoded == report)
    }

    @Test func executablePreviewExitsZeroAndChangesNothing() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let binary = Bundle(for: Phase4CrashWorker.self).bundleURL.deletingLastPathComponent().appending(path: "thinnercore")
        let run = try Shell.run(binary.path, "release", copy.app.path, "--json")
        #expect(run.status == 0, "\(run.output)")
        let report = try JSONDecoder().decode(MutationReport.self, from: Data(run.output.utf8))
        #expect(report.command == "release")
        #expect(report.apps.first?.release?.dryRun == true)
        #expect(copy.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.backupPath) })
    }
}

import Foundation
import Testing
@testable import ThinnerCore

@Suite struct RecoveryReportTests {
    @Test func gateIsClosedForAllPublicOperations() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        #expect(!MutationReleaseGate.isOpen)
        #expect(try ThinOperation.apply(to: copy.app) == .skipped(reason: MutationCommands.releaseBlock))
        #expect(ThinOperation.recover(copy.app) == .skipped(reason: MutationCommands.releaseBlock))
        #expect(RestoreOperation.restore(copy.app).outcome == .refused(MutationCommands.releaseBlock))
        #expect(ReleaseOperation.release(copy.app).outcome == .refused(MutationCommands.releaseBlock))
        #expect(try copy.allStillThinned())
    }

    @Test func committedJournalNeedsNoRecovery() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let report = MutationCommands.recoverUnreleased(copy.app) { _ in
            Issue.record("must not run recovery for a committed journal")
            return .committed
        }
        #expect(report.apps.first?.outcome == .nothingToDo)
        #expect(report.exitCode == 0)
    }

    @Test func realRecoveryProducesVerifiedReport() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try copy.editJournal { $0["state"] = "inProgress" }
        let report = MutationCommands.recoverUnreleased(copy.app) {
            ThinOperation.recoverUnreleased($0, environment: idleEnvironment)
        }
        #expect(report.exitCode == 0)
        #expect(report.apps.first?.outcome == .committed)
        #expect(Codesign.verify(copy.app) == nil)
        #expect(try JSONDecoder().decode(MutationReport.self, from: Data(report.json().utf8)) == report)
    }

    @Test func refusalKeepsRecoveryPending() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try copy.editJournal { $0["state"] = "inProgress" }
        let report = MutationCommands.recoverUnreleased(copy.app) { _ in .skipped(reason: "host refused") }
        #expect(report.exitCode == 3)
        #expect(report.apps.first?.outcome == .recoveryPending)
        #expect(try copy.allStillThinned())
    }

    @Test func unreadableJournalPreventsAnyRecovery() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try Data("invalid".utf8).write(to: copy.journalURL)
        let report = MutationCommands.recoverUnreleased(copy.app) { _ in
            Issue.record("must not run with incomplete discovery")
            return .committed
        }
        #expect(report.exitCode == 3)
        #expect(!report.problems.isEmpty)
        #expect(try copy.allStillThinned())
    }
}

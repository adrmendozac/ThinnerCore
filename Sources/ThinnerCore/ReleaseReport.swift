import Foundation

extension MutationCommands {
    /// A dry run unless `apply`: backups are the only way back to the Intel
    /// code, so deleting them takes an explicit flag, like thinning does.
    /// Applying uses the public release API, so it cannot bypass its gate.
    public static func release(_ app: URL, apply: Bool) -> MutationReport {
        guard apply else { return releaseReport(app, ReleaseOperation.preview(app), dryRun: true) }
        let result = ReleaseOperation.release(app)
        if case .refused(let reason) = result.outcome, reason == releaseBlock {
            return unavailable("release", root: app)
        }
        return releaseReport(app, result, dryRun: false)
    }

    static func releaseReport(_ app: URL, _ result: ReleaseResult, dryRun: Bool) -> MutationReport {
        let outcome: MutationReport.Outcome
        let reason: String
        switch result.outcome {
        case .released where dryRun:
            outcome = .nothingToDo
            reason = "Dry run: nothing was deleted. Rerun with --apply to delete these backups."
        case .released:
            outcome = .committed
            reason = "Backups deleted."
        case .nothingToRelease(let message):
            outcome = .nothingToDo
            reason = message
        case .refused(let message):
            outcome = .refused
            reason = message
        case .pending(let message):
            outcome = .recoveryPending
            reason = message
        }
        let details = MutationReport.ReleaseDetails(dryRun: dryRun, released: result.released,
                                                    releasedBytes: result.releasedBytes, notes: result.notes)
        return MutationReport(command: "release", apps: [
            .init(path: app.path, outcome: outcome, reason: reason, release: details)
        ], problems: [])
    }
}

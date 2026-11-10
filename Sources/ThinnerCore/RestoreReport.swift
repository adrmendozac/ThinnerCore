import Foundation

extension MutationCommands {
    /// Uses the public restore API so CLI wiring cannot bypass its release gate.
    public static func restore(_ app: URL) -> MutationReport {
        let result = RestoreOperation.restore(app)
        if case .refused(let reason) = result.outcome, reason == releaseBlock {
            // Preserve read-only pending-journal diagnostics while gated.
            return unavailable("restore", root: app)
        }
        return restoreReport(app, result)
    }

    static func restoreReport(_ app: URL, _ result: RestoreResult) -> MutationReport {
        let outcome: MutationReport.Outcome
        let reason: String
        switch result.outcome {
        case .restored:
            outcome = .committed
            reason = "Original files restored and verified; backups retained."
        case .nothingToRestore(let message):
            outcome = .nothingToDo
            reason = message
        case .refused(let message):
            outcome = .refused
            reason = message
        case .pending(let message):
            outcome = .recoveryPending
            reason = message
        case .recoveryFailed(let message):
            outcome = .recoveryFailed
            reason = message
        }
        let details = MutationReport.RestoreDetails(
            restored: result.restored, alreadyOriginal: result.alreadyOriginal,
            backupLocations: result.backupLocations, notes: result.notes)
        return MutationReport(command: "restore", apps: [
            .init(path: app.path, outcome: outcome, reason: reason, restore: details)
        ], problems: [])
    }
}

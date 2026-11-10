import Foundation

extension MutationCommands {
    public static func recover(_ root: URL) -> MutationReport {
        guard MutationReleaseGate.isOpen else { return unavailable("recover", root: root) }
        return recoverUnreleased(root)
    }

    /// Discovery is read-only; each recovery rechecks its journals under the app lock.
    static func recoverUnreleased(_ root: URL,
                                  operation: (URL) -> ThinOperation.Outcome = ThinOperation.recover) -> MutationReport {
        let located = AppScanner.appLocations(root)
        let snapshot = PendingOperations.read(root: root, apps: located.apps)
        let problems = located.problems + snapshot.problems
        guard problems.isEmpty else {
            return MutationReport(command: "recover", apps: [
                .init(path: root.path, outcome: .recoveryPending,
                      reason: "Recovery not attempted: journal discovery is incomplete. Keep all backups.")
            ], problems: problems)
        }
        let paths = Set(snapshot.operations.map(\.bundlePath)).sorted()
        guard !paths.isEmpty else {
            return MutationReport(command: "recover", apps: [
                .init(path: root.path, outcome: .nothingToDo, reason: "No unfinished operations found in the searched directories.")
            ], problems: [])
        }
        var apps: [MutationReport.App] = []
        var stopped = false
        for path in paths {
            if stopped {
                apps.append(.init(path: path, outcome: .recoveryPending,
                                  reason: "Not attempted after unresolved recovery. Keep all backups."))
                continue
            }
            let outcome: MutationReport.Outcome
            let reason: String
            switch operation(URL(filePath: path)) {
            case .committed:
                outcome = .committed
                reason = "Recovered and verified; backups retained."
            case .rolledBack(let message): outcome = .rolledBack; reason = message
            case .superseded(let message): outcome = .superseded; reason = message
            case .pending(let message): outcome = .recoveryPending; reason = message
            case .recoveryFailed(let message): outcome = .recoveryFailed; reason = message
            case .skipped(let message): outcome = .recoveryPending; reason = message
            }
            apps.append(.init(path: path, outcome: outcome, reason: reason))
            // A refusal can leave the discovered operation unfinished too.
            stopped = outcome == .recoveryPending || outcome == .recoveryFailed || outcome == .refused
        }
        return MutationReport(command: "recover", apps: apps, problems: [])
    }
}

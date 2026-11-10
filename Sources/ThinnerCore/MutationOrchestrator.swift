import Foundation

/// Phase 5's batch coordinator. It remains internal until the Phase 0 and
/// restore/recovery release gates pass; the public CLI and library APIs still
/// refuse mutation. Each app is scanned again by `ThinOperation` under its
/// lock immediately before any write.
extension MutationCommands {
    typealias ApplyOperation = (URL, ScanOptions) throws(Problem) -> ThinOperation.Outcome

    static func applyUnreleased(_ root: URL, options: ScanOptions = ScanOptions(),
                                operation: ApplyOperation = { try ThinOperation.applyUnreleased(to: $0, options: $1) }) -> MutationReport {
        let scan = AppScanner.scan(root, options: options)
        let snapshot = PendingOperations.read(root: root, apps: scan.apps.map(\.url))
        let problems = scan.issues.map(\.problem) + snapshot.problems

        // A journal whose state cannot be read might belong to an interrupted
        // write. Do not start a new write anywhere in this batch until it can
        // be inspected. Likewise, recovery is an explicit operation here.
        if !snapshot.operations.isEmpty || !snapshot.problems.isEmpty {
            // Journals record the app's real path; the scan reports the path
            // as given (for example /var rather than /private/var).
            func key(_ path: String) -> String { realPath(path) ?? path }
            var pendingPaths = Set<String>()
            let pending = snapshot.operations.map { entry -> MutationReport.App in
                pendingPaths.insert(key(entry.bundlePath))
                return .init(path: entry.bundlePath,
                             outcome: entry.state == "recoveryFailed" ? .recoveryFailed : .recoveryPending,
                             reason: "Resolve the unfinished operation at \(entry.journalPath) before applying. Keep its backups.")
            }
            let untouched = scan.apps.filter { !pendingPaths.contains(key($0.url.path)) }.map {
                MutationReport.App(path: $0.url.path, outcome: .refused,
                                   reason: "Not attempted while a journal is unresolved. Keep all backups.")
            }
            return MutationReport(command: "apply", apps: pending + untouched, problems: problems)
        }
        if !scan.issues.isEmpty {
            return MutationReport(command: "apply", apps: scan.apps.map {
                .init(path: $0.url.path, outcome: .refused,
                      reason: "Not attempted because the app search was incomplete.")
            }, problems: problems)
        }

        var apps: [MutationReport.App] = []
        var stopReason: String?
        for app in scan.apps {
            if let stopReason {
                apps.append(.init(path: app.url.path, outcome: .refused, reason: stopReason))
                continue
            }
            if let skip = app.skip {
                apps.append(.init(path: app.url.path, outcome: skip.mutationOutcome, reason: skip.description))
                continue
            }
            if !app.issues.isEmpty {
                apps.append(.init(path: app.url.path, outcome: .refused,
                                  reason: "Incomplete app scan; resolve unreadable paths before retrying."))
                continue
            }
            if !app.files.contains(where: \.isEligible) {
                apps.append(.init(path: app.url.path, outcome: .nothingToDo, reason: "No eligible files."))
                continue
            }

            do {
                let result = try operation(app.url, options)
                let entry = report(app.url, result)
                apps.append(entry)
                if entry.outcome == .recoveryPending || entry.outcome == .recoveryFailed {
                    stopReason = "Not attempted after an unresolved operation. Keep all backups and recover first."
                }
            } catch {
                // The writer throws both from preflight, before anything is
                // written, and after its journal is durable. Decide by what is
                // on disk: an unfinished journal for this app, or one that
                // cannot be read, means recovery is pending and the batch
                // stops; no journal at all means nothing was written.
                let after = PendingOperations.read(root: app.url, apps: [app.url])
                if after.operations.isEmpty && after.problems.isEmpty {
                    apps.append(.init(path: app.url.path, outcome: .refused,
                                      reason: "Not changed: \(error.description)"))
                } else {
                    apps.append(.init(path: app.url.path, outcome: .recoveryPending,
                                      reason: "Operation stopped: \(error.description). Inspect the journal and recover before retrying; keep all backups."))
                    stopReason = "Not attempted after an operation stopped without a confirmed outcome."
                }
            }
        }
        return MutationReport(command: "apply", apps: apps, problems: problems)
    }

    private static func report(_ app: URL, _ result: ThinOperation.Outcome) -> MutationReport.App {
        switch result {
        case .committed:
            .init(path: app.path, outcome: .committed, reason: "Verified and committed; backups retained.")
        case let .rolledBack(reason):
            .init(path: app.path, outcome: .rolledBack, reason: reason)
        case let .superseded(reason):
            .init(path: app.path, outcome: .superseded, reason: reason)
        case let .pending(reason):
            .init(path: app.path, outcome: .recoveryPending, reason: reason)
        case let .recoveryFailed(reason):
            .init(path: app.path, outcome: .recoveryFailed, reason: reason)
        case let .skipped(reason):
            // The writer uses `skipped` for both policy decisions and failed
            // preflights. Policy skips and no-op apps were handled above;
            // any later skip is a refusal for exit-code purposes.
            .init(path: app.path, outcome: .refused, reason: reason)
        }
    }
}

extension AppSkipReason {
    /// An uncertain or invalid app is a refusal, not a successful policy
    /// skip. The report's exit status must tell automation to investigate.
    var mutationOutcome: MutationReport.Outcome {
        switch self {
        case .bundleMetadata, .rosettaInconclusive, .signatureInvalid, .skipListUnreadable, .allowListUnreadable:
            .refused
        case .protectedLocation, .excluded, .containsExclusion, .scriptOnly,
             .rosettaFlagged, .noNativeMainExecutable, .intelArchitecturePriority, .intelOnlyCode, .skipListed,
             .masApp, .embedsSystemExtension, .notOnAllowList:
            .skipped
        }
    }
}

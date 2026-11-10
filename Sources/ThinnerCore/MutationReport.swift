import Foundation

/// Stable outcomes shared by apply, restore, and interrupted-operation recovery.
public struct MutationReport: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case committed, skipped, nothingToDo, refused, rolledBack, recoveryPending, recoveryFailed
        /// Recovery found that the app the operation changed is gone or was
        /// replaced; nothing was changed and the backups are kept.
        case superseded

        public var exitCode: Int32 {
            switch self {
            case .committed, .skipped, .nothingToDo, .superseded: 0
            case .refused, .rolledBack: 1
            case .recoveryPending: 3
            case .recoveryFailed: 4
            }
        }
    }

    public struct App: Codable, Equatable, Sendable {
        public let path: String
        public let outcome: Outcome
        public let reason: String
        public var restore: RestoreDetails? = nil
        public var release: ReleaseDetails? = nil
    }

    /// Additive release details; absent from reports for other commands.
    public struct ReleaseDetails: Codable, Equatable, Sendable {
        /// True when nothing was deleted: `released` lists what would be.
        public let dryRun: Bool
        public let released: [String]
        /// Logical size of the backups (that would be) deleted.
        public let releasedBytes: UInt64
        public let notes: [String]
    }

    /// Additive restore details; absent from reports for other commands.
    public struct RestoreDetails: Codable, Equatable, Sendable {
        public let restored: [String]
        public let alreadyOriginal: [String]
        public let backupLocations: [String]
        public let notes: [String]
    }

    public var schemaVersion: Int = 1
    public let command: String
    public let apps: [App]
    public let problems: [String]
    public var exitCode: Int32 { max(problems.isEmpty ? 0 : 1, apps.map { $0.outcome.exitCode }.max() ?? 0) }

    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public var text: String {
        (apps.flatMap { app -> [String] in
            var lines = ["\(app.path): \(app.outcome.rawValue) — \(app.reason)"]
            if let details = app.restore {
                lines += details.restored.map { "  Restored: \($0)" }
                lines += details.alreadyOriginal.map { "  Already original: \($0)" }
                lines += details.backupLocations.map { "  Backups retained: \($0)" }
                lines += details.notes.map { "  Note: \($0)" }
            }
            if let details = app.release {
                let verb = details.dryRun ? "Would delete" : "Deleted"
                lines += details.released.map { "  \(verb): \($0)" }
                lines.append("  \(verb) \(details.releasedBytes) bytes of backups (logical size)")
                lines += details.notes.map { "  Note: \($0)" }
            }
            return lines
        } + problems)
            .map(TerminalText.sanitize).joined(separator: "\n")
    }
}

/// No runtime flag can bypass the release gate. Remove it only after the
/// Phase 0 gates and Phase 4/6 recovery requirements have been validated.
public enum MutationCommands {
    public static let releaseBlock = "Modification is unavailable: Phase 0 permission and Gatekeeper gates, the audited writer, and Phase 6 restore/recovery validation must pass first. Continue using scan; keep all existing backups."

    public static func apply(_ root: URL, options: ScanOptions = ScanOptions()) -> MutationReport {
        if MutationReleaseGate.isOpen { return applyUnreleased(root, options: options) }
        let scan = AppScanner.scan(root, options: options)
        let snapshot = PendingOperations.read(root: root, apps: scan.apps.map(\.url))
        var apps = scan.apps.map { app -> MutationReport.App in
            if let skip = app.skip {
                return .init(path: app.url.path, outcome: skip.mutationOutcome, reason: skip.description)
            }
            if !app.issues.isEmpty {
                return .init(path: app.url.path, outcome: .refused, reason: "Incomplete app scan; resolve unreadable paths before retrying.")
            }
            if let refusal = HostGate.check() {
                return .init(path: app.url.path, outcome: .refused, reason: refusal.description)
            }
            do {
                let usage = try BundleUsage.scan(app.url)
                if !usage.uses.isEmpty {
                    return .init(path: app.url.path, outcome: .refused,
                                 reason: "Quit processes using this app before retrying: " + usage.uses.map(\.description).joined(separator: "; "))
                }
                if usage.uninspectable > 0 {
                    return .init(path: app.url.path, outcome: .refused,
                                 reason: "Cannot establish that this app is idle: \(usage.uninspectable) processes could not be inspected. Full-visibility policy remains a Phase 0 gate; do not bypass this refusal.")
                }
            } catch {
                return .init(path: app.url.path, outcome: .refused, reason: "Cannot inspect running processes: \(error)")
            }
            return .init(path: app.url.path, outcome: .refused, reason: releaseBlock)
        }
        apps += snapshot.operations.map {
            .init(path: $0.bundlePath, outcome: $0.state == "recoveryFailed" ? .recoveryFailed : .recoveryPending,
                  reason: "Unfinished operation at \($0.journalPath). Keep its backups; recovery is unavailable in this build.")
        }
        return MutationReport(command: "apply", apps: apps,
                              problems: [releaseBlock] + scan.issues.map(\.problem) + snapshot.problems)
    }

    public static func unavailable(_ command: String, root: URL) -> MutationReport {
        // Journals sit beside each app, so a directory's nested apps must be
        // found first; the root alone holds only its direct children's.
        let located = AppScanner.appLocations(root)
        let snapshot = PendingOperations.read(root: root, apps: located.apps)
        let pending: [MutationReport.App] = snapshot.operations.map {
            .init(path: $0.bundlePath, outcome: $0.state == "recoveryFailed" ? .recoveryFailed : .recoveryPending,
                  reason: "Unfinished operation at \($0.journalPath). \(releaseBlock)")
        }
        return MutationReport(command: command,
                              apps: pending.isEmpty ? [.init(path: root.path, outcome: .refused, reason: releaseBlock)] : pending,
                              problems: located.problems + snapshot.problems)
    }
}

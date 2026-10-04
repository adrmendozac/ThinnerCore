import Foundation

/// The human-readable dry-run report, rendered from the same `ScanReport` as
/// the JSON.
public enum TextReport {
    public static func render(_ report: ScanReport, verbose: Bool = false, color: Bool = false) -> String {
        var lines: [String] = []
        lines.append("\(report.tool.name)  \(report.tool.version)")
        lines.append("dry run: nothing on disk was changed")
        lines.append("")
        lines.append("Path     \(report.root)")
        lines.append(rosetta(report.rosetta))
        for path in report.missingExclusions {
            lines.append("Warning: excluded path not found, so it excludes nothing: \(path)")
        }

        let totals = report.totals
        let skipped = totals.skippedApps > 0 ? " (\(totals.skippedApps) skipped)" : ""
        lines.append("")
        lines.append("OVERVIEW")
        lines.append("Total: \(count(totals.apps, "app"))\(skipped) · \(count(totals.universalFiles, "universal file"))"
            + " · \(totals.eligibleFiles) eligible · \(bytes(totals.removableBytes)) estimated removable")
        lines.append("Estimates are the logical size of the slices removed, not disk space freed.")
        lines.append("")
        lines.append("APPLICATIONS")
        if report.apps.isEmpty { lines.append("  No apps found in the searched paths.") }
        for app in report.apps {
            let status = app.skip != nil ? "SKIP" : !app.issues.isEmpty ? "CHECK" : app.eligibleFiles > 0 ? "ELIGIBLE" : "NO CHANGE"
            lines.append("")
            lines.append("  [\(status)] \(app.path)")
            if verbose, let id = app.bundleIdentifier { lines.append("    \(id)") }
            lines += self.app(app, verbose: verbose).map { "    \($0)" }
        }

        if !report.skippedPaths.isEmpty {
            lines.append("")
            lines.append("Not searched:")
            for skipped in report.skippedPaths {
                lines.append("  \(display(skipped.path, root: report.root)): \(skipped.reason.detail)")
            }
        }

        let unreadable = report.issues.map { (display($0.path, root: report.root), $0.problem) }
            + report.apps.flatMap { app in app.issues.map { ("\(app.path)/\($0.path)", $0.problem) } }
        if !unreadable.isEmpty {
            lines.append("")
            lines.append("Could not read:")
            lines += unreadable.map { "  \($0): \($1)" }
        }

        if !report.pendingOperations.operations.isEmpty || !report.pendingOperations.problems.isEmpty {
            lines.append("")
            lines.append("Recovery journal snapshot (unlocked; may be out of date; searched beside the root and discovered apps):")
            lines += report.pendingOperations.operations.map { "  \($0.bundlePath): \($0.state) — \($0.journalPath)" }
            lines += report.pendingOperations.problems.map { "  \($0)" }
            lines.append("No recovery was attempted. Keep all backups.")
        }
        lines.append("")
        if totals.issues > 0 {
            lines.append("Incomplete scan: \(count(totals.issues, "path")) could not be read; counts are lower bounds.")
        }
        if !report.pendingOperations.problems.isEmpty {
            lines.append("Journal inspection incomplete: \(count(report.pendingOperations.problems.count, "problem")); see recovery details above.")
        }
        if report.complete { lines.append("Scan complete. No files changed.") }
        if !verbose && !report.apps.isEmpty { lines.append("Use --verbose for file decisions or --json for structured output.") }
        return lines.map { line in
            let clean = TerminalText.sanitize(line)
            guard color else { return clean }
            let code: String?
            if line == "OVERVIEW" || line == "APPLICATIONS" || line.hasPrefix(report.tool.name + "  ") { code = "1;36" }
            else if line.hasPrefix("Total:") { code = "1" }
            else if line.contains("[ELIGIBLE]") || line == "Scan complete. No files changed." { code = "32" }
            else if line.contains("[SKIP]") || line.contains("[CHECK]") || line.hasPrefix("Warning:") || line.hasPrefix("Incomplete") || line.hasPrefix("Journal inspection") { code = "33" }
            else if line.contains("[NO CHANGE]") || line.hasPrefix("Use --") || line.hasPrefix("Estimates") { code = "2" }
            else { code = nil }
            return code.map { "\u{1B}[\($0)m\(clean)\u{1B}[0m" } ?? clean
        }.joined(separator: "\n")
    }

    private static func app(_ app: ScanReport.App, verbose: Bool) -> [String] {
        var lines: [String] = []
        if let skip = app.skip {
            lines.append("skipped: \(skip.detail)")
            let wouldBe = app.files.count(where: \.eligible)
            if wouldBe > 0 {
                lines.append("\(count(app.universalFiles, "universal file")); \(wouldBe) would otherwise be eligible")
            }
        } else if app.universalFiles == 0 {
            lines.append("no universal files")
        } else {
            lines.append("\(app.universalFiles) universal · \(app.eligibleFiles) eligible"
                + " · \(bytes(app.removableBytes)) removable")
            let skipped = Dictionary(grouping: app.files.compactMap(\.skip), by: \.code)
            if !skipped.isEmpty {
                let parts = skipped.count == 1
                    ? skipped.keys.map(label)
                    : skipped.keys.sorted().map { "\(skipped[$0]!.count) \(label($0))" }
                lines.append("\(skipped.values.map(\.count).reduce(0, +)) skipped: \(parts.joined(separator: ", "))")
            }
        }
        if verbose {
            for file in app.files {
                if let skip = file.skip {
                    lines.append("  skip      \(file.path): \(skip.detail)")
                } else {
                    let removing = (file.removing ?? []).joined(separator: ", ")
                    lines.append("  eligible  \(file.path): remove \(removing), \(bytes(file.savedBytes))")
                }
            }
        }
        return lines
    }

    private static func rosetta(_ rosetta: ScanReport.Rosetta) -> String {
        let installed = rosetta.installed ? "installed" : "not installed"
        let flags: String = switch rosetta.preferences {
        case "absent", "read":
            "\(count(rosetta.flaggedApps ?? 0, "app")) set to Open using Rosetta in \(rosetta.preferencesUser)'s preferences"
        default:
            "\(rosetta.preferencesUser)'s LaunchServices preferences are unreadable, so every app is skipped"
                + (rosetta.problem.map { " (\($0))" } ?? "")
        }
        return "Rosetta: \(installed); \(flags)"
    }

    /// Short names for file skip codes, for the per-app summary.
    private static func label(_ code: String) -> String {
        switch code {
        case "notUniversal": "not universal"
        case "malformed": "malformed"
        case "noARM64": "without arm64"
        case "noIntel": "without Intel"
        case "noSavings": "with nothing to save"
        case "hardLinked": "hard-linked"
        case "sealedAsData": "sealed as data"
        case "unsealed": "not sealed as code"
        case "signatureMetadata": "with unreadable signature metadata"
        default: code
        }
    }

    private static func display(_ path: String, root: String) -> String {
        path.isEmpty ? root : path
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    private static func bytes(_ n: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false // "0 bytes", not "Zero KB"
        return formatter.string(fromByteCount: Int64(clamping: n))
    }
}

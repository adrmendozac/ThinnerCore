import Foundation

/// The system's own signature check, the authority over any reading of
/// `CodeResources` this module does. Read-only.
enum Codesign {
    /// A deep check of the largest apps takes minutes; a timeout counts as
    /// a failed verification.
    static let timeout: TimeInterval = 1800

    /// Nil if the app verifies; otherwise what `codesign` objected to.
    static func verify(_ app: URL) -> String? {
        let result: Subprocess.Result
        do {
            result = try Subprocess.run("/usr/bin/codesign",
                                        ["--verify", "--deep", "--strict", "--all-architectures", app.path],
                                        timeout: timeout)
        } catch {
            return error.description
        }
        if result.timedOut { return "codesign did not finish within \(Int(timeout)) seconds" }
        guard result.status != 0 else { return nil }

        // codesign prefixes its first line with the path it was given.
        let lines = result.output.split(separator: "\n").map { line in
            line.hasPrefix(app.path + ": ") ? String(line.dropFirst(app.path.count + 2)) : String(line)
        }
        return lines.isEmpty ? "codesign exited \(result.status)" : lines.prefix(3).joined(separator: "; ")
    }
}

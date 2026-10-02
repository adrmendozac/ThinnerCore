import Foundation

/// The system's own signature check, the authority over any reading of
/// `CodeResources` this module does. Read-only.
enum Codesign {
    /// Nil if the app verifies; otherwise what `codesign` objected to.
    static func verify(_ app: URL) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", "--all-architectures", app.path]
        // One pipe for both streams, drained before waiting, so codesign can
        // never block on a full buffer.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return "cannot run codesign: \(error.localizedDescription)"
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }

        // codesign prefixes its first line with the path it was given.
        let lines = output.split(separator: "\n").map { line in
            line.hasPrefix(app.path + ": ") ? String(line.dropFirst(app.path.count + 2)) : String(line)
        }
        return lines.isEmpty ? "codesign exited \(process.terminationStatus)" : lines.prefix(3).joined(separator: "; ")
    }
}

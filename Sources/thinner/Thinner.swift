import ArgumentParser
import Foundation
import ThinnerCore

@main
struct Thinner: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thinner",
        abstract: "Remove Intel (x86_64) slices from Universal Binary apps on Apple Silicon.",
        version: ThinnerCore.version,
        subcommands: [Scan.self],
        defaultSubcommand: Scan.self
    )

    /// Invalid arguments exit 2, not ArgumentParser's default of 64.
    static func main() {
        do {
            var command = try parseAsRoot()
            try command.run()
        } catch {
            if exitCode(for: error).rawValue == ExitCode.validationFailure.rawValue {
                FileHandle.standardError.write(Data((fullMessage(for: error) + "\n").utf8))
                Foundation.exit(2)
            }
            exit(withError: error)
        }
    }
}

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report what thinning would remove. Read-only: nothing on disk changes.",
        discussion: """
            Lists every app under PATH with its universal files, the files that could be \
            thinned, the estimated bytes removable, and why anything is skipped. Estimates \
            are the logical size of the slices removed, not disk space freed. A file listed \
            as eligible is not authorization to change it: every check runs again before \
            any change.

            Exit status: 0 for a complete scan, 1 for a scan that failed or could not read \
            everything, 2 for invalid arguments.
            """
    )

    @Argument(help: "An app, or a folder to search for apps.")
    var path = "/Applications"

    @Option(name: .customLong("exclude"),
            help: ArgumentHelp("Leave out a path, everything below it, and any app that contains it. Repeatable.",
                               valueName: "path"))
    var excludes: [String] = []

    @Option(help: ArgumentHelp(
        "Read \"Open using Rosetta\" settings from this LaunchServices preferences file instead of the current user's.",
        valueName: "plist"))
    var rosettaPreferences: String?

    @Flag(help: "Print the report as JSON.")
    var json = false

    @Flag(name: .shortAndLong, help: "List every universal file with its decision.")
    var verbose = false

    func validate() throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw ValidationError("cannot scan \(path): \(String(cString: strerror(errno)))")
        }
    }

    func run() throws {
        let root = Self.absolute(path)
        let excludes = excludes.map(Self.absolute)
        let progress = ProgressLine()
        let options = ScanOptions(excludes: excludes, launchServicesPreferences: rosettaPreferences.map(Self.absolute))
        let result = AppScanner.scan(root, options: options, progress: progress.show)
        progress.clear()

        let report = ScanReport(root: root, excludes: excludes, result: result)
        print(json ? try report.json() : TextReport.render(report, verbose: verbose))
        if !report.complete { throw ExitCode(1) }
    }

    private static func absolute(_ path: String) -> URL {
        URL(filePath: path, relativeTo: URL.currentDirectory()).absoluteURL
    }
}

/// "Scanning <app>…" on one self-erasing line, only when stderr is a
/// terminal, so piped and JSON output stay clean.
final class ProgressLine {
    private let enabled = isatty(STDERR_FILENO) != 0
    private var shown = false

    func show(_ app: String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2KScanning \(app)…".utf8))
        shown = true
    }

    func clear() {
        guard shown else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
    }
}

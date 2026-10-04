import ArgumentParser
import Foundation
import ThinnerCore

@main
struct Thinner: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thinner",
        abstract: "Remove Intel (x86_64) slices from Universal Binary apps on Apple Silicon.",
        version: ThinnerCore.version,
        subcommands: [Scan.self, Restore.self, Recover.self],
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

enum ColorMode: String, ExpressibleByArgument {
    case auto, always, never

    var enabled: Bool {
        switch self {
        case .always: true
        case .never: false
        case .auto: isatty(STDOUT_FILENO) != 0
            && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
            && ProcessInfo.processInfo.environment["TERM"] != "dumb"
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
            everything, 2 for invalid arguments. Mutation requests use 3 for pending recovery and 4 for failed recovery; the highest outcome code wins across apps.
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

    @Flag(name: .customLong("apply"), help: "Request thinning (unavailable until safety and restore release gates pass).")
    var apply = false

    @Flag(help: "Print the report as JSON.")
    var json = false

    @Option(help: "Terminal colors: auto, always, or never. JSON is never colored.")
    var color: ColorMode = .auto

    @Flag(name: .shortAndLong, help: "List every universal file with its decision.")
    var verbose = false

    func validate() throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw ValidationError("cannot scan \(PermissionDiagnostic.describe(errno, path: path))")
        }
    }

    func run() throws {
        let root = Self.absolute(path)
        let excludes = excludes.map(Self.absolute)
        let progress = ProgressLine()
        let options = ScanOptions(excludes: excludes, launchServicesPreferences: rosettaPreferences.map(Self.absolute))
        if apply {
            let report = MutationCommands.apply(root, options: options)
            print(json ? try report.json() : report.text)
            if report.exitCode != 0 { throw ExitCode(report.exitCode) }
            return
        }
        let result = AppScanner.scan(root, options: options, progress: progress.show)
        progress.clear()

        let report = ScanReport(root: root, excludes: excludes, result: result)
        print(json ? try report.json() : TextReport.render(report, verbose: verbose, color: color.enabled))
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
        FileHandle.standardError.write(Data("\r\u{1B}[2KScanning \(TerminalText.sanitize(app))…".utf8))
        shown = true
    }

    func clear() {
        guard shown else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
    }
}

/// These commands reserve the stable interface without exposing an unsafe
/// fallback such as manually copying backup files over a changed app.
struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restore an app (release gate pending).")
    @Argument(help: "App to restore.") var path: String
    @Flag(help: "Print the report as JSON.") var json = false
    func run() throws { try reportUnavailable("restore", path: path, json: json) }
}

struct Recover: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Recover interrupted operations (release gate pending).")
    @Argument(help: "App or directory to recover.") var path: String
    @Flag(help: "Print the report as JSON.") var json = false
    func run() throws { try reportUnavailable("recover", path: path, json: json) }
}

private func reportUnavailable(_ command: String, path: String, json: Bool) throws {
    let root = URL(filePath: path, relativeTo: URL.currentDirectory()).absoluteURL
    let report = MutationCommands.unavailable(command, root: root)
    print(json ? try report.json() : report.text)
    throw ExitCode(report.exitCode)
}

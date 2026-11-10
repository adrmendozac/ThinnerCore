import ArgumentParser
import Foundation
import ThinnerCore

@main
struct Thinner: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thinnercore",
        abstract: "Remove Intel (x86_64) slices from Universal Binary apps on Apple Silicon.",
        version: ThinnerCore.version,
        subcommands: [Scan.self, Restore.self, Recover.self, Release.self, Skip.self, Allow.self],
        defaultSubcommand: Scan.self
    )

    /// Invalid arguments exit 2, not ArgumentParser's default of 64.
    static func main() {
        if MutationReleaseGate.isOpen {
            FileHandle.standardError.write(Data((MutationReleaseGate.developmentWarning + "\n").utf8))
        }
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
        "Read \"Open using Rosetta\" settings from this LaunchServices preferences file instead of the current user's (under sudo, the invoking user's).",
        valueName: "plist"))
    var rosettaPreferences: String?

    @Option(help: ArgumentHelp(
        "Read the skip list from this file instead of the current user's (under sudo, the invoking user's).",
        valueName: "file"))
    var skipList: String?

    @Option(help: ArgumentHelp(
        "Read the allow list from this file instead of the current user's (under sudo, the invoking user's). When it has entries, only those apps can be thinned.",
        valueName: "file"))
    var allowList: String?

    @Flag(name: .customLong("apply"), help: "Request thinning (unavailable until safety and restore release gates pass).")
    var apply = false

    @Flag(help: "With --apply, do not ask for confirmation in a terminal.")
    var yes = false

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
        var options = ScanOptions(excludes: excludes, launchServicesPreferences: rosettaPreferences.map(Self.absolute))
        do {
            options.loadSkipList(try skipList.map(Self.absolute) ?? SkipListFile.defaultLocation())
        } catch {
            options.skipListProblem = (error as? Problem)?.description ?? "\(error)"
        }
        do {
            options.loadAllowList(try allowList.map(Self.absolute) ?? AllowListFile.defaultLocation())
        } catch {
            options.allowListProblem = (error as? Problem)?.description ?? "\(error)"
        }
        if apply {
            if MutationReleaseGate.isOpen && !yes && Confirm.interactive {
                let preview = AppScanner.scan(root, options: options, progress: progress.show)
                progress.clear()
                let eligible = preview.apps.filter { $0.skip == nil && $0.issues.isEmpty && $0.eligibleCount > 0 }
                if !eligible.isEmpty {
                    let bytes = eligible.reduce(0) { $0 + $1.removableBytes }
                    var lines = ["About to thin \(eligible.count) app\(eligible.count == 1 ? "" : "s"):"]
                    lines += eligible.map { "  \($0.relativePath)  \(Confirm.bytes($0.removableBytes))" }
                    lines.append("Estimated \(Confirm.bytes(bytes)) removable. Backups of the originals are kept,")
                    lines.append("so disk usage first grows until you release them. Every check runs again first.")
                    guard Confirm.yes(lines.joined(separator: "\n") + "\nThin these apps? [y/N] ") else {
                        Confirm.cancelled()
                    }
                }
            }
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

/// "Scanning <app> (12/140)…" on one self-erasing line, only when stderr is a
/// terminal, so piped and JSON output stay clean.
///
/// With `THINNERCORE_PROGRESS=json` (set by the Ink front end, which pipes
/// stderr), each update is instead one JSON line on stderr:
/// `{"progress":{"app":"…","index":12,"total":140}}`. stdout is unaffected.
final class ProgressLine {
    private let json = ProcessInfo.processInfo.environment["THINNERCORE_PROGRESS"] == "json"
    private let enabled = isatty(STDERR_FILENO) != 0
    private var shown = false

    func show(_ progress: ScanProgress) {
        if json {
            struct Line: Encodable { let progress: ScanProgress }
            guard let data = try? JSONEncoder().encode(Line(progress: progress)) else { return }
            FileHandle.standardError.write(data + Data("\n".utf8))
            return
        }
        guard enabled else { return }
        let app = TerminalText.sanitize(progress.app)
        FileHandle.standardError.write(Data("\r\u{1B}[2KScanning \(app) (\(progress.index)/\(progress.total))…".utf8))
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
    static let configuration = CommandConfiguration(
        abstract: "Restore an app (release gate pending).",
        discussion: """
            Puts back the original universal files from the backups made during thinning. \
            Backups are retained after restoration. If a restore stops part-way (e.g. because \
            the app is running), quit the app and run restore again to retry the remaining files. \
            Restored files will unavoidably receive a new com.apple.provenance tag from macOS.
            """
    )
    @Argument(help: "App to restore.") var path: String
    @Flag(help: "Print the report as JSON.") var json = false
    func validate() throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw ValidationError("cannot restore \(PermissionDiagnostic.describe(errno, path: path))")
        }
    }
    func run() throws {
        let app = URL(filePath: path, relativeTo: URL.currentDirectory()).absoluteURL
        let report = MutationCommands.restore(app)
        print(json ? try report.json() : report.text)
        if report.exitCode != 0 { throw ExitCode(report.exitCode) }
    }
}

/// Terminal confirmation for commands that change the disk. Asked on stderr
/// only when stdin and stderr are terminals, so scripts and JSON on stdout are
/// unaffected; `--yes` skips it. Anything but the expected answer, including
/// end of input, cancels.
enum Confirm {
    static var interactive: Bool { isatty(STDIN_FILENO) != 0 && isatty(STDERR_FILENO) != 0 }

    static func yes(_ question: String) -> Bool {
        guard let answer = ask(question)?.lowercased() else { return false }
        return answer == "y" || answer == "yes"
    }

    /// For changes that cannot be undone: the user types `expected` exactly.
    static func typed(_ question: String, expected: String) -> Bool {
        ask(question) == expected
    }

    static func cancelled() -> Never {
        FileHandle.standardError.write(Data("Cancelled. Nothing changed.\n".utf8))
        Foundation.exit(1)
    }

    static func bytes(_ n: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(clamping: n))
    }

    private static func ask(_ question: String) -> String? {
        FileHandle.standardError.write(Data(question.split(separator: "\n", omittingEmptySubsequences: false).map { TerminalText.sanitize(String($0)) }.joined(separator: "\n").utf8))
        return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct Recover: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Recover interrupted operations (release gate pending).")
    @Argument(help: "App or directory to recover.") var path: String
    @Flag(help: "Print the report as JSON.") var json = false
    func run() throws {
        let root = URL(filePath: path, relativeTo: URL.currentDirectory()).absoluteURL
        let report = MutationCommands.recover(root)
        print(json ? try report.json() : report.text)
        if report.exitCode != 0 { throw ExitCode(report.exitCode) }
    }
}

struct Release: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete an app's backups (dry run unless --apply; release gate pending).",
        discussion: """
            Backups keep the original universal files, so disk usage grows by each thinned \
            file's size until they are released. Without --apply, lists what would be deleted \
            and changes nothing. Released backups are gone: afterwards only reinstalling the app, \
            while its vendor still ships a universal build, brings back its Intel code. Refused \
            while any thinning, recovery, or restore of the app is unfinished. Works for an app \
            that was deleted, once recover has marked its operations superseded.
            """
    )
    @Argument(help: "App whose backups to delete. It may no longer exist.") var path: String
    @Flag(help: "Delete the backups. Without it, nothing is deleted.") var apply = false
    @Flag(help: "With --apply, do not ask for confirmation in a terminal.") var yes = false
    @Flag(help: "Print the report as JSON.") var json = false
    func run() throws {
        let app = URL(filePath: path, relativeTo: URL.currentDirectory()).absoluteURL
        if apply && MutationReleaseGate.isOpen && !yes && Confirm.interactive {
            let preview = ReleaseOperation.preview(app)
            if case .released = preview.outcome, !preview.released.isEmpty {
                let name = app.deletingPathExtension().lastPathComponent
                var lines = ["About to delete \(Confirm.bytes(preview.releasedBytes)) of backups for \(app.lastPathComponent):"]
                lines += preview.released.map { "  \($0)" }
                lines.append("Afterwards only reinstalling the app, while its vendor still ships a universal")
                lines.append("build, brings back its Intel code. This cannot be undone.")
                guard Confirm.typed(lines.joined(separator: "\n") + "\nType \(name) to delete: ", expected: name) else {
                    Confirm.cancelled()
                }
            }
        }
        let report = MutationCommands.release(app, apply: apply)
        print(json ? try report.json() : report.text)
        if report.exitCode != 0 { throw ExitCode(report.exitCode) }
    }
}

/// The persistent skip list: apps the tool never thins.
struct Skip: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or edit the skip list of apps that are never thinned.",
        discussion: """
            One entry per line in ~/Library/Application Support/thinnercore/skip-list.txt: \
            an absolute path (excluded like --exclude) or a bundle identifier (skipped \
            wherever the app is). An existing path given to add or remove is stored as an \
            absolute path. Edit it without sudo; runs under sudo read the invoking user's list.
            """,
        subcommands: [List.self, Add.self, Remove.self],
        defaultSubcommand: List.self
    )

    struct Location: ParsableArguments {
        @Option(help: ArgumentHelp("Use this skip list file instead of the current user's.", valueName: "file"))
        var skipList: String?

        func url() throws -> URL {
            if let skipList { return URL(filePath: skipList, relativeTo: URL.currentDirectory()).absoluteURL }
            do { return try SkipListFile.defaultLocation() } catch { throw ValidationError(error.description) }
        }
    }

    /// An existing path becomes absolute; anything else is kept as typed.
    static func entry(_ value: String) -> String {
        guard !value.hasPrefix("/"), !value.hasPrefix("~/"), FileManager.default.fileExists(atPath: value) else { return value }
        return URL(filePath: value, relativeTo: URL.currentDirectory()).absoluteURL.standardizedFileURL.path
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the skip list entries.")
        @OptionGroup var location: Location
        @Flag(help: "Print the list as JSON.") var json = false
        func run() throws {
            let url = try location.url()
            let entries: [String]
            do { entries = try SkipListFile.entries(at: url) } catch { throw ValidationError(error.description) }
            if json {
                struct Output: Encodable { let path: String; let entries: [String] }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: try encoder.encode(Output(path: url.path, entries: entries)), as: UTF8.self))
            } else {
                print(TerminalText.sanitize("Skip list: \(url.path)"))
                print(entries.isEmpty ? "  (empty)" : entries.map { TerminalText.sanitize("  \($0)") }.joined(separator: "\n"))
            }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add an app path or bundle identifier.")
        @Argument(help: "Path or bundle identifier.") var entry: String
        @OptionGroup var location: Location
        func run() throws {
            let value = Skip.entry(entry)
            let changed: Bool
            do { changed = try SkipListFile.add(value, at: try location.url()) } catch let error as Problem { throw ValidationError(error.description) }
            print(TerminalText.sanitize(changed ? "Added \(value)" : "Already listed: \(value)"))
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove an entry.")
        @Argument(help: "Path or bundle identifier, as listed.") var entry: String
        @OptionGroup var location: Location
        func run() throws {
            let value = Skip.entry(entry)
            let changed: Bool
            do { changed = try SkipListFile.remove(value, at: try location.url()) } catch let error as Problem { throw ValidationError(error.description) }
            print(TerminalText.sanitize(changed ? "Removed \(value)" : "Not listed: \(value)"))
            if !changed { throw ExitCode(1) }
        }
    }
}

/// The allow list: when it has entries, the only apps that can be thinned.
struct Allow: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or edit the allow list: when it has entries, only those apps can be thinned.",
        discussion: """
            One entry per line in ~/Library/Application Support/thinnercore/allow-list.txt: \
            an absolute path (that app, or every app below that folder) or a bundle identifier \
            (that app wherever it is). Empty or missing, it allows every app. It only narrows: \
            listed apps still pass every check, and the skip list and --exclude win over it. \
            An existing path given to add or remove is stored as an absolute path. Edit it \
            without sudo; runs under sudo read the invoking user's list.
            """,
        subcommands: [List.self, Add.self, Remove.self],
        defaultSubcommand: List.self
    )

    struct Location: ParsableArguments {
        @Option(help: ArgumentHelp("Use this allow list file instead of the current user's.", valueName: "file"))
        var allowList: String?

        func url() throws -> URL {
            if let allowList { return URL(filePath: allowList, relativeTo: URL.currentDirectory()).absoluteURL }
            do { return try AllowListFile.defaultLocation() } catch { throw ValidationError(error.description) }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the allow list entries.")
        @OptionGroup var location: Location
        @Flag(help: "Print the list as JSON.") var json = false
        func run() throws {
            let url = try location.url()
            let entries: [String]
            do { entries = try SkipListFile.entries(at: url) } catch { throw ValidationError(error.description) }
            if json {
                struct Output: Encodable { let path: String; let entries: [String] }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: try encoder.encode(Output(path: url.path, entries: entries)), as: UTF8.self))
            } else {
                print(TerminalText.sanitize("Allow list: \(url.path)"))
                print(entries.isEmpty ? "  (empty: every app can be thinned)" : entries.map { TerminalText.sanitize("  \($0)") }.joined(separator: "\n"))
            }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add an app or folder path, or a bundle identifier.")
        @Argument(help: "Path or bundle identifier.") var entry: String
        @OptionGroup var location: Location
        func run() throws {
            let value = Skip.entry(entry)
            let changed: Bool
            do { changed = try SkipListFile.add(value, at: try location.url(), header: AllowListFile.header) }
            catch let error as Problem { throw ValidationError(error.description) }
            print(TerminalText.sanitize(changed ? "Added \(value)" : "Already listed: \(value)"))
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove an entry.")
        @Argument(help: "Path or bundle identifier, as listed.") var entry: String
        @OptionGroup var location: Location
        func run() throws {
            let value = Skip.entry(entry)
            let changed: Bool
            do { changed = try SkipListFile.remove(value, at: try location.url()) } catch let error as Problem { throw ValidationError(error.description) }
            print(TerminalText.sanitize(changed ? "Removed \(value)" : "Not listed: \(value)"))
            if !changed { throw ExitCode(1) }
        }
    }
}

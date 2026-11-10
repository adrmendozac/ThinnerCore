import Foundation

/// The user's persistent skip list: apps the tool never thins, on every run,
/// with the standing of `--exclude` (no force option overrides it).
///
/// A text file, one entry per line. An entry starting with `/` or `~/` is a
/// path, excluded like `--exclude`: itself, everything below it, and any app
/// containing it. Any other entry is a bundle identifier; apps with it are
/// skipped wherever they are. `#` starts a comment.
///
/// It belongs to the same user whose "Open using Rosetta" choices are read:
/// under `sudo`, the user who ran it. A list that exists but cannot be read
/// refuses every app, never "nothing excluded".
public struct SkipList: Equatable, Sendable {
    public var paths: [String] = []
    public var bundleIdentifiers: [String] = []

    public init(paths: [String] = [], bundleIdentifiers: [String] = []) {
        self.paths = paths
        self.bundleIdentifiers = bundleIdentifiers
    }

    public var isEmpty: Bool { paths.isEmpty && bundleIdentifiers.isEmpty }

    static func location(home: String) -> URL {
        URL(filePath: home).appending(path: "Library/Application Support/thinnercore/skip-list.txt")
    }

    /// The allow list (see `AllowListFile`) uses the same format beside it.
    static func allowLocation(home: String) -> URL {
        URL(filePath: home).appending(path: "Library/Application Support/thinnercore/allow-list.txt")
    }

    static func home(of uid: uid_t) -> String {
        getpwuid(uid).flatMap { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    }

    /// Parses the file's text; `home` expands `~/`.
    static func parse(_ text: String, home: String) -> SkipList {
        var list = SkipList()
        for raw in text.split(whereSeparator: \.isNewline) {
            let entry = Self.entry(in: raw)
            if entry.isEmpty { continue }
            if entry.hasPrefix("/") {
                list.paths.append(entry)
            } else if entry.hasPrefix("~/") {
                list.paths.append(home + entry.dropFirst())
            } else {
                list.bundleIdentifiers.append(entry)
            }
        }
        return list
    }

    /// The same entry text is used for scanning, listing, and removal.
    static func entry(in line: Substring) -> String {
        (line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The list at `url`; empty when there is no file.
    static func load(_ url: URL, home: String) throws(Problem) -> SkipList {
        guard let text = try readText(url) else { return SkipList() }
        return parse(text, home: home)
    }

    /// The file's text, or nil when there is none. Read on the user's behalf
    /// even under sudo, so a symlink, FIFO, device, oversized file, or
    /// non-UTF-8 content is an error, never followed or guessed at.
    static func readText(_ url: URL) throws(Problem) -> String? {
        guard let data = try readSettingsFile(url.path, limit: 1 << 20) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { throw Problem("\(url.path) is not UTF-8 text") }
        return text
    }
}

/// Reading and editing the skip list file, for the `skip` command.
public enum SkipListFile {
    public static func defaultLocation() throws(Problem) -> URL {
        SkipList.location(home: SkipList.home(of: try RosettaFlags.defaultPreferencesUser().get()))
    }

    public static func entries(at url: URL) throws(Problem) -> [String] {
        guard let text = try SkipList.readText(url) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { SkipList.entry(in: $0) }
            .filter { !$0.isEmpty }
    }

    /// Adds `entry` unless present; true if the file changed. Lines and
    /// comments already in the file are kept.
    public static func add(_ entry: String, at url: URL,
                           header: String = "# thinnercore skip list: one path or bundle identifier per line.\n") throws(Problem) -> Bool {
        try refuseRoot()
        let entry = try validated(entry)
        guard try !entries(at: url).contains(entry) else { return false }
        // An unreadable list is an error: rewriting it would lose its entries.
        var text = try SkipList.readText(url) ?? header
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        try write(text + entry + "\n", to: url)
        return true
    }

    /// Removes matching entries, including lines with inline comments.
    public static func remove(_ entry: String, at url: URL) throws(Problem) -> Bool {
        try refuseRoot()
        let entry = try validated(entry)
        guard let text = try SkipList.readText(url) else { return false }
        let lines = text.components(separatedBy: "\n")
        let kept = lines.filter { SkipList.entry(in: Substring($0)) != entry }
        guard kept.count != lines.count else { return false }
        try write(kept.joined(separator: "\n"), to: url)
        return true
    }

    private static func validated(_ entry: String) throws(Problem) -> String {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("#"), !trimmed.contains(where: \.isNewline) else {
            throw Problem("\"\(entry)\" is not a path or bundle identifier")
        }
        return trimmed
    }

    /// Written as root, the file would belong to root in the user's home.
    private static func refuseRoot() throws(Problem) {
        if geteuid() == 0 { throw Problem("edit this list without sudo; runs under sudo read the invoking user's list") }
    }

    private static func write(_ text: String, to url: URL) throws(Problem) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw Problem("cannot create \(url.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        try durablyWrite(Data(text.utf8), to: url)
    }
}

/// The user's allow list: when it has any entry, only the apps it names are
/// ever thinned, and every other app is skipped (`notOnAllowList`). Empty
/// or missing, it has no effect. It only narrows: an app on it still passes
/// every check, and the skip list and `--exclude` win over it.
///
/// The same format as the skip list, in `allow-list.txt` beside it: a path
/// (`/` or `~/`) allows that app or every app below that folder, matched by
/// identity; anything else is a bundle identifier. A list that exists but
/// cannot be read refuses every app, never "everything allowed".
/// Edited through `SkipListFile` with this file's location.
public enum AllowListFile {
    public static let header = "# thinnercore allow list: only these apps are thinned. One path or bundle identifier per line.\n"

    public static func defaultLocation() throws(Problem) -> URL {
        SkipList.allowLocation(home: SkipList.home(of: try RosettaFlags.defaultPreferencesUser().get()))
    }
}

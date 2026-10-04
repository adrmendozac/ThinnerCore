import Foundation

/// An unlocked, read-only snapshot of journals beside the scan root and
/// discovered apps. It is not a global restore index and may become stale.
public struct PendingOperations: Codable, Equatable, Sendable {
    public struct Operation: Codable, Equatable, Sendable {
        public let journalPath: String
        public let bundlePath: String
        public let state: String
    }
    public var operations: [Operation] = []
    public var problems: [String] = []
    public var searchedDirectories: [String] = []

    static func isStagingName(_ name: String) -> Bool {
        name.hasPrefix(".thinner-") && UUID(uuidString: String(name.dropFirst(9))) != nil
    }

    /// Only journals for the requested app, or for apps under the requested
    /// directory, are reported: an app's journals sit in its parent
    /// directory, beside its siblings' journals. A journal that cannot be
    /// read cannot be attributed, so it stays a problem, as it blocks restore.
    public static func read(root: URL, apps: [URL]) -> PendingOperations {
        var snapshot = PendingOperations()
        let rootIsApp = AppScanner.isApp(root.lastPathComponent)
        let rootPaths = Set([root.standardizedFileURL.path, realPath(root.path)].compactMap { $0 })
        func belongs(_ bundlePath: String) -> Bool {
            let candidates = Set([bundlePath, realPath(bundlePath)].compactMap { $0 })
            return candidates.contains { path in
                rootPaths.contains { rootIsApp ? path == $0 : path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
            }
        }
        let directories = Set(([AppScanner.isApp(root.lastPathComponent) ? root.deletingLastPathComponent() : root]
            + apps.map { $0.deletingLastPathComponent() }).map { $0.standardizedFileURL.path })
        for directory in directories.sorted() {
            snapshot.searchedDirectories.append(directory)
            do {
                let tree = try FileTree(URL(filePath: directory))
                for entry in try tree.entries([]) where isStagingName(entry.name) {
                    guard entry.kind == .directory else {
                        snapshot.problems.append("Cannot inspect staging path \(directory)/\(entry.name): not a directory")
                        continue
                    }
                    let journalPath = URL(filePath: directory).appending(path: entry.name).appending(path: Journal.fileName)
                    // Inspect with the no-follow reader, never trust a journal symlink.
                    do {
                        let data = try tree.read([entry.name, Journal.fileName], limit: 16 * 1024 * 1024)
                        let journal = try JSONDecoder().decode(Journal.self, from: data)
                        guard journal.schemaVersion == Journal.schemaVersion else {
                            snapshot.problems.append("Unsupported journal schema at \(journalPath.path)")
                            continue
                        }
                        if journal.state == .inProgress || journal.state == .recoveryFailed, belongs(journal.bundlePath) {
                            snapshot.operations.append(.init(journalPath: journalPath.path, bundlePath: journal.bundlePath, state: journal.state.rawValue))
                        }
                    } catch {
                        snapshot.problems.append("Cannot inspect journal at \(journalPath.path): \(error)")
                    }
                }
            } catch {
                snapshot.problems.append("Cannot inspect journals in \(directory): \(error)")
            }
        }
        snapshot.operations.sort { $0.journalPath < $1.journalPath }
        snapshot.problems.sort()
        return snapshot
    }
}

import Foundation

/// The fixture matrix built by `scripts/make-fixtures.sh`, generated once per
/// test process into a fresh temporary directory.
enum Fixtures {
    static func root() throws -> URL {
        try generated.get()
    }

    static func url(_ relativePath: String) throws -> URL {
        try root().appending(path: relativePath)
    }

    private static let generated: Result<URL, any Error> = Result {
        let packageRoot = URL(filePath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // ThinnerCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
        let out = FileManager.default.temporaryDirectory
            .appending(path: "thinner-fixtures-\(UUID().uuidString)")
        let script = packageRoot.appending(path: "scripts/make-fixtures.sh")
        let result = try Shell.run("/bin/bash", script.path, out.path)
        guard result.status == 0 else {
            throw Shell.Failure(command: script.path, result: result)
        }
        return out
    }
}

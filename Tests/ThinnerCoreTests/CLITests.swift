import Foundation
import Testing
import ThinnerCore

/// Runs the built `thinner` binary. Only ever against fixtures and throwaway
/// directories, never the default /Applications.
@Suite struct CLITests {
    /// The CLI builds next to the test bundle.
    static let binary: URL = {
        let bundle = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }
        let products = bundle?.bundleURL.deletingLastPathComponent()
            ?? URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../.build/debug")
        return products.appending(path: "thinner")
    }()

    private let dir: URL
    private var prefs: String { dir.appending(path: "no-prefs.plist").path }

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "thinner-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Hermetic: never reads the real user's Rosetta settings.
    private func thinner(_ arguments: String...) throws -> Shell.Result {
        try Shell.run(Self.binary.path, arguments: arguments + ["--rosetta-preferences", prefs])
    }

    @Test func jsonScanOfTheFixturesExitsZero() throws {
        defer { cleanUp() }
        let run = try thinner("scan", try Fixtures.root().path, "--json")
        #expect(run.status == 0, "\(run.output)")
        let report = try JSONDecoder().decode(ScanReport.self, from: Data(run.output.utf8))
        #expect(report.complete)
        #expect(report.totals.apps == 3)
        #expect(report.totals.universalFiles == 25)
        #expect(report.totals.eligibleFiles == 15)
        #expect(report.rosetta.preferencesPath == prefs)
    }

    @Test func humanAndJSONReportsAgree() throws {
        defer { cleanUp() }
        let root = try Fixtures.root().path
        let json = try thinner("scan", root, "--json")
        let text = try thinner("scan", root)
        #expect(json.status == 0 && text.status == 0)
        let report = try JSONDecoder().decode(ScanReport.self, from: Data(json.output.utf8))
        #expect(text.output.contains("Total: \(report.totals.apps) apps · \(report.totals.universalFiles) universal files"
            + " · \(report.totals.eligibleFiles) eligible"))
    }

    @Test func scanIsTheDefaultCommandAndExcludeRepeats() throws {
        defer { cleanUp() }
        let run = try thinner(try Fixtures.root().path, "--json",
                              "--exclude", try Fixtures.url("bundles/Nested.app").path,
                              "--exclude", try Fixtures.url("bundles/Signed.app").path)
        #expect(run.status == 0, "\(run.output)")
        let report = try JSONDecoder().decode(ScanReport.self, from: Data(run.output.utf8))
        #expect(report.apps.compactMap(\.skip?.code) == ["excluded", "excluded"])
        #expect(report.excludes.count == 2)
    }

    @Test func invalidArgumentsExitTwo() throws {
        defer { cleanUp() }
        let badOption = try thinner("scan", try Fixtures.root().path, "--no-such-option")
        #expect(badOption.status == 2)
        let missing = try thinner("scan", dir.appending(path: "missing").path)
        #expect(missing.status == 2)
        #expect(missing.output.contains("No such file or directory"))
    }

    @Test func incompleteScanExitsOne() throws {
        let locked = dir.appending(path: "root/Locked")
        defer {
            chmod(locked.path, 0o755)
            cleanUp()
        }
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try #require(chmod(locked.path, 0o000) == 0)
        try #require(getuid() != 0, "root can read anything; this test needs a normal user")

        let run = try thinner("scan", dir.appending(path: "root").path)
        #expect(run.status == 1)
        #expect(run.output.contains("Could not read:"))
        #expect(run.output.contains("Incomplete scan"))
    }

    @Test func symlinkedRootExitsOne() throws {
        defer { cleanUp() }
        let link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: try Fixtures.root())
        let run = try thinner("scan", link.path)
        #expect(run.status == 1)
        #expect(run.output.contains("is a symbolic link"))
    }
}

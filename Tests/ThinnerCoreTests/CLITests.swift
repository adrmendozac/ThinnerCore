import Foundation
import Testing
@testable import ThinnerCore

/// Runs the built `thinnercore` binary. Only ever against fixtures and throwaway
/// directories, never the default /Applications.
@Suite struct CLITests {
    /// The CLI builds next to the test bundle.
    static let binary: URL = {
        let bundle = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }
        let products = bundle?.bundleURL.deletingLastPathComponent()
            ?? URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../.build/debug")
        return products.appending(path: "thinnercore")
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

    private var skipList: String { dir.appending(path: "skip-list.txt").path }
    private var allowList: String { dir.appending(path: "allow-list.txt").path }

    /// Hermetic: never reads the real user's Rosetta settings, skip list, or
    /// allow list.
    private func thinner(_ arguments: String...) throws -> Shell.Result {
        try Shell.run(Self.binary.path, arguments: arguments
            + ["--rosetta-preferences", prefs, "--skip-list", skipList, "--allow-list", allowList])
    }

    @Test func allowCommandEditsTheListAndScansHonorIt() throws {
        defer { cleanUp() }
        let bundles = try Fixtures.url("bundles").path
        let id = "dev.thinner.fixture.signed"
        let empty = try Shell.run(Self.binary.path, "allow", "list", "--allow-list", allowList)
        #expect(empty.output.contains("every app can be thinned"))
        #expect(try Shell.run(Self.binary.path, "allow", "add", id, "--allow-list", allowList).status == 0)
        #expect(try String(contentsOfFile: allowList, encoding: .utf8).hasPrefix("# thinnercore allow list"))

        let run = try thinner("scan", bundles, "--json")
        let report = try JSONDecoder().decode(ScanReport.self, from: Data(run.output.utf8))
        let byID = Dictionary(report.apps.map { ($0.bundleIdentifier ?? $0.path, $0.skip?.code) }) { first, _ in first }
        #expect(byID[id] != "notOnAllowList", "the listed app is allowed")
        #expect(report.apps.filter { $0.bundleIdentifier != id }.allSatisfy { $0.skip != nil }, "every other app is skipped")
        #expect(report.apps.contains { $0.skip?.code == "notOnAllowList" })
        #expect(report.allowList?.entries == 1)
        #expect(try thinner("scan", bundles).output.contains("Allow list: only its 1 entry can be thinned"))

        #expect(try Shell.run(Self.binary.path, "allow", "remove", id, "--allow-list", allowList).status == 0)
        let after = try JSONDecoder().decode(ScanReport.self, from: Data(try thinner("scan", bundles, "--json").output.utf8))
        #expect(!after.apps.contains { $0.skip?.code == "notOnAllowList" }, "an emptied list allows every app")
        #expect(after.allowList == nil)
    }

    @Test func skipCommandEditsTheListAndScansHonorIt() throws {
        defer { cleanUp() }
        let signed = try Fixtures.url("bundles/Signed.app").path
        let id = "dev.thinner.fixture.signed"
        #expect(try Shell.run(Self.binary.path, "skip", "add", id, "--skip-list", skipList).status == 0)
        let again = try Shell.run(Self.binary.path, "skip", "add", id, "--skip-list", skipList)
        #expect(again.output.contains("Already listed"))
        let list = try Shell.run(Self.binary.path, "skip", "list", "--json", "--skip-list", skipList)
        #expect(list.output.contains(id))

        let run = try thinner("scan", signed, "--json")
        let report = try JSONDecoder().decode(ScanReport.self, from: Data(run.output.utf8))
        #expect(report.apps.first?.skip?.code == "skipListed")

        #expect(try Shell.run(Self.binary.path, "skip", "remove", id, "--skip-list", skipList).status == 0)
        #expect(try Shell.run(Self.binary.path, "skip", "remove", id, "--skip-list", skipList).status == 1)
        let after = try thinner("scan", signed, "--json")
        #expect(try JSONDecoder().decode(ScanReport.self, from: Data(after.output.utf8)).apps.first?.skip == nil)
    }

    @Test func jsonScanOfTheFixturesExitsZero() throws {
        defer { cleanUp() }
        let run = try thinner("scan", try Fixtures.root().path, "--json")
        #expect(run.status == 0, "\(run.output)")
        let report = try JSONDecoder().decode(ScanReport.self, from: Data(run.output.utf8))
        #expect(report.complete)
        #expect(report.totals.apps == 4)
        #expect(report.totals.universalFiles == 26)
        #expect(report.totals.eligibleFiles == 13)
        #expect(report.rosetta.preferencesPath == prefs)
    }

    /// The Ink front end pipes stderr and asks for machine-readable progress;
    /// stdout must stay a clean JSON report.
    @Test func jsonProgressGoesToStderrOnly() throws {
        defer { cleanUp() }
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = ["scan", try Fixtures.url("bundles").path, "--json", "--rosetta-preferences", prefs, "--skip-list", skipList, "--allow-list", allowList]
        process.environment = ProcessInfo.processInfo.environment.merging(["THINNERCORE_PROGRESS": "json"]) { $1 }
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let report = try JSONDecoder().decode(ScanReport.self, from: out)
        struct Line: Decodable { let progress: ScanProgress }
        let lines = String(decoding: err, as: UTF8.self).split(separator: "\n")
            .filter { !$0.hasPrefix("WARNING") } // development gate banner, if enabled
        let progress = try lines.map { try JSONDecoder().decode(Line.self, from: Data($0.utf8)).progress }
        #expect(progress.map(\.index) == Array(1...report.apps.count))
        #expect(progress.allSatisfy { $0.total == report.apps.count })
        #expect(progress.map(\.app) == report.apps.map(\.path))
    }

    @Test func humanAndJSONReportsAgree() throws {
        defer { cleanUp() }
        let root = try Fixtures.root().path
        let json = try thinner("scan", root, "--json")
        let text = try thinner("scan", root)
        #expect(json.status == 0 && text.status == 0)
        let report = try JSONDecoder().decode(ScanReport.self, from: Data(json.output.utf8))
        #expect(text.output.contains("Total: \(report.totals.apps) apps (\(report.totals.skippedApps) skipped) · \(report.totals.universalFiles) universal files"
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

    @Test func applyIsGatedAndReportsJSON() throws {
        defer { cleanUp() }
        let run = try thinner(dir.path, "--apply", "--json")
        #expect(run.status == 1)
        let report = try JSONDecoder().decode(MutationReport.self, from: Data(run.output.utf8))
        #expect(report.command == "apply")
        #expect(report.problems.contains(MutationCommands.releaseBlock))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func restoreAndRecoverAreGated() throws {
        defer { cleanUp() }
        for command in ["restore", "recover"] {
            let run = try Shell.run(Self.binary.path, command, dir.path, "--json")
            #expect(run.status == 1)
            let report = try JSONDecoder().decode(MutationReport.self, from: Data(run.output.utf8))
            #expect(report.command == command)
            #expect(report.apps.first?.outcome == .refused)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func pendingJournalsAreReadOnlyAndDriveMutationExitCodes() throws {
        defer { cleanUp() }
        let stage = dir.appending(path: ".thinner-00000000-0000-0000-0000-000000000002")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let journalURL = stage.appending(path: "journal.json")
        var journal = Journal(operationID: "test", bundlePath: dir.appending(path: "Gone.app").path,
                              bundleIdentifier: "fixture", startedAt: "test")
        for state in [Journal.OperationState.inProgress, .recoveryFailed] {
            journal.state = state
            let bytes = try JSONEncoder().encode(journal)
            try bytes.write(to: journalURL)
            let scan = try thinner(dir.path, "--json")
            #expect(scan.status == 0)
            let report = try JSONDecoder().decode(ScanReport.self, from: Data(scan.output.utf8))
            #expect(report.pendingOperations.operations.count == 1)
            let apply = try thinner(dir.path, "--apply", "--json")
            #expect(apply.status == (state == .recoveryFailed ? 4 : 3))
            #expect(try Data(contentsOf: journalURL) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: stage.path) == ["journal.json"])
        }
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

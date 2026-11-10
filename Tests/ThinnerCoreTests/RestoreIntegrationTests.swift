import Foundation
import Testing
@testable import ThinnerCore

/// Exercises real fixture restoration through the CLI's report adapter.
/// Public executable tests remain gated; no runtime mutation bypass is added.
@Suite struct RestoreIntegrationTests {
    private func report(_ copy: ThinnedCopy, _ env: RestoreOperation.Environment = idleEnvironment) throws -> MutationReport {
        let result = RestoreOperation.restoreUnreleased(copy.app, environment: env)
        let report = MutationCommands.restoreReport(copy.app, result)
        let decoded = try JSONDecoder().decode(MutationReport.self, from: Data(report.json().utf8))
        #expect(decoded == report)
        return decoded
    }

    @Test func successAndRepeatedRestore() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let first = try report(copy)
        #expect(first.exitCode == 0)
        #expect(first.apps.first?.outcome == .committed)
        #expect(Set(first.apps.first?.restore?.restored ?? []) == Set(copy.entries.map(\.relativePath)))
        #expect(first.text.contains("Backups retained:"))
        let again = try report(copy)
        #expect(again.exitCode == 0)
        #expect(again.apps.first?.outcome == .nothingToDo)
        #expect(again.apps.first?.restore?.restored.isEmpty == true)
        #expect(Set(again.apps.first?.restore?.alreadyOriginal ?? []) == Set(copy.entries.map(\.relativePath)))
        for entry in copy.entries {
            #expect(try copy.hash(entry.relativePath) == entry.originalHash)
            #expect(try SHA256.hash(file: entry.backupPath) == entry.originalHash)
        }
        #expect(Codesign.verify(copy.app) == nil)
    }

    @Test(arguments: ["changed", "damaged", "running"])
    func refusalIsReported(_ scenario: String) throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        var holder: HeldOpen?
        defer { holder?.stop() }
        var env = idleEnvironment
        switch scenario {
        case "changed":
            try copy.editJournal { journal in
                var identity = journal[AppIdentity.journalKey] as! [String: Any]
                identity["bundleVersion"] = "999"
                journal[AppIdentity.journalKey] = identity
            }
        case "damaged":
            let entry = try #require(copy.entries.first)
            let file = try FileHandle(forWritingTo: URL(filePath: entry.backupPath))
            try file.write(contentsOf: Data([0xFF, 0xFF]))
            try file.close()
        default:
            holder = try HeldOpen(copy.app.appending(path: "Contents/Info.plist"))
            try holder?.waitUntilVisible(in: copy.app)
            env = RestoreOperation.Environment()
        }
        let result = try report(copy, env)
        #expect(result.exitCode == 1)
        #expect(result.apps.first?.outcome == .refused)
        #expect(result.apps.first?.restore?.restored.isEmpty == true)
        #expect(try copy.allStillThinned())
        #expect(!FileManager.default.fileExists(atPath: copy.staging.appending(path: "restore.json").path))
    }

    @Test func pendingThenRetryAndVerificationFailure() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        var env = idleEnvironment
        var swapped = false
        env.boundary = { point, _ in if point == "restore-swapped" { swapped = true } }
        env.usage = { url throws(Problem) in
            swapped ? BundleUsage.Result(uses: [.init(pid: 4242, how: .executable, path: url.path)]) : BundleUsage.Result()
        }
        let pending = try report(copy, env)
        #expect(pending.exitCode == 3)
        #expect(pending.apps.first?.outcome == .recoveryPending)
        #expect(pending.apps.first?.restore?.restored.count == 1)
        #expect(pending.text.contains("Run restore again"))
        var failing = idleEnvironment
        failing.verify = { _ in "fixture verification failure" }
        let failed = try report(copy, failing)
        #expect(failed.exitCode == 4)
        #expect(failed.apps.first?.outcome == .recoveryFailed)
        #expect(failed.text.contains("fixture verification failure"))
        for entry in copy.entries {
            #expect(try SHA256.hash(file: entry.backupPath) == entry.originalHash)
        }
    }

    @Test func executableKeepsFixtureAndPendingJournalsUntouched() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        for state in ["committed", "inProgress", "recoveryFailed"] {
            try copy.editJournal { $0["state"] = state }
            let before = try Data(contentsOf: copy.journalURL)
            let run = try Shell.run(CLITests.binary.path, "restore", copy.app.path, "--json")
            let decoded = try JSONDecoder().decode(MutationReport.self, from: Data(run.output.utf8))
            let code: Int32 = state == "committed" ? 1 : state == "inProgress" ? 3 : 4
            #expect(run.status == code)
            #expect(decoded.exitCode == code)
            let text = try Shell.run(CLITests.binary.path, "restore", copy.app.path)
            #expect(text.status == code)
            #expect(text.output.trimmingCharacters(in: .whitespacesAndNewlines) == decoded.text)
            #expect(try Data(contentsOf: copy.journalURL) == before)
            #expect(try copy.allStillThinned())
            #expect(!FileManager.default.fileExists(atPath: copy.staging.appending(path: "restore.json").path))
        }
    }

    @Test func executableHelpAndArguments() throws {
        let help = try Shell.run(CLITests.binary.path, "restore", "--help")
        #expect(help.status == 0)
        #expect(help.output.contains("backups"))
        #expect(help.output.contains("release gate"))
        for args in [["restore"], ["restore", "--unknown"], ["restore", "one", "two"]] {
            #expect(try Shell.run(CLITests.binary.path, arguments: args).status == 2)
        }
    }
}

import Foundation
import Testing
@testable import ThinnerCore

@Suite struct RestoreCLIIntegrationTests {
    @Test func successfulRestore() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let result = RestoreOperation.restoreUnreleased(copy.app, environment: idleEnvironment)
        let report = MutationCommands.restoreReport(copy.app, result)
        
        #expect(report.exitCode == 0)
        #expect(report.apps.first?.outcome == .committed)
        
        let text = report.text
        #expect(text.contains("committed — Original files restored and verified; backups retained."))
        #expect(text.contains("Restored: Contents/MacOS/Signed"))
        #expect(text.contains("Backups retained: \(copy.staging.path)") || text.contains("Backups retained: /private\(copy.staging.path)"))
        
        let json = try report.json()
        #expect(json.contains("\"outcome\" : \"committed\""))
        #expect(json.contains("\"command\" : \"restore\""))
    }

    @Test func repeatedRestore() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        _ = RestoreOperation.restoreUnreleased(copy.app, environment: idleEnvironment)
        let result = RestoreOperation.restoreUnreleased(copy.app, environment: idleEnvironment)
        let report = MutationCommands.restoreReport(copy.app, result)
        
        #expect(report.exitCode == 0)
        #expect(report.apps.first?.outcome == .nothingToDo)
        let text = report.text
        #expect(text.contains("nothingToDo — every thinned file already holds its original"))
        #expect(text.contains("Already original: Contents/MacOS/Signed"))
    }

    @Test func changedApp() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let changed = try #require(copy.entries.first)
        let handle = try FileHandle(forWritingTo: copy.app.appending(path: changed.relativePath))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()

        let result = RestoreOperation.restoreUnreleased(copy.app, environment: idleEnvironment)
        let report = MutationCommands.restoreReport(copy.app, result)
        
        #expect(report.exitCode == 1)
        #expect(report.apps.first?.outcome == .refused)
        #expect(report.text.contains("refused — these files match neither their original nor their thinned version"))
    }

    @Test func damagedBackup() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let damaged = try #require(copy.entries.last)
        let handle = try FileHandle(forUpdating: URL(filePath: damaged.backupPath))
        try handle.write(contentsOf: Data([0xFF, 0xFF]))
        try handle.close()

        let result = RestoreOperation.restoreUnreleased(copy.app, environment: idleEnvironment)
        let report = MutationCommands.restoreReport(copy.app, result)
        
        #expect(report.exitCode == 1)
        #expect(report.apps.first?.outcome == .refused)
        #expect(report.text.contains("refused — the backup of \(damaged.relativePath) is damaged"))
    }

    @Test func runningProcessRefusal() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        var env = idleEnvironment
        env.usage = { url in BundleUsage.Result(uses: [.init(pid: 1234, how: .executable, path: url.path + "/Contents/MacOS/Signed")]) }
        
        let result = RestoreOperation.restoreUnreleased(copy.app, environment: env)
        let report = MutationCommands.restoreReport(copy.app, result)
        
        #expect(report.exitCode == 1)
        #expect(report.apps.first?.outcome == .refused)
        #expect(report.text.contains("refused — the app is in use: process 1234 runs"))
    }

    @Test func pendingRecoveryReporting() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try #require(copy.entries.count >= 2)
        var calls = 0
        var env = idleEnvironment
        env.usage = { url throws(Problem) in
            calls += 1
            if calls >= 3 { return BundleUsage.Result(uses: [.init(pid: 4242, how: .executable, path: url.path)]) }
            return BundleUsage.Result()
        }

        let result = RestoreOperation.restoreUnreleased(copy.app, environment: env)
        let report = MutationCommands.restoreReport(copy.app, result)
        
        #expect(report.exitCode == 3)
        #expect(report.apps.first?.outcome == .recoveryPending)
        #expect(report.text.contains("recoveryPending — the app is in use: process 4242 runs"))
        #expect(report.text.contains("every file is individually valid"))
    }

    @Test func failedRecoveryReporting() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        var env = idleEnvironment
        env.verify = { _ in "simulated verification failure" }
        
        let result = RestoreOperation.restoreUnreleased(copy.app, environment: env)
        let report = MutationCommands.restoreReport(copy.app, result)
        
        #expect(report.exitCode == 4)
        #expect(report.apps.first?.outcome == .recoveryFailed)
        #expect(report.text.contains("recoveryFailed — every restored file matches its original, but the app does not verify: simulated verification failure"))
    }
}

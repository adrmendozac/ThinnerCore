import Testing
import Foundation
@testable import ThinnerCore

@Suite struct ThinOperationTests {
    let dir: URL
    let app: URL
    /// No LaunchServices preferences: no app is set to Open using Rosetta.
    let options: ScanOptions

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("thinner-op-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        app = dir.appendingPathComponent("Signed.app")
        try #require(try Shell.run("/usr/bin/ditto", Fixtures.url("bundles/Signed.app").path, app.path).status == 0)
        options = ScanOptions(launchServicesPreferences: dir.appending(path: "no-prefs.plist"))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Hashes of every eligible file, relative path to SHA-256.
    func eligibleHashes() throws -> [String: String] {
        var hashes: [String: String] = [:]
        for file in BundleClassifier.classify(app).files where file.isEligible {
            hashes[file.relativePath] = try SHA256.hash(file: app.appending(path: file.relativePath).path)
        }
        return hashes
    }

    func stagingJournal() throws -> Journal {
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter(RestoreOperation.isStagingName)
        let name = try #require(names.count == 1 ? names.first : nil, "expected one staging directory, found \(names)")
        return try #require(try Journal.load(from: dir.appending(path: name).appending(path: Journal.fileName)))
    }

    @Test func libraryWriterRespectsReleaseGate() throws {
        defer { cleanUp() }
        let exeURL = app.appendingPathComponent("Contents/MacOS/Signed")
        let before = try Data(contentsOf: exeURL)
        let outcome = try ThinOperation.apply(to: app)
        #expect(outcome == .skipped(reason: MutationCommands.releaseBlock))
        #expect(try Data(contentsOf: exeURL) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Signed.app"])
    }

    /// Regression: the writer recorded no app identity, so restore refused
    /// every journal it wrote; and it left a lock file beside the app.
    @Test func writerRecordsIdentityAndRestoreUndoesIt() throws {
        defer { cleanUp() }
        let originals = try eligibleHashes()
        try #require(!originals.isEmpty)

        #expect(try ThinOperation.applyUnreleased(to: app, options: options, environment: idleEnvironment) == .committed)
        for path in originals.keys {
            #expect(try Shell.run("/usr/bin/lipo", "-archs", app.appending(path: path).path).output
                .trimmingCharacters(in: .whitespacesAndNewlines) == "arm64")
        }
        #expect(Codesign.verify(app) == nil)
        let journal = try stagingJournal()
        #expect(journal.state == .committed)
        #expect(journal.appIdentity == (try AppIdentity.of(app)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".thinner-") } == ["Signed.app"])

        let restored = RestoreOperation.restore(app, environment: idleEnvironment)
        #expect(restored.outcome == .restored)
        #expect(try eligibleHashes() == originals)
    }

    /// Regression: rollback renamed the backups into the app and never
    /// checked the restored hashes.
    @Test func rollbackPutsOriginalsBackAndKeepsEveryBackup() throws {
        defer { cleanUp() }
        let originals = try eligibleHashes()
        var env = idleEnvironment
        env.verify = verifyFailing(on: [2])   // before thinning passes, after fails

        let outcome = try ThinOperation.applyUnreleased(to: app, options: options, environment: env)
        guard case .rolledBack(let reason) = outcome else {
            Issue.record("expected rolledBack, got \(outcome)")
            return
        }
        #expect(reason.contains("verification failed after thinning"))
        #expect(try eligibleHashes() == originals)
        #expect(Codesign.verify(app) == nil)
        let journal = try stagingJournal()
        #expect(journal.state == .rolledBack)
        for entry in journal.entries {
            #expect(entry.state == .restored)
            #expect(try SHA256.hash(file: entry.backupPath) == entry.originalHash, "the backup survives")
        }
    }

    /// Regression: the writer classified files directly and skipped every
    /// app-level rule.
    @Test func writerHonorsAUserExclusion() throws {
        defer { cleanUp() }
        let originals = try eligibleHashes()
        let excluding = ScanOptions(excludes: [app], launchServicesPreferences: options.launchServicesPreferences)
        let outcome = try ThinOperation.applyUnreleased(to: app, options: excluding, environment: idleEnvironment)
        guard case .skipped(let reason) = outcome else {
            Issue.record("expected skipped, got \(outcome)")
            return
        }
        #expect(reason.contains("excluded"))
        #expect(try eligibleHashes() == originals)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Signed.app"])
    }

    @Test func writerHonorsOpenUsingRosetta() throws {
        defer { cleanUp() }
        let originals = try eligibleHashes()
        let prefs = dir.appending(path: "LaunchServices.plist")
        try PropertyListSerialization.data(fromPropertyList: [
            "Architectures(arm64)": ["dev.thinner.fixture.signed": [Data([1]), "x86_64"]],
        ], format: .binary, options: 0).write(to: prefs)

        let outcome = try ThinOperation.applyUnreleased(to: app, options: ScanOptions(launchServicesPreferences: prefs),
                                                        environment: idleEnvironment)
        guard case .skipped(let reason) = outcome else {
            Issue.record("expected skipped, got \(outcome)")
            return
        }
        #expect(reason.contains("Open using Rosetta"))
        #expect(try eligibleHashes() == originals)
    }

    /// Regression: incomplete process visibility was treated as idle.
    @Test func writerRefusesWithIncompleteProcessVisibility() throws {
        defer { cleanUp() }
        var env = idleEnvironment
        env.usage = { _ throws(Problem) in BundleUsage.Result(uninspectable: 3) }
        let outcome = try ThinOperation.applyUnreleased(to: app, options: options, environment: env)
        guard case .skipped(let reason) = outcome else {
            Issue.record("expected skipped, got \(outcome)")
            return
        }
        #expect(reason.contains("could not be inspected"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Signed.app"])
    }

    @Test func writerWaitsForTheAppLock() throws {
        defer { cleanUp() }
        let lock = try AppLock(try #require(realPath(app.path)))
        let outcome = try ThinOperation.applyUnreleased(to: app, options: options, environment: idleEnvironment)
        withExtendedLifetime(lock) {}
        guard case .skipped(let reason) = outcome else {
            Issue.record("expected skipped, got \(outcome)")
            return
        }
        #expect(reason.contains("another operation"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Signed.app"])
    }

    /// Regression: an app with an unreadable part was reported as pending
    /// recovery (exit code 3) even when no recovery was waiting. It is an
    /// ordinary skip.
    @Test func unreadableAppWithoutPendingRecoveryIsSkipped() throws {
        let resources = app.appending(path: "Contents/Resources")
        defer {
            chmod(resources.path, 0o755)
            cleanUp()
        }
        try #require(getuid() != 0, "root can read anything; this test needs a normal user")
        try #require(chmod(resources.path, 0o000) == 0)

        let outcome = try ThinOperation.applyUnreleased(to: app, options: options, environment: idleEnvironment)
        guard case .skipped = outcome else {
            Issue.record("expected skipped, got \(outcome)")
            return
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Signed.app"])
    }

    /// With a recovery waiting, the same unreadable app stays pending: the
    /// recovery cannot be judged without the whole app.
    @Test func unreadableAppWithPendingRecoveryStaysPending() throws {
        let copy = try ThinnedCopy()
        let resources = copy.app.appending(path: "Contents/Resources")
        defer {
            chmod(resources.path, 0o755)
            copy.remove()
        }
        try copy.editJournal { $0["state"] = Journal.OperationState.inProgress.rawValue }
        try #require(getuid() != 0, "root can read anything; this test needs a normal user")
        try #require(chmod(resources.path, 0o000) == 0)

        let outcome = try ThinOperation.applyUnreleased(to: copy.app, options: ScanOptions(
            launchServicesPreferences: copy.dir.appending(path: "no-prefs.plist")), environment: idleEnvironment)
        guard case .pending(let reason) = outcome else {
            Issue.record("expected pending, got \(outcome)")
            return
        }
        #expect(reason.contains("before recovery"))
        #expect(try copy.allStillThinned())
    }
}

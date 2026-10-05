import Darwin
import Foundation
import Testing
@testable import ThinnerCore

/// The Phase 4 failure cases not covered elsewhere: an unsuitable host, low
/// disk space, permission denial, runs that mix privilege levels, and a dry
/// run while another operation holds the app. Disposable fixture copies only.
@Suite struct PreflightFailureTests {
    func stagingNames(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter(RestoreOperation.isStagingName)
    }

    // MARK: - Host

    @Test(arguments: [HostGate.Refusal.notARM64, .translated])
    func unsuitableHostChangesNothing(_ refusal: HostGate.Refusal) throws {
        let fixture = try ThinOperationTests()
        defer { fixture.cleanUp() }
        let originals = try fixture.eligibleHashes()
        var env = idleEnvironment
        env.host = { refusal }

        #expect(try ThinOperation.applyUnreleased(to: fixture.app, options: fixture.options, environment: env)
            == .skipped(reason: refusal.description))
        #expect(try fixture.eligibleHashes() == originals)
        #expect(try stagingNames(fixture.dir).isEmpty)
    }

    @Test(arguments: [HostGate.Refusal.notARM64, .translated])
    func unsuitableHostDoesNotRecover(_ refusal: HostGate.Refusal) throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try copy.editJournal { $0["state"] = "inProgress" }
        let before = try Data(contentsOf: copy.journalURL)
        var env = idleEnvironment
        env.host = { refusal }

        #expect(ThinOperation.recoverUnreleased(copy.app, environment: env) == .skipped(reason: refusal.description))
        #expect(try Data(contentsOf: copy.journalURL) == before)
        #expect(try copy.allStillThinned())
    }

    // MARK: - Disk space

    /// Free space must cover the thinned files plus the reserve before the
    /// staging directory is even created.
    @Test func lowDiskSpaceRefusesBeforeAnyChange() throws {
        let fixture = try ThinOperationTests()
        defer { fixture.cleanUp() }
        let originals = try fixture.eligibleHashes()
        var env = idleEnvironment
        env.freeSpace = { _ in StagingArea.reserve }

        #expect {
            try ThinOperation.applyUnreleased(to: fixture.app, options: fixture.options, environment: env)
        } throws: { error in
            (error as? Problem)?.description.contains("insufficient free space") == true
        }
        #expect(try fixture.eligibleHashes() == originals)
        #expect(try stagingNames(fixture.dir).isEmpty)
    }

    // MARK: - Permission denial

    /// A directory in the app that cannot be written: the swap into it fails
    /// after earlier files were replaced, and rollback puts those back.
    @Test func permissionDeniedMidwayRollsBackCleanly() throws {
        let fixture = try ThinOperationTests()
        let macOS = fixture.app.appending(path: "Contents/MacOS")
        defer {
            chmod(macOS.path, 0o755)
            fixture.cleanUp()
        }
        let originals = try fixture.eligibleHashes()
        let order = BundleClassifier.classify(fixture.app).files.filter(\.isEligible).map(\.relativePath)
        let denied = try #require(order.firstIndex { $0.hasPrefix("Contents/MacOS/") })
        try #require(denied > 0, "the denied file must not be the first one replaced: \(order)")
        try #require(chmod(macOS.path, 0o555) == 0)

        let outcome = try ThinOperation.applyUnreleased(to: fixture.app, options: fixture.options, environment: idleEnvironment)
        guard case let .rolledBack(reason) = outcome else { Issue.record("\(outcome)"); return }
        #expect(reason.contains("Permission denied"))
        #expect(try fixture.eligibleHashes() == originals)
        #expect(Codesign.verify(fixture.app) == nil)
        let journal = try fixture.stagingJournal()
        #expect(journal.state == .rolledBack)
        #expect(try journal.entries.allSatisfy { try SHA256.hash(file: $0.backupPath) == $0.originalHash })
    }

    // MARK: - Mixed privilege levels

    /// A staging directory root made refuses an unprivileged run with the
    /// sudo command to rerun. Only root can create one, so this checks the
    /// rule against a directory root already owns.
    @Test func rootOwnedStagingNamesTheSudoCommand() throws {
        let refusal = try #require(StagingOwner.refusal(URL(filePath: "/usr"), euid: 501, rerun: "recover",
                                                        app: "/Applications/My App.app"))
        #expect(refusal.contains("sudo thinnercore recover '/Applications/My App.app'"))
        #expect(StagingOwner.refusal(URL(filePath: "/usr"), euid: 0, rerun: "recover", app: "/x.app") == nil)
    }

    @Test func recoverRefusesAnotherUsersOperation() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try copy.editJournal { $0["state"] = "inProgress" }
        let before = try Data(contentsOf: copy.journalURL)
        var env = idleEnvironment
        env.euid = { 0 }

        let outcome = ThinOperation.recoverUnreleased(copy.app, environment: env)
        guard case let .pending(reason) = outcome else { Issue.record("\(outcome)"); return }
        #expect(reason.contains("without sudo") && reason.contains("thinnercore recover"))
        #expect(try Data(contentsOf: copy.journalURL) == before)
        #expect(try copy.allStillThinned())
        #expect(try FileManager.default.contentsOfDirectory(atPath: copy.staging.path).sorted() == ["backups", "journal.json", "temps"])
    }

    @Test func applyRefusesAnotherUsersPendingOperation() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try copy.editJournal { $0["state"] = "inProgress" }
        let before = try Data(contentsOf: copy.journalURL)
        var env = idleEnvironment
        env.euid = { geteuid() + 1 }

        let options = ScanOptions(launchServicesPreferences: copy.dir.appending(path: "no-prefs.plist"))
        let outcome = try ThinOperation.applyUnreleased(to: copy.app, options: options, environment: env)
        guard case let .pending(reason) = outcome else { Issue.record("\(outcome)"); return }
        #expect(reason.contains("rerun as that user"))
        #expect(try Data(contentsOf: copy.journalURL) == before)
        #expect(try stagingNames(copy.dir) == [copy.staging.lastPathComponent])
    }

    @Test func restoreRefusesAnotherUsersBackups() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        var env = idleEnvironment
        env.euid = { 0 }

        let outcome = RestoreOperation.restoreUnreleased(copy.app, environment: env).outcome
        guard case let .refused(reason) = outcome else { Issue.record("\(outcome)"); return }
        #expect(reason.contains("thinnercore restore"))
        #expect(try copy.allStillThinned())
        // Not even its lock file or restore record was written.
        #expect(try FileManager.default.contentsOfDirectory(atPath: copy.staging.path).sorted() == ["backups", "journal.json", "temps"])
    }

    // MARK: - Dry runs

    /// A scan never takes or waits for a lock: it reports an unfinished
    /// operation while another process holds the app, as during an apply,
    /// and writes nothing.
    @Test func dryRunDuringAnApplyNeitherWaitsNorWrites() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try copy.editJournal { $0["state"] = "inProgress" }
        let before = try Data(contentsOf: copy.journalURL)
        let holder = try HeldAppLock(copy.app)
        defer { holder.stop() }

        let options = ScanOptions(launchServicesPreferences: copy.dir.appending(path: "no-prefs.plist"))
        let report = ScanReport(root: copy.dir, excludes: [], result: AppScanner.scan(copy.dir, options: options))

        #expect(report.pendingOperations.operations.map(\.journalPath) == [copy.journalURL.path])
        #expect(try Data(contentsOf: copy.journalURL) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: copy.staging.path).sorted() == ["backups", "journal.json", "temps"])
    }

    /// The scan shows retained backup bytes beside the bytes thinning removed.
    @Test func scanReportsRetainedBackupsBesideRemovedBytes() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let options = ScanOptions(launchServicesPreferences: copy.dir.appending(path: "no-prefs.plist"))
        func scan() -> ScanReport {
            ScanReport(root: copy.dir, excludes: [], result: AppScanner.scan(copy.dir, options: options))
        }
        let retained = copy.entries.map(\.originalSize).reduce(0, +)
        let removed = copy.entries.map { $0.originalSize - $0.thinnedSize! }.reduce(0, +)
        try #require(removed > 0)

        let thinned = scan()
        #expect(thinned.backups.sets.map(\.stagingPath) == [copy.staging.path])
        #expect(thinned.backups.retainedBytes == retained)
        #expect(thinned.backups.removedBytes == removed)
        #expect(thinned.complete)
        let json = try #require(JSONSerialization.jsonObject(with: Data(thinned.json().utf8)) as? [String: Any])
        let backups = try #require(json["backups"] as? [String: Any])
        #expect(backups["retainedBytes"] as? Int == Int(retained))
        #expect(backups["removedBytes"] as? Int == Int(removed))
        #expect(TextReport.render(thinned).contains("Retained backups: 1 backup set"))

        #expect(RestoreOperation.restoreUnreleased(copy.app, environment: idleEnvironment).outcome == .restored)
        let restored = scan()
        #expect(restored.backups.retainedBytes == retained)
        #expect(restored.backups.removedBytes == 0)
        #expect(restored.backups.sets.first?.restoreState == "restored")
    }
}

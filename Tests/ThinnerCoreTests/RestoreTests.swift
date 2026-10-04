import Foundation
import Testing
@testable import ThinnerCore

/// A copy of a fixture app, thinned the way the write path thins: clonefile
/// backups and `lipo -remove` output in a `.thinner-<UUID>` staging directory
/// beside the app, each file swapped in by rename(2), and a journal that
/// records the app identity. Disposable; never an installed app.
struct ThinnedCopy {
    let dir: URL
    let app: URL
    let staging: URL
    var journalURL: URL { staging.appending(path: Journal.fileName) }
    let entries: [Journal.Entry]

    init(_ fixture: String = "bundles/Signed.app", recordIdentity: Bool = true,
         relativePathOverride: String? = nil) throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "thinner-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = try Fixtures.url(fixture)
        app = dir.appending(path: source.lastPathComponent)
        try #require(try Shell.run("/usr/bin/ditto", source.path, app.path).status == 0)
        let identity = try AppIdentity.of(app)

        let operationID = UUID().uuidString
        staging = dir.appending(path: ".thinner-\(operationID)")
        let eligible = BundleClassifier.classify(app).files.filter(\.decision.isEligible)
        try #require(!eligible.isEmpty)

        var entries: [Journal.Entry] = []
        for file in eligible {
            guard case let .eligible(removing, _) = file.decision else { continue }
            let target = app.appending(path: file.relativePath).path
            let backup = staging.appending(path: "backups/\(file.relativePath)")
            let temp = staging.appending(path: "temps/\(file.relativePath)")
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: temp.deletingLastPathComponent(), withIntermediateDirectories: true)

            let originalHash = try SHA256.hash(file: target)
            try #require(clonefile(target, backup.path, 0x0001) == 0)
            let removals = removing.flatMap { ["-remove", $0.description] }
            try #require(try Shell.run("/usr/bin/lipo", arguments: [target] + removals + ["-output", temp.path]).status == 0)
            try #require(chmod(temp.path, 0o755) == 0)
            let thinnedHash = try SHA256.hash(file: temp.path)
            let thinnedSize = try #require(FileIdentity.of(temp.path)).size
            try #require(rename(temp.path, target) == 0)
            entries.append(Journal.Entry(
                relativePath: relativePathOverride ?? file.relativePath, originalHash: originalHash,
                thinnedHash: thinnedHash, arm64SliceHash: "", backupPath: backup.path, tempPath: nil,
                originalSize: file.size, thinnedSize: thinnedSize, state: .committed))
        }
        self.entries = entries

        var journal = Journal(operationID: operationID, bundlePath: app.path, bundleIdentifier: identity.bundleIdentifier,
                              startedAt: ISO8601DateFormatter().string(from: Date()))
        journal.state = .committed
        journal.entries = entries
        journal.plannedFiles = entries.map(\.relativePath)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(journal)) as? [String: Any])
        if recordIdentity {
            object[AppIdentity.journalKey] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(identity))
        }
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: journalURL)
    }

    func hash(_ relativePath: String) throws -> String {
        try SHA256.hash(file: app.appending(path: relativePath).path)
    }

    func editJournal(_ change: (inout [String: Any]) -> Void) throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
        change(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: journalURL)
    }

    func restoreRecord() throws -> [String: Any] {
        let data = try Data(contentsOf: staging.appending(path: "restore.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func allStillThinned() throws -> Bool {
        try entries.allSatisfy { try hash($0.relativePath) == $0.thinnedHash }
    }

    func remove() {
        try? FileManager.default.removeItem(at: dir)
    }
}

/// No process uses the app; codesign is real.
private var idle: RestoreOperation.Environment {
    RestoreOperation.Environment(usage: { _ throws(Problem) in BundleUsage.Result() })
}

@Suite struct RestoreTests {
    @Test func restoresEveryThinnedFileAndKeepsBackups() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try #require(Codesign.verify(copy.app) == nil)

        let result = RestoreOperation.restoreUnreleased(copy.app, environment: idle)
        #expect(result.outcome == .restored, "\(result.outcome) \(result.notes)")
        #expect(Set(result.restored) == Set(copy.entries.map(\.relativePath)))
        for entry in copy.entries {
            #expect(try copy.hash(entry.relativePath) == entry.originalHash)
            let archs = try Shell.run("/usr/bin/lipo", "-archs", copy.app.appending(path: entry.relativePath).path).output
            #expect(archs.contains("x86_64"))
            #expect(try SHA256.hash(file: entry.backupPath) == entry.originalHash, "backup must survive the restore")
        }
        #expect(Codesign.verify(copy.app) == nil)
        #expect(try copy.restoreRecord()["state"] as? String == "restored")
    }

    /// Regression (Greptile): the public restore changed apps while the
    /// release gate was closed, unlike `apply` and `recover`.
    @Test func libraryRestoreRespectsReleaseGate() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let result = RestoreOperation.restore(copy.app)
        #expect(result.outcome == .refused(MutationCommands.releaseBlock))
        #expect(try copy.allStillThinned())
        #expect(!FileManager.default.fileExists(atPath: copy.staging.appending(path: "restore.json").path))
    }

    /// Regression (Greptile): a backup set from an earlier version refused
    /// every restore. Thin v1, update to v2 (undoing the thinning), thin v2:
    /// restore must put v2's originals back and keep v1's set untouched.
    @Test func restoreAfterUpdateAndRethinIgnoresTheOlderVersionsBackups() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let v1Backups = try copy.entries.map { ($0.backupPath, try SHA256.hash(file: $0.backupPath)) }

        // The update: a fresh universal copy with a new version and signature.
        try FileManager.default.removeItem(at: copy.app)
        try #require(try Shell.run("/usr/bin/ditto", Fixtures.url("bundles/Signed.app").path, copy.app.path).status == 0)
        let plistURL = copy.app.appending(path: "Contents/Info.plist")
        var plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        plist["CFBundleVersion"] = "2"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        try #require(try Shell.run("/usr/bin/codesign", "--force", "--sign", "-", copy.app.path).status == 0)
        let v2Originals = Dictionary(uniqueKeysWithValues: try copy.entries.map { ($0.relativePath, try copy.hash($0.relativePath)) })

        let options = ScanOptions(launchServicesPreferences: copy.dir.appending(path: "no-prefs.plist"))
        #expect(try ThinOperation.applyUnreleased(to: copy.app, options: options, environment: idleEnvironment) == .committed)

        let result = RestoreOperation.restoreUnreleased(copy.app, environment: idle)
        #expect(result.outcome == .restored, "\(result.outcome)")
        for (path, hash) in v2Originals { #expect(try copy.hash(path) == hash, "v2's original is back: \(path)") }
        #expect(Codesign.verify(copy.app) == nil)
        #expect(result.notes.contains { $0.contains(copy.staging.path) && $0.contains("another version") })
        for (path, hash) in v1Backups { #expect(try SHA256.hash(file: path) == hash, "v1's backup is kept: \(path)") }
        #expect(!FileManager.default.fileExists(atPath: copy.staging.appending(path: "restore.json").path),
                "v1's set is not touched")
    }

    @Test func secondRestoreFindsNothingToDo() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        #expect(RestoreOperation.restoreUnreleased(copy.app, environment: idle).outcome == .restored)

        let again = RestoreOperation.restoreUnreleased(copy.app, environment: idle)
        guard case .nothingToRestore = again.outcome else {
            Issue.record("expected nothing to restore, got \(again.outcome)")
            return
        }
        #expect(Set(again.alreadyOriginal) == Set(copy.entries.map(\.relativePath)))
    }

    @Test func thinningLeavesAppIdentityUnchanged() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let source = try AppIdentity.of(Fixtures.url("bundles/Signed.app"))
        #expect(try AppIdentity.of(copy.app) == source)
    }

    @Test func refusesARecordWithoutAppIdentity() throws {
        let copy = try ThinnedCopy(recordIdentity: false)
        defer { copy.remove() }
        let result = RestoreOperation.restoreUnreleased(copy.app, environment: idle)
        try expectRefused(result, containing: "which version")
        #expect(try copy.allStillThinned())
    }

    @Test func refusesBackupsFromAnotherVersion() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try copy.editJournal { journal in
            var identity = journal[AppIdentity.journalKey] as! [String: Any]
            identity["bundleVersion"] = "999"
            journal[AppIdentity.journalKey] = identity
        }
        try expectRefused(RestoreOperation.restoreUnreleased(copy.app, environment: idle), containing: "changed since it was thinned")
        #expect(try copy.allStillThinned())
    }

    @Test func refusesWhenAFileChangedSinceThinning() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let changed = try #require(copy.entries.first)
        let handle = try FileHandle(forWritingTo: copy.app.appending(path: changed.relativePath))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()

        try expectRefused(RestoreOperation.restoreUnreleased(copy.app, environment: idle), containing: changed.relativePath)
        for entry in copy.entries.dropFirst() {
            #expect(try copy.hash(entry.relativePath) == entry.thinnedHash)
        }
    }

    @Test func refusesADamagedBackupBeforeChangingAnything() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let damaged = try #require(copy.entries.last)
        let handle = try FileHandle(forUpdating: URL(filePath: damaged.backupPath))
        try handle.write(contentsOf: Data([0xFF, 0xFF]))
        try handle.close()

        try expectRefused(RestoreOperation.restoreUnreleased(copy.app, environment: idle), containing: "damaged")
        #expect(try copy.allStillThinned())
    }

    @Test func refusesWhileAProcessHasABundleFileOpen() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let holder = try HeldOpen(copy.app.appending(path: "Contents/Info.plist"))
        defer { holder.stop() }
        try holder.waitUntilVisible(in: copy.app)

        try expectRefused(RestoreOperation.restoreUnreleased(copy.app), containing: "in use")
        #expect(try copy.allStillThinned())
    }

    /// Regression: the check before any change only noted processes it could
    /// not inspect, and the refusal came later, per swap, after originals had
    /// been prepared. Incomplete visibility must refuse before restore writes
    /// a record or a temporary file.
    @Test func refusesWithIncompleteProcessVisibilityBeforeChangingAnything() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let before = FileManager.default.subpaths(atPath: copy.staging.path)?.sorted()
        var env = idle
        env.usage = { _ throws(Problem) in BundleUsage.Result(uninspectable: 1) }

        try expectRefused(RestoreOperation.restoreUnreleased(copy.app, environment: env), containing: "could not be inspected")
        #expect(try copy.allStillThinned())
        // Only the backups' own `StagingLock` file may appear.
        let after = FileManager.default.subpaths(atPath: copy.staging.path)?.filter { $0 != ".lock" }.sorted()
        #expect(after == before, "no restore record and no temporary file")
    }

    @Test func stopsPartWayWhenTheAppStartsAndResumesLater() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        try #require(copy.entries.count >= 2)

        // Preflight and the first file's recheck see nothing; the second file's
        // recheck sees a process.
        let calls = Counter()
        var env = idle
        env.usage = { url throws(Problem) in
            calls.value += 1
            guard calls.value >= 3 else { return BundleUsage.Result() }
            return BundleUsage.Result(uses: [.init(pid: 4242, how: .executable, path: url.path + "/Contents/MacOS/Signed")])
        }
        let first = RestoreOperation.restoreUnreleased(copy.app, environment: env)
        guard case .pending = first.outcome else {
            Issue.record("expected pending, got \(first.outcome)")
            return
        }
        #expect(first.outcome.exitCode == 3)
        #expect(first.restored.count == 1)
        #expect(Codesign.verify(copy.app) == nil, "a part-way restore leaves every file individually valid")
        #expect(try copy.restoreRecord()["state"] as? String == "pending")

        let second = RestoreOperation.restoreUnreleased(copy.app, environment: idle)
        #expect(second.outcome == .restored)
        #expect(second.alreadyOriginal == first.restored)
        #expect(second.restored.count == copy.entries.count - 1)
    }

    @Test func failedVerificationKeepsEverything() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        var env = idle
        env.verify = { _ in "simulated verification failure" }

        let result = RestoreOperation.restoreUnreleased(copy.app, environment: env)
        guard case .recoveryFailed(let reason) = result.outcome else {
            Issue.record("expected recovery failure, got \(result.outcome)")
            return
        }
        #expect(reason.contains("simulated"))
        #expect(result.outcome.exitCode == 4)
        for entry in copy.entries {
            #expect(try SHA256.hash(file: entry.backupPath) == entry.originalHash)
        }
        #expect(try copy.restoreRecord()["state"] as? String == "recoveryFailed")
    }

    @Test func refusesWhileAnotherOperationHoldsTheBackups() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let lock = try StagingLock(copy.staging)
        try expectRefused(RestoreOperation.restoreUnreleased(copy.app, environment: idle), containing: "another operation")
        withExtendedLifetime(lock) {}
        #expect(try copy.allStillThinned())
    }

    @Test func refusesARecordThatPointsOutsideTheApp() throws {
        let copy = try ThinnedCopy(relativePathOverride: "../escape")
        defer { copy.remove() }
        try expectRefused(RestoreOperation.restoreUnreleased(copy.app, environment: idle), containing: "unsafe path")
    }

    @Test func refusesABackupOutsideItsStagingDirectory() throws {
        let copy = try ThinnedCopy()
        defer { copy.remove() }
        let outside = copy.dir.appending(path: "elsewhere")
        let entry = try #require(copy.entries.first)
        try FileManager.default.copyItem(at: URL(filePath: entry.backupPath), to: outside)
        try copy.editJournal { journal in
            var entries = journal["entries"] as! [[String: Any]]
            entries[0]["backupPath"] = outside.path
            journal["entries"] = entries
        }
        try expectRefused(RestoreOperation.restoreUnreleased(copy.app, environment: idle), containing: "not inside")
        #expect(try copy.allStillThinned())
    }

    @Test func nothingToRestoreWithoutBackups() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "thinner-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = dir.appending(path: "Signed.app")
        try #require(try Shell.run("/usr/bin/ditto", Fixtures.url("bundles/Signed.app").path, app.path).status == 0)

        let result = RestoreOperation.restoreUnreleased(app, environment: idle)
        guard case .nothingToRestore = result.outcome else {
            Issue.record("expected nothing to restore, got \(result.outcome)")
            return
        }
    }
}

private func expectRefused(_ result: RestoreResult, containing text: String,
                           sourceLocation: SourceLocation = #_sourceLocation) throws {
    guard case .refused(let reason) = result.outcome else {
        Issue.record("expected a refusal, got \(result.outcome)", sourceLocation: sourceLocation)
        return
    }
    #expect(reason.contains(text), "reason: \(reason)", sourceLocation: sourceLocation)
    #expect(result.outcome.exitCode == 1, sourceLocation: sourceLocation)
}

final class Counter: @unchecked Sendable {
    var value = 0
}

/// A `tail -f` process holding a file open, stopped by `stop()`.
struct HeldOpen {
    let process = Process()

    init(_ file: URL) throws {
        process.executableURL = URL(filePath: "/usr/bin/tail")
        process.arguments = ["-f", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func waitUntilVisible(in bundle: URL) throws {
        for _ in 0..<50 {
            if try BundleUsage.scan(bundle).uses.contains(where: { $0.pid == process.processIdentifier }) { return }
            usleep(100_000)
        }
        Issue.record("tail never showed up as using \(bundle.path)")
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
    }
}

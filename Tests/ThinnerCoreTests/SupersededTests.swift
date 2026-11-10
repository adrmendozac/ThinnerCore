import Foundation
import Testing
@testable import ThinnerCore

/// An unfinished operation whose app was later updated or deleted. Before the
/// superseded state, recover failed or waited forever, release refused, and
/// every apply in the folder was blocked, with no supported way out.
@Suite struct SupersededTests {
    /// The copy as a crash would leave it, recorded under its real path, as
    /// the writer records it.
    func interrupted() throws -> ThinnedCopy {
        let copy = try ThinnedCopy()
        let real = try #require(realPath(copy.app.path))
        try copy.editJournal {
            $0["state"] = "inProgress"
            $0["bundlePath"] = real
        }
        return copy
    }

    func journal(_ copy: ThinnedCopy) throws -> Journal {
        try #require(try Journal.load(from: copy.journalURL))
    }

    /// The update: a fresh universal copy with a new version and signature.
    func update(_ app: URL) throws {
        try FileManager.default.removeItem(at: app)
        try #require(try Shell.run("/usr/bin/ditto", Fixtures.url("bundles/Signed.app").path, app.path).status == 0)
        try bumpVersion(app)
    }

    func bumpVersion(_ app: URL) throws {
        let plistURL = app.appending(path: "Contents/Info.plist")
        var plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        plist["CFBundleVersion"] = "2"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        try #require(try Shell.run("/usr/bin/codesign", "--force", "--sign", "-", app.path).status == 0)
    }

    var options: ScanOptions { ScanOptions(launchServicesPreferences: URL(filePath: "/nonexistent/prefs.plist")) }

    @Test func updatedAppSupersedesTheOperationAndUnblocksApply() throws {
        let copy = try interrupted()
        defer { copy.remove() }
        try update(copy.app)

        let outcome = ThinOperation.recoverUnreleased(copy.app, environment: idleEnvironment)
        guard case let .superseded(reason) = outcome else { Issue.record("expected superseded, got \(outcome)"); return }
        #expect(reason.contains(copy.staging.lastPathComponent))
        #expect(try journal(copy).state == .superseded)
        for entry in copy.entries { #expect(try SHA256.hash(file: entry.backupPath) == entry.originalHash) }

        // No longer pending, so the batch thins the new version.
        let dir = copy.app.deletingLastPathComponent()
        #expect(PendingOperations.read(root: dir, apps: [copy.app]).operations.isEmpty)
        let report = MutationCommands.applyUnreleased(dir, options: options) { app, options throws(Problem) in
            try ThinOperation.applyUnreleased(to: app, options: options, environment: idleEnvironment)
        }
        #expect(report.apps.map(\.outcome) == [.committed], "\(report)")
        #expect(Codesign.verify(copy.app) == nil)

        // Restore puts the new version back and never uses the old backups.
        let restored = RestoreOperation.restoreUnreleased(copy.app, environment: idleEnvironment)
        #expect(restored.outcome == .restored, "\(restored.outcome)")
        #expect(!restored.backupLocations.contains(copy.staging.path))
    }

    /// The writer resolves its pending operations first; a superseded one
    /// must not stop it thinning the new version.
    @Test func applyThinsTheNewVersionAfterSuperseding() throws {
        let copy = try interrupted()
        defer { copy.remove() }
        try update(copy.app)
        let outcome = try ThinOperation.applyUnreleased(to: copy.app, options: options, environment: idleEnvironment)
        #expect(outcome == .committed)
        #expect(try journal(copy).state == .superseded)
    }

    /// An app that still holds the operation's thinned bytes has not lost
    /// the change, so the operation is not superseded.
    @Test func changedAppStillHoldingThinnedFilesIsNotSuperseded() throws {
        let copy = try interrupted()
        defer { copy.remove() }
        try bumpVersion(copy.app)

        let outcome = ThinOperation.recoverUnreleased(copy.app, environment: idleEnvironment)
        guard case let .recoveryFailed(reason) = outcome else { Issue.record("expected recoveryFailed, got \(outcome)"); return }
        #expect(reason.contains("Reinstall"))
        #expect(try journal(copy).state == .inProgress)
    }

    @Test func deletedAppSupersedesTheOperationAndCanBeReleased() throws {
        let copy = try interrupted()
        defer { copy.remove() }
        try FileManager.default.removeItem(at: copy.app)

        let report = MutationCommands.recoverUnreleased(copy.dir) { app in
            ThinOperation.recoverUnreleased(app, environment: idleEnvironment)
        }
        #expect(report.apps.map(\.outcome) == [.superseded], "\(report)")
        #expect(report.exitCode == 0)
        #expect(report.apps.first?.reason.contains("thinnercore release") == true)
        #expect(try journal(copy).state == .superseded)
        #expect(copy.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.backupPath) })
        #expect(PendingOperations.read(root: copy.dir, apps: []).operations.isEmpty)

        let released = ReleaseOperation.releaseUnreleased(copy.app, environment: idleEnvironment)
        #expect(released.outcome == .released, "\(released.outcome)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: copy.dir.path).isEmpty)
    }

    /// Release of a deleted app still waits for its unfinished operation:
    /// only an explicit recover supersedes it.
    @Test func releaseOfADeletedAppWaitsForRecover() throws {
        let copy = try interrupted()
        defer { copy.remove() }
        try FileManager.default.removeItem(at: copy.app)
        guard case .pending = ReleaseOperation.releaseUnreleased(copy.app, environment: idleEnvironment).outcome else {
            Issue.record("released the backups of an unfinished operation"); return
        }
        #expect(try journal(copy).state == .inProgress)
    }

    /// A moved app is gone from the recorded path; once it is back, restore
    /// still uses the superseded set, by hash.
    @Test func movedBackAppIsStillRestorable() throws {
        let copy = try interrupted()
        defer { copy.remove() }
        let moved = copy.dir.appending(path: "Elsewhere.app")
        try FileManager.default.moveItem(at: copy.app, to: moved)
        guard case .superseded = ThinOperation.recoverUnreleased(copy.app, environment: idleEnvironment) else {
            Issue.record("expected superseded"); return
        }
        try FileManager.default.moveItem(at: moved, to: copy.app)
        #expect(RestoreOperation.restoreUnreleased(copy.app, environment: idleEnvironment).outcome == .restored)
        for entry in copy.entries { #expect(try copy.hash(entry.relativePath) == entry.originalHash) }
    }

    /// Regression: an updater that replaced the whole bundle while the writer
    /// ran led it, by path, into the new version, under the old version's
    /// checks and identity, where restore would later refuse its backups.
    /// The writer now stops before the next swap.
    @Test func writerStopsWhenTheBundleIsReplacedMidOperation() throws {
        let fixture = try ThinOperationTests()
        defer { fixture.cleanUp() }
        let old = fixture.dir.appending(path: "Old.app")
        var replaced = false
        var env = idleEnvironment
        env.boundary = { name, _ in
            guard name == "ready-journal", !replaced else { return }
            replaced = true
            do {
                try FileManager.default.moveItem(at: fixture.app, to: old)
                try #require(try Shell.run("/usr/bin/ditto", Fixtures.url("bundles/Signed.app").path, fixture.app.path).status == 0)
                try self.bumpVersion(fixture.app)
            } catch {
                Issue.record("cannot replace the bundle: \(error)")
            }
        }
        let newOriginals = { () throws -> [String: String] in
            var hashes: [String: String] = [:]
            for file in BundleWalker.walk(fixture.app).files {
                hashes[file.relativePath] = try SHA256.hash(file: fixture.app.appending(path: file.relativePath).path)
            }
            return hashes
        }
        let outcome = try ThinOperation.applyUnreleased(to: fixture.app, options: fixture.options, environment: env)
        #expect(replaced)
        #expect(outcome != .committed, "\(outcome)")
        // Nothing of the new version was touched: every universal file is still universal.
        let files = BundleWalker.walk(fixture.app).files
        #expect(files.allSatisfy { $0.decision.isEligible })
        let before = try newOriginals()
        #expect(Codesign.verify(fixture.app) == nil)

        // The operation never reached the new version, so recover supersedes it.
        guard case .superseded = ThinOperation.recoverUnreleased(fixture.app, environment: idleEnvironment) else {
            Issue.record("expected superseded"); return
        }
        let after = try newOriginals()
        #expect(after == before)
    }
}

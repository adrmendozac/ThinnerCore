import Darwin
import Foundation
import Testing
@testable import ThinnerCore

/// Regressions from the CodeRabbit review of 2026-11-10.
@Suite struct ReviewRegressionTests {
    /// Naming a preferences file made the scan forget whose run it was, so
    /// under sudo `~/` skip-list entries resolved under root's home and
    /// excluded nothing. The home now follows the invoking user regardless.
    @Test func explicitPreferencesKeepTheInvokingUsersHome() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = dir.appending(path: "list.txt")
        try "~/Applications/Foo.app\n".write(to: list, atomically: true, encoding: .utf8)

        // uid 0 stands in for "an invoking user other than the effective one".
        var options = ScanOptions(excludes: [], launchServicesPreferences: dir.appending(path: "prefs.plist"),
                                  defaultUser: .success(0))
        options.loadSkipList(list)
        options.loadAllowList(list)
        let rootHome = SkipList.home(of: 0)
        #expect(rootHome != SkipList.home(of: geteuid()), "the test needs two different homes")
        #expect(options.skipList.paths == [rootHome + "/Applications/Foo.app"])
        #expect(options.allowList.paths == [rootHome + "/Applications/Foo.app"])
    }

    /// A crash between creating a preparation directory and writing its
    /// journal left it beside the app for ever. An old empty one is removed;
    /// a fresh one may be a sibling app's preparation still running.
    @Test func abandonedEmptyPreparationsAreRemovedOnlyWhenOld() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "prep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "A.app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appending(path: StagingArea.preparingPrefix + UUID().uuidString)
        let fresh = dir.appending(path: StagingArea.preparingPrefix + UUID().uuidString)
        let notEmpty = dir.appending(path: StagingArea.preparingPrefix + UUID().uuidString)
        for url in [old, fresh, notEmpty] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        try Data("x".utf8).write(to: notEmpty.appending(path: "other"))
        let hourAgo = Date().addingTimeInterval(-2 * StagingArea.abandonedAge)
        for url in [old, notEmpty] { try FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: url.path) }

        StagingArea.removeAbandonedPreparations(of: realPath(dir.path)! + "/A.app", euid: geteuid())
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: notEmpty.appending(path: "other").path), "rmdir never removes content")
    }
}

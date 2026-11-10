import Foundation
import Testing
@testable import ThinnerCore

/// The allow list narrows what can be thinned and never widens it. On
/// throwaway copies of the fixture apps.
@Suite struct AllowListTests {
    private let dir: URL
    private var root: URL { dir.appending(path: "root") }
    private var listFile: URL { dir.appending(path: "allow-list.txt") }

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "thinner-allow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    private func copyApp(_ relative: String) throws -> URL {
        let app = root.appending(path: relative)
        try FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        let copy = try Shell.run("/bin/cp", "-R", try Fixtures.url("bundles/Signed.app").path, app.path)
        try #require(copy.status == 0, "\(copy.output)")
        return app
    }

    /// Gives a copy its own bundle identifier, so apps can be told apart.
    private func setIdentifier(_ app: URL, _ id: String) throws {
        let url = app.appending(path: "Contents/Info.plist")
        var plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        plist["CFBundleIdentifier"] = id
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        try #require(try Shell.run("/usr/bin/codesign", "--force", "--sign", "-", app.path).status == 0)
    }

    private func scan(allow lines: [String]?, skip: [String] = []) throws -> [String: AppSkipReason?] {
        var options = ScanOptions(launchServicesPreferences: dir.appending(path: "no-prefs.plist"))
        options.pluginFolders = []
        if let lines {
            try (lines.joined(separator: "\n") + "\n").write(to: listFile, atomically: true, encoding: .utf8)
            options.loadAllowList(listFile)
        }
        options.skipList = SkipList(bundleIdentifiers: skip)
        return Dictionary(uniqueKeysWithValues: AppScanner.scan(root, options: options).apps.map { ($0.relativePath, $0.skip) })
    }

    @Test func noListOrAnEmptyOneAllowsEveryApp() throws {
        defer { cleanUp() }
        try copyApp("A.app")
        #expect(try scan(allow: nil)["A.app"] == .some(nil))
        #expect(try scan(allow: ["# only a comment", ""])["A.app"] == .some(nil))
    }

    @Test func aBundleIdentifierAllowsOnlyThatApp() throws {
        defer { cleanUp() }
        try setIdentifier(try copyApp("A.app"), "com.example.a")
        try setIdentifier(try copyApp("B.app"), "com.example.b")
        let result = try scan(allow: ["com.example.a"])
        #expect(result["A.app"] == .some(nil))
        #expect(result["B.app"] == .notOnAllowList)
        #expect(AppSkipReason.notOnAllowList.mutationOutcome == .skipped)
    }

    @Test func aFolderAllowsEveryAppBelowIt() throws {
        defer { cleanUp() }
        try copyApp("Tools/Nested/A.app")
        try copyApp("Other/B.app")
        let result = try scan(allow: [root.appending(path: "Tools").path])
        #expect(result["Tools/Nested/A.app"] == .some(nil))
        #expect(result["Other/B.app"] == .notOnAllowList)
    }

    /// Paths match by identity, like exclusions, so a symlink to the app works.
    @Test func anAppPathMatchesThroughASymlink() throws {
        defer { cleanUp() }
        let app = try copyApp("A.app")
        try copyApp("B.app")
        let link = dir.appending(path: "link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        let result = try scan(allow: [link.path])
        #expect(result["A.app"] == .some(nil))
        #expect(result["B.app"] == .notOnAllowList)
    }

    @Test func theSkipListWinsOverTheAllowList() throws {
        defer { cleanUp() }
        try setIdentifier(try copyApp("A.app"), "com.example.a")
        #expect(try scan(allow: ["com.example.a"], skip: ["com.example.a"])["A.app"] == .skipListed("com.example.a"))
    }

    /// Being listed never lifts a check.
    @Test func aListedAppStillPassesEveryCheck() throws {
        defer { cleanUp() }
        let app = try copyApp("A.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/_MASReceipt"), withIntermediateDirectories: true)
        #expect(try scan(allow: [app.path])["A.app"] == .masApp)
    }

    @Test func anUnreadableListRefusesEveryApp() throws {
        defer { cleanUp() }
        try copyApp("A.app")
        let target = dir.appending(path: "real-list.txt")
        try "com.example.a\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: listFile, withDestinationURL: target)
        var options = ScanOptions(launchServicesPreferences: dir.appending(path: "no-prefs.plist"))
        options.pluginFolders = []
        options.loadAllowList(listFile)
        let result = AppScanner.scan(root, options: options)
        guard case .allowListUnreadable? = result.apps.first?.skip else {
            Issue.record("expected allowListUnreadable, got \(String(describing: result.apps.first?.skip))"); return
        }
        #expect(result.apps.first?.skip?.mutationOutcome == .refused)
        #expect(result.allowList?.problem != nil)
    }

    @Test func missingPathsAreReported() throws {
        defer { cleanUp() }
        try copyApp("A.app")
        var options = ScanOptions(launchServicesPreferences: dir.appending(path: "no-prefs.plist"))
        options.pluginFolders = []
        try "/nowhere/Gone.app\n".write(to: listFile, atomically: true, encoding: .utf8)
        options.loadAllowList(listFile)
        let result = AppScanner.scan(root, options: options)
        #expect(result.allowList?.missingPaths == ["/nowhere/Gone.app"])
        #expect(result.apps.first?.skip == .notOnAllowList, "a list naming nothing that exists allows nothing")
    }
}

import Foundation
import Testing
import ThinnerCore

/// Options that read no real user settings: the LaunchServices preferences
/// path names nothing, so no app is flagged for Rosetta.
func hermeticOptions(excludes: [URL] = []) -> ScanOptions {
    ScanOptions(
        excludes: excludes,
        launchServicesPreferences: FileManager.default.temporaryDirectory.appending(path: "thinner-no-prefs-\(UUID().uuidString).plist")
    )
}

@Suite struct AppScannerFixtureTests {
    @Test func findsEachTopLevelAppAndTotalsIt() throws {
        let result = AppScanner.scan(try Fixtures.root(), options: hermeticOptions())
        #expect(result.isComplete, "\(result.issues)")

        // Loose files in macho/ and java/ belong to no app; helper apps are
        // part of the app that contains them; Multi.framework is not an app.
        #expect(result.apps.map(\.relativePath) == ["bundles/Electron.app", "bundles/Nested.app", "bundles/Signed.app"])

        #expect(result.apps.allSatisfy { $0.skip == nil })
        #expect(result.skippedPaths.isEmpty)
        let counts = result.apps.map { [$0.universalCount, $0.eligibleCount] }
        #expect(counts == [[14, 9], [7, 3], [4, 3]])

        for app in result.apps {
            #expect(app.removableBytes == app.files.reduce(0) { $0 + $1.decision.savedBytes })
            #expect(app.removableBytes > 0)
            #expect(app.url.lastPathComponent == URL(filePath: app.relativePath).lastPathComponent)
        }

        let totals = result.totals
        #expect(totals.apps == 3)
        #expect(totals.skippedApps == 0)
        #expect(totals.universalFiles == 25)
        #expect(totals.eligibleFiles == 15)
        #expect(totals.removableBytes == result.apps.reduce(0) { $0 + $1.removableBytes })
        #expect(totals.issues == 0)
    }

    @Test func anAppRootIsScannedAsThatApp() throws {
        let url = try Fixtures.url("bundles/Signed.app")
        let result = AppScanner.scan(url, options: hermeticOptions())
        #expect(result.apps.map(\.relativePath) == ["Signed.app"])
        #expect(result.apps.first?.files == BundleClassifier.classify(url).files)
    }

    @Test func scanningLeavesFixturesUntouched() throws {
        let root = try Fixtures.root()
        let before = try Self.snapshot(root)
        _ = AppScanner.scan(root, options: hermeticOptions())
        #expect(try Self.snapshot(root) == before)
    }

    /// Path, size, and modification time of everything under `root`.
    private static func snapshot(_ root: URL) throws -> [String: [Double]] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        var result: [String: [Double]] = [:]
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys))
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            result[url.path] = [Double(values.fileSize ?? -1), values.contentModificationDate?.timeIntervalSince1970 ?? -1]
        }
        return result
    }
}

/// Layouts built in a throwaway directory from copies of the fixtures.
@Suite struct AppScannerEdgeTests {
    private let dir: URL
    private var root: URL { dir.appending(path: "root") }

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "thinner-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func copyApp(to relativePath: String) throws {
        let destination = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let copy = try Shell.run("/bin/cp", "-R", try Fixtures.url("bundles/Signed.app").path, destination.path)
        try #require(copy.status == 0, "\(copy.output)")
    }

    @Test func appsInSubfoldersAreFound() throws {
        defer { cleanUp() }
        try copyApp(to: "Top.app")
        try copyApp(to: "Vendor/Suite/Tool.app")
        let result = AppScanner.scan(root, options: hermeticOptions())
        #expect(result.apps.map(\.relativePath) == ["Top.app", "Vendor/Suite/Tool.app"])
        #expect(result.apps.allSatisfy { $0.eligibleCount == 3 })
    }

    @Test func symlinksAndFilesNamedAppAreIgnored() throws {
        defer { cleanUp() }
        try copyApp(to: "Real.app")
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "Link.app").path, withDestinationPath: "Real.app")
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "Folder").path, withDestinationPath: ".")
        try Data().write(to: root.appending(path: "Fake.app"))

        let result = AppScanner.scan(root, options: hermeticOptions())
        #expect(result.apps.map(\.relativePath) == ["Real.app"])
        #expect(result.isComplete)
    }

    @Test func appWithoutMetadataIsStillListed() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: root.appending(path: "Empty.app/Contents/MacOS"), withIntermediateDirectories: true)
        let app = try #require(AppScanner.scan(root, options: hermeticOptions()).apps.first)
        #expect(app.relativePath == "Empty.app")
        #expect(app.universalCount == 0)
        #expect(app.removableBytes == 0)
        guard case .bundleMetadata = app.skip else {
            Issue.record("expected bundleMetadata, got \(String(describing: app.skip))")
            return
        }
    }

    @Test func unreadableFolderIsReportedAndTheRestScanned() throws {
        let locked = root.appending(path: "Locked")
        defer {
            chmod(locked.path, 0o755)
            cleanUp()
        }
        try copyApp(to: "Open.app")
        try copyApp(to: "Locked/Hidden.app")
        try #require(chmod(locked.path, 0o000) == 0)
        try #require(getuid() != 0, "root can read anything; this test needs a normal user")

        let result = AppScanner.scan(root, options: hermeticOptions())
        #expect(result.apps.map(\.relativePath) == ["Open.app"])
        #expect(result.issues.map(\.relativePath) == ["Locked"])
        #expect(!result.isComplete)
        #expect(result.totals.issues == 1)
    }

    @Test func unreadablePathInsideAnAppMakesTheScanIncomplete() throws {
        let resources = root.appending(path: "App.app/Contents/Resources")
        defer {
            chmod(resources.path, 0o755)
            cleanUp()
        }
        try copyApp(to: "App.app")
        try #require(chmod(resources.path, 0o000) == 0)
        try #require(getuid() != 0, "root can read anything; this test needs a normal user")

        let result = AppScanner.scan(root, options: hermeticOptions())
        let app = try #require(result.apps.first)
        #expect(app.issues.map(\.relativePath) == ["Contents/Resources"])
        #expect(result.issues.isEmpty)
        #expect(!result.isComplete)
    }

    @Test func symlinkedRootIsRefused() throws {
        defer { cleanUp() }
        try copyApp(to: "App.app")
        let link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.path)

        let result = AppScanner.scan(link, options: hermeticOptions())
        #expect(result.apps.isEmpty)
        #expect(result.issues.map(\.problem) == ["is a symbolic link"])
    }
}

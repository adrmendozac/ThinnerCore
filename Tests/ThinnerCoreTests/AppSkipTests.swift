import Foundation
import Testing
import ThinnerCore

private let currentUser = String(cString: getpwuid(getuid())!.pointee.pw_name)

/// App-level skips, on throwaway copies of the fixture apps. Copies that are
/// edited are re-signed ad hoc here, as the fixture script signs its bundles,
/// so that each test isolates one reason. The tool itself never signs.
@Suite struct AppSkipTests {
    private let dir: URL
    private var root: URL { dir.appending(path: "root") }
    private var prefs: URL { dir.appending(path: "LaunchServices.plist") }

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "thinner-skip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func copyApp(to relativePath: String, from fixture: String = "bundles/Signed.app") throws -> URL {
        let destination = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let copy = try Shell.run("/bin/cp", "-R", try Fixtures.url(fixture).path, destination.path)
        try #require(copy.status == 0, "\(copy.output)")
        return destination
    }

    private func editInfoPlist(_ app: URL, _ edit: (inout [String: Any]) -> Void) throws {
        let url = app.appending(path: "Contents/Info.plist")
        var plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        edit(&plist)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    private func resign(_ app: URL) throws {
        let sign = try Shell.run("/usr/bin/codesign", "--force", "--sign", "-", app.path)
        try #require(sign.status == 0, "\(sign.output)")
    }

    private func writePrefs(_ plist: [String: Any]) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: prefs)
    }

    private func scan(_ path: URL? = nil, excludes: [URL] = []) -> ScanResult {
        AppScanner.scan(path ?? root, options: ScanOptions(excludes: excludes, launchServicesPreferences: prefs))
    }

    private func app(_ result: ScanResult, _ relativePath: String) throws -> AppScan {
        try #require(result.apps.first { $0.relativePath == relativePath }, "\(result.apps.map(\.relativePath))")
    }

    // MARK: - Exclusions

    @Test func excludedAppIsListedButNotRead() throws {
        defer { cleanUp() }
        try copyApp(to: "Keep.app")
        let excluded = try copyApp(to: "Skip.app")

        let result = scan(excludes: [excluded])
        let skipped = try app(result, "Skip.app")
        #expect(skipped.skip == .excluded(excluded.path))
        #expect(skipped.files.isEmpty)
        #expect(try app(result, "Keep.app").skip == nil)
        #expect(result.totals.skippedApps == 1)
        #expect(result.totals.eligibleFiles == 3)
    }

    @Test func excludedFolderIsNotSearched() throws {
        defer { cleanUp() }
        try copyApp(to: "Vendor/Tool.app")
        let vendor = root.appending(path: "Vendor")

        let result = scan(excludes: [vendor])
        #expect(result.apps.isEmpty)
        #expect(result.skippedPaths.map(\.relativePath) == ["Vendor"])
        #expect(result.skippedPaths.map(\.reason) == [.excluded(vendor.path)])
    }

    /// Identity, not spelling: an exclusion reached through a symlink still
    /// matches the folder the scan finds.
    @Test func exclusionThroughASymlinkMatches() throws {
        defer { cleanUp() }
        try copyApp(to: "Vendor/Tool.app")
        let alias = dir.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appending(path: "Vendor"))

        let result = scan(excludes: [alias.appending(path: "Tool.app")])
        #expect(try app(result, "Vendor/Tool.app").skip == .excluded(alias.appending(path: "Tool.app").path))
    }

    @Test func exclusionInsideAnAppSkipsTheWholeApp() throws {
        defer { cleanUp() }
        let copy = try copyApp(to: "App.app")
        let dylib = copy.appending(path: "Contents/Frameworks/libloose.dylib")

        let result = scan(excludes: [dylib])
        let scanned = try app(result, "App.app")
        #expect(scanned.skip == .containsExclusion(dylib.path))
        #expect(scanned.eligibleCount == 0)
    }

    @Test func excludedRootIsNotSearched() throws {
        defer { cleanUp() }
        try copyApp(to: "App.app")
        let result = scan(excludes: [root])
        #expect(result.apps.isEmpty)
        #expect(result.skippedPaths.map(\.relativePath) == [""])
        #expect(result.skippedPaths.map(\.reason) == [.excluded(root.path)])

        let single = scan(root.appending(path: "App.app"), excludes: [root])
        #expect(single.apps.map(\.skip) == [.excluded(root.path)])
    }

    @Test func missingExclusionIsReported() throws {
        defer { cleanUp() }
        let nowhere = dir.appending(path: "nowhere")
        #expect(scan(excludes: [nowhere]).missingExclusions == [nowhere.path])
    }

    // MARK: - Protected locations

    @Test func protectedLocations() throws {
        defer { cleanUp() }
        // Checked by path alone; nothing under /System is read.
        #expect(ProtectedLocations.reason(forRealPath: "/System/Applications/Example.app") == "under /System")
        #expect(ProtectedLocations.reason(forRealPath: "/System") == "under /System")
        // statfs of the root volume only reads mount information.
        #expect(ProtectedLocations.reason(forRealPath: "/") == "on the sealed system volume")
        // The temporary directory is on the writable Data volume.
        #expect(ProtectedLocations.reason(forRealPath: try #require(realPathOf(root))) == nil)
        // A path that cannot be checked is protected.
        #expect(ProtectedLocations.reason(forRealPath: dir.appending(path: "missing").path)?
            .hasPrefix("cannot determine its volume") == true)
    }

    private func realPathOf(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Bundle metadata

    @Test func scriptOnlyAppIsReportedAsSuch() throws {
        defer { cleanUp() }
        let app = root.appending(path: "Script.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleExecutable": "run", "CFBundleIdentifier": "dev.thinner.fixture.script"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: app.appending(path: "Contents/MacOS/run"))

        let scanned = try self.app(scan(), "Script.app")
        #expect(scanned.skip == .scriptOnly("the main executable run is a script"))
        #expect(scanned.bundleIdentifier == "dev.thinner.fixture.script")
    }

    @Test func missingMainExecutableIsBundleMetadata() throws {
        defer { cleanUp() }
        let copy = try copyApp(to: "App.app")
        try editInfoPlist(copy) { $0["CFBundleExecutable"] = "Missing" }
        guard case let .bundleMetadata(detail) = try app(scan(), "App.app").skip else {
            Issue.record("expected bundleMetadata")
            return
        }
        #expect(detail.contains("Contents/MacOS/Missing"))
    }

    // MARK: - Rosetta

    @Test func absentPreferencesFlagNothing() throws {
        defer { cleanUp() }
        try copyApp(to: "App.app")
        let result = scan()
        #expect(result.rosetta.preferences == .absent)
        #expect(result.rosetta.preferencesPath == prefs.path)
        #expect(result.rosetta.preferencesUser == currentUser)
        #expect(try app(result, "App.app").skip == nil)
    }

    /// The name macOS 27 writes, and the earlier assumed one.
    static let rosettaKeys = ["Architectures(arm64)", "LSArchitecturesForX86_64"]

    @Test(arguments: rosettaKeys)
    func openUsingRosettaFlagSkipsThatAppOnly(key: String) throws {
        defer { cleanUp() }
        try copyApp(to: "Flagged.app")
        try copyApp(to: "Other.app", from: "bundles/Nested.app")
        try writePrefs([key: [
            "dev.thinner.fixture.signed": [Data([1, 2, 3]), "x86_64"],
        ]])

        let result = scan()
        #expect(result.rosetta.preferences == .read(flagged: 1))
        #expect(try app(result, "Flagged.app").skip == .rosettaFlagged(user: currentUser))
        #expect(try app(result, "Other.app").skip == nil)
    }

    @Test(arguments: rosettaKeys)
    func unrecognizedRosettaEntryIsInconclusive(key: String) throws {
        defer { cleanUp() }
        try copyApp(to: "App.app")
        try writePrefs([key: ["dev.thinner.fixture.signed": ["arm64"]]])
        guard case .rosettaInconclusive = try app(scan(), "App.app").skip else {
            Issue.record("expected rosettaInconclusive")
            return
        }
    }

    @Test(arguments: rosettaKeys)
    func unparseableRosettaKeySkipsEveryApp(key: String) throws {
        defer { cleanUp() }
        try copyApp(to: "A.app")
        try copyApp(to: "B.app", from: "bundles/Nested.app")
        try writePrefs([key: "not a dictionary"])

        let result = scan()
        guard case .unreadable = result.rosetta.preferences else {
            Issue.record("expected unreadable preferences, got \(result.rosetta.preferences)")
            return
        }
        #expect(result.apps.count == 2)
        for app in result.apps {
            guard case .rosettaInconclusive = app.skip else {
                Issue.record("\(app.relativePath): \(String(describing: app.skip))")
                continue
            }
        }
    }

    /// Regression: the scanner read only `LSArchitecturesForX86_64`, so on
    /// macOS 27 a flagged app was reported eligible. This is the shape Finder
    /// wrote on macOS 27.0.1 (Phase 0, 2026-10-03): a bookmark to the flagged
    /// copy, then the architecture, beside unrelated LaunchServices keys.
    @Test func macOS27RosettaFlagIsRead() throws {
        defer { cleanUp() }
        try copyApp(to: "Flagged.app")
        try copyApp(to: "Other.app", from: "bundles/Nested.app")
        let bookmark = Data("book".utf8) + Data(count: 1036)
        try writePrefs([
            "Architectures(arm64)": ["dev.thinner.fixture.signed": [bookmark, "x86_64"]],
            "LSGameModeDisabledIsPreferred": [String: Any](),
            "LSSystemHiddenPreferred": [String: Any](),
        ])

        let result = scan()
        #expect(result.rosetta.preferences == .read(flagged: 1))
        #expect(try app(result, "Flagged.app").skip == .rosettaFlagged(user: currentUser))
        #expect(try app(result, "Other.app").skip == nil)
    }

    /// Flags under both names are combined; flagged under either is flagged.
    @Test func rosettaFlagsUnderBothKeysCombine() throws {
        defer { cleanUp() }
        try copyApp(to: "A.app")
        try copyApp(to: "B.app", from: "bundles/Nested.app")
        try writePrefs([
            "Architectures(arm64)": ["dev.thinner.fixture.signed": [Data([1]), "x86_64"]],
            "LSArchitecturesForX86_64": [
                "dev.thinner.fixture.signed": ["arm64"],
                "dev.thinner.fixture.nested": [Data([2]), "x86_64"],
            ],
        ])

        let result = scan()
        #expect(result.rosetta.preferences == .read(flagged: 2))
        #expect(try app(result, "A.app").skip == .rosettaFlagged(user: currentUser))
        #expect(try app(result, "B.app").skip == .rosettaFlagged(user: currentUser))
    }

    @Test func corruptPreferencesFileSkipsEveryApp() throws {
        defer { cleanUp() }
        try copyApp(to: "App.app")
        try Data("garbage".utf8).write(to: prefs)
        guard case .rosettaInconclusive = try app(scan(), "App.app").skip else {
            Issue.record("expected rosettaInconclusive")
            return
        }
    }

    @Test func intelFirstArchitecturePriorityIsSkipped() throws {
        defer { cleanUp() }
        let intelFirst = try copyApp(to: "Intel.app")
        try editInfoPlist(intelFirst) { $0["LSArchitecturePriority"] = ["x86_64", "arm64"] }
        try resign(intelFirst)
        let armFirst = try copyApp(to: "Arm.app")
        try editInfoPlist(armFirst) { $0["LSArchitecturePriority"] = ["arm64", "x86_64"] }
        try resign(armFirst)

        let result = scan()
        #expect(try app(result, "Intel.app").skip == .intelArchitecturePriority(["x86_64", "arm64"]))
        #expect(try app(result, "Arm.app").skip == nil)
    }

    @Test func malformedArchitecturePriorityIsBundleMetadata() throws {
        defer { cleanUp() }
        let copy = try copyApp(to: "App.app")
        try editInfoPlist(copy) { $0["LSArchitecturePriority"] = "x86_64" }
        try resign(copy)
        #expect(try app(scan(), "App.app").skip
            == .bundleMetadata("LSArchitecturePriority is not a list of architecture names"))
    }

    // MARK: - Signature

    @Test func appFailingCodesignIsSkippedButKeepsItsFiles() throws {
        defer { cleanUp() }
        let copy = try copyApp(to: "App.app")
        // Change a sealed resource in the throwaway copy.
        let handle = try FileHandle(forWritingTo: copy.appending(path: "Contents/Resources/addon.node"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()

        let scanned = try app(scan(), "App.app")
        guard case let .signatureInvalid(detail) = scanned.skip else {
            Issue.record("expected signatureInvalid, got \(String(describing: scanned.skip))")
            return
        }
        #expect(detail.contains("sealed resource"))
        #expect(scanned.eligibleCount == 0)
        #expect(scanned.removableBytes == 0)
        #expect(scanned.files.count { $0.decision.isEligible } == 3) // what would have been eligible
    }

    @Test func reasonsDescribeThemselves() {
        #expect(AppSkipReason.rosettaFlagged(user: "sam").description
            == "set to Open using Rosetta in sam's preferences")
        #expect(AppSkipReason.intelArchitecturePriority(["x86_64", "arm64"]).description
            == "LSArchitecturePriority lists an Intel architecture first (x86_64, arm64)")
    }
}

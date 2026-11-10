import Foundation
import Testing
@testable import ThinnerCore

/// Phase 7's advisory defaults, on throwaway copies of the fixture apps.
@Suite struct AdvisoryPolicyTests {
    private let dir: URL
    private var root: URL { dir.appending(path: "root") }

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "thinner-advisory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: dir) }

    private func copyApp(_ name: String) throws -> URL {
        let app = root.appending(path: name)
        let copy = try Shell.run("/bin/cp", "-R", try Fixtures.url("bundles/Signed.app").path, app.path)
        try #require(copy.status == 0, "\(copy.output)")
        return app
    }

    private func makeDirectory(_ app: URL, _ relative: String) throws {
        try FileManager.default.createDirectory(at: app.appending(path: relative), withIntermediateDirectories: true)
    }

    private func options() -> ScanOptions {
        var options = ScanOptions(launchServicesPreferences: dir.appending(path: "no-prefs.plist"))
        options.pluginFolders = []
        return options
    }

    private func scanApp(_ app: URL) throws -> AppScan {
        try #require(AppScanner.scan(app, options: options()).apps.first)
    }

    @Test func anOrdinaryAppHasNoAdvisorySkip() throws {
        defer { cleanUp() }
        let scanned = try scanApp(try copyApp("Plain.app"))
        #expect(scanned.skip == nil)
        #expect(scanned.eligibleCount > 0)
    }

    @Test func macAppStoreAppIsSkippedAsAdvisory() throws {
        defer { cleanUp() }
        let app = try copyApp("Store.app")
        try makeDirectory(app, "Contents/_MASReceipt")
        try Data("receipt".utf8).write(to: app.appending(path: "Contents/_MASReceipt/receipt"))

        let scanned = try scanApp(app)
        #expect(scanned.skip == .masApp)
        #expect(scanned.skip?.isAdvisory == true)
        #expect(scanned.skip?.mutationOutcome == .skipped)
        #expect(scanned.eligibleCount == 0)
        #expect(scanned.files.contains { $0.decision.isEligible }, "the report still says what would be eligible")
    }

    @Test(arguments: ["Contents/Library/SystemExtensions/com.example.vpn.systemextension",
                      "Contents/Library/SystemExtensions/com.example.driver.dext",
                      "Contents/Library/Extensions/Example.kext"])
    func embeddedExtensionIsSkippedAsAdvisory(_ extensionPath: String) throws {
        defer { cleanUp() }
        let app = try copyApp("Secure.app")
        try makeDirectory(app, extensionPath)

        let scanned = try scanApp(app)
        #expect(scanned.skip == .embedsSystemExtension([extensionPath]))
        #expect(scanned.skip?.isAdvisory == true)
    }

    @Test func emptyExtensionFoldersSkipNothing() throws {
        defer { cleanUp() }
        let app = try copyApp("Empty.app")
        try makeDirectory(app, "Contents/Library/SystemExtensions")
        try makeDirectory(app, "Contents/Library/Extensions/NotAKext")
        #expect(try scanApp(app).skip == nil)
    }

    /// A hard reason is always the one reported, so a future override of
    /// advisory skips can never uncover an app a safety rule refused.
    @Test func aHardReasonWinsOverAnAdvisoryOne() throws {
        defer { cleanUp() }
        let app = try copyApp("Both.app")
        try makeDirectory(app, "Contents/_MASReceipt")
        let url = app.appending(path: "Contents/Info.plist")
        var plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        plist["LSArchitecturePriority"] = ["x86_64", "arm64"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)

        let skip = try #require(try scanApp(app).skip)
        #expect(!skip.isAdvisory)
        #expect(skip.code == "intelArchitecturePriority")
    }

    @Test func onlyThePhase7DefaultsAreAdvisory() {
        let hard: [AppSkipReason] = [
            .protectedLocation(""), .excluded(""), .containsExclusion(""), .bundleMetadata(""), .scriptOnly(""),
            .rosettaFlagged(user: ""), .rosettaInconclusive(""), .noNativeMainExecutable([]),
            .intelArchitecturePriority([]), .intelOnlyCode([]), .skipListed(""), .skipListUnreadable(""),
            .signatureInvalid(""),
        ]
        #expect(hard.allSatisfy { !$0.isAdvisory })
        #expect(AppSkipReason.masApp.isAdvisory && AppSkipReason.embedsSystemExtension([]).isAdvisory)
    }

    @Test func reportMarksAdvisorySkipsOnly() throws {
        defer { cleanUp() }
        let store = try copyApp("Store.app")
        try makeDirectory(store, "Contents/_MASReceipt")
        _ = try copyApp("Plain.app")
        let report = ScanReport(root: root, excludes: [], result: AppScanner.scan(root, options: options()))
        #expect(report.schemaVersion == 5)
        let json = try #require(JSONSerialization.jsonObject(with: Data(report.json().utf8)) as? [String: Any])
        let apps = try #require(json["apps"] as? [[String: Any]])
        let skips = apps.map { $0["skip"] as? [String: Any] }
        #expect(skips.compactMap { $0?["advisory"] as? Bool } == [true])
        #expect(skips.compactMap { $0?["code"] as? String } == ["masApp"])
    }

    // MARK: - Intel-only plugins

    private func plugin(_ folder: URL, _ name: String, executable fixture: String?) throws {
        let contents = folder.appending(path: "\(name)/Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        guard let fixture else { return }
        let plist = ["CFBundleExecutable": "Plugin"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        try FileManager.default.copyItem(at: try Fixtures.url(fixture), to: contents.appending(path: "MacOS/Plugin"))
    }

    @Test func intelOnlyPluginsAreReportedNotSkipped() throws {
        defer { cleanUp() }
        let components = dir.appending(path: "Components")
        let vst3 = dir.appending(path: "VST3")
        try plugin(components, "Old.component", executable: "macho/thin-x86_64")
        try plugin(components, "Universal.component", executable: "macho/fat-arm64-x86_64")
        try plugin(components, "Native.component", executable: "macho/thin-arm64")
        try plugin(components, "Broken.component", executable: nil)
        try plugin(components, "NotAPlugin.bundle", executable: "macho/thin-x86_64")
        try plugin(vst3, "Old.vst3", executable: "macho/thin-x86_64")
        let missing = dir.appending(path: "VST")

        let report = AdvisoryPolicy.plugins(in: [components, vst3, missing])
        #expect(report.intelOnly == [components.appending(path: "Old.component").path, vst3.appending(path: "Old.vst3").path])
        #expect(report.uninspected == [components.appending(path: "Broken.component").path])
    }

    @Test func pluginsReachTheReports() throws {
        defer { cleanUp() }
        let components = dir.appending(path: "Components")
        try plugin(components, "Old.component", executable: "macho/thin-x86_64")
        _ = try copyApp("Plain.app")
        var options = options()
        options.pluginFolders = [components]
        let report = ScanReport(root: root, excludes: [], result: AppScanner.scan(root, options: options))
        #expect(report.plugins.intelOnly == [components.appending(path: "Old.component").path])
        #expect(report.apps.allSatisfy { $0.skip == nil }, "a warning skips nothing")
        #expect(TextReport.render(report).contains("1 Intel-only audio plugin runs only under Rosetta"))
    }

    @Test func standardPluginFoldersAreAudioOnly() {
        let folders = AdvisoryPolicy.pluginFolders(home: "/Users/someone").map(\.path)
        #expect(folders.contains("/Library/Audio/Plug-Ins/Components"))
        #expect(folders.contains("/Users/someone/Library/Audio/Plug-Ins/VST3"))
        #expect(!folders.contains { $0.contains("QuickLook") || $0.contains("Spotlight") || $0.contains("HAL") })
    }
}

import Foundation
import Testing
import ThinnerCore

private func isEligible(_ decision: Decision?) -> Bool {
    if case .eligible = decision { true } else { false }
}

private func decisions(_ result: WalkResult) -> [String: Decision] {
    Dictionary(uniqueKeysWithValues: result.files.map { ($0.relativePath, $0.decision) })
}

@Suite struct BundleClassifierFixtureTests {
    private func classify(_ bundle: String) throws -> [String: Decision] {
        let result = BundleClassifier.classify(try Fixtures.url(bundle))
        #expect(result.issues.isEmpty, "\(result.issues)")
        return decisions(result)
    }

    @Test func signedAppSkipsOnlyTheHashSealedNode() throws {
        let d = try classify("bundles/Signed.app")
        #expect(isEligible(d["Contents/MacOS/Signed"])) // main executable
        #expect(isEligible(d["Contents/Frameworks/Foo.framework/Versions/A/Foo"])) // framework binary
        #expect(isEligible(d["Contents/Frameworks/libloose.dylib"])) // cdhash
        #expect(d["Contents/Resources/addon.node"] == .skip(.sealedAsData(by: "")))
        #expect(d.count == 4)
    }

    @Test func nestedAppFollowsTheChainIntoHelpers() throws {
        let d = try classify("bundles/Nested.app")
        #expect(isEligible(d["Contents/MacOS/Nested"]))
        #expect(isEligible(d["Contents/MacOS/nested-tool"]))
        #expect(isEligible(d["Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper"]))
        // A signed bundle in Resources is data to the app, file by file.
        #expect(d["Contents/Resources/Plugin.bundle/Contents/MacOS/Plugin"] == .skip(.sealedAsData(by: "")))
        // The architecture rule still comes first.
        #expect(d["Contents/Frameworks/libarm64e.dylib"] == .skip(.noARM64))
        #expect(d["Contents/Frameworks/libintel.dylib"] == .skip(.noARM64))
        #expect(d["Contents/Frameworks/libapple.dylib"] == .skip(.noIntel))
    }

    @Test func electronAppSkipsWhatAnyLevelSealsAsData() throws {
        let d = try classify("bundles/Electron.app")
        let framework = "Contents/Frameworks/Electron Framework.framework"
        let squirrel = "Contents/Frameworks/Squirrel.framework"
        let helpers = ["Electron Helper", "Electron Helper (GPU)", "Electron Helper (Renderer)", "Electron Helper (Plugin)"]
        let eligible = [
            "Contents/MacOS/Electron",
            "\(framework)/Versions/A/Electron Framework",
            "\(framework)/Versions/A/Helpers/chrome_crashpad_handler",
            "\(squirrel)/Versions/A/Squirrel",
            "Contents/Helpers/native-host",
        ] + helpers.map { "Contents/Frameworks/\($0).app/Contents/MacOS/\($0)" }
        for path in eligible {
            #expect(isEligible(d[path]), "\(path): \(String(describing: d[path]))")
        }

        // The app seals the framework by cdhash, but the framework's own seal
        // covers Libraries/ as data.
        for lib in ["libEGL", "libGLESv2", "libffmpeg"] {
            #expect(d["\(framework)/Versions/A/Libraries/\(lib).dylib"] == .skip(.sealedAsData(by: framework)))
        }
        // Squirrel's updater is signed, but sits in the framework's Resources.
        #expect(d["\(squirrel)/Versions/A/Resources/ShipIt"] == .skip(.sealedAsData(by: squirrel)))
        let node = "Contents/Resources/app.asar.unpacked/node_modules/native/build/Release/native.node"
        #expect(d[node] == .skip(.sealedAsData(by: "")))
        #expect(d.count == eligible.count + 5)
    }

    @Test func onlyTheCurrentFrameworkVersionIsCovered() throws {
        let d = try classify("bundles/Multi.framework")
        #expect(isEligible(d["Versions/A/Multi"])) // Versions/Current -> A
        #expect(d["Versions/B/Multi"] == .skip(.unsealed("in a version of the bundle other than Versions/Current")))
    }

    @Test func reasonsDescribeThemselves() {
        #expect(SkipReason.sealedAsData(by: "").description
            == "sealed as data by the bundle; thinning would break its signature")
        #expect(SkipReason.sealedAsData(by: "Contents/Frameworks/X.framework").description
            == "sealed as data by Contents/Frameworks/X.framework; thinning would break its signature")
    }
}

/// Damaged or unusual bundles, made from throwaway copies of the fixtures.
/// The copies' signatures no longer verify; the classifier must still refuse
/// everything it cannot account for.
@Suite struct BundleClassifierEdgeTests {
    private let dir: URL
    private var app: URL { dir.appending(path: "Signed.app") }

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "thinner-seal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // cp -R copies symlinks as symlinks, keeping the framework layout.
        let copy = try Shell.run("/bin/cp", "-R", try Fixtures.url("bundles/Signed.app").path, app.path)
        try #require(copy.status == 0, "\(copy.output)")
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func classify() -> [String: Decision] {
        decisions(BundleClassifier.classify(app))
    }

    private func editPlist(_ relativePath: String, _ edit: (inout [String: Any]) -> Void) throws {
        let url = app.appending(path: relativePath)
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        var plist = try #require(object as? [String: Any])
        edit(&plist)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    private static let main = "Contents/MacOS/Signed"
    private static let loose = "Contents/Frameworks/libloose.dylib"
    private static let foo = "Contents/Frameworks/Foo.framework/Versions/A/Foo"
    private static let seal = "Contents/_CodeSignature/CodeResources"

    private func expectSignatureMetadata(_ decision: Decision?, containing text: String = "",
                                         sourceLocation: SourceLocation = #_sourceLocation) {
        guard case let .skip(.signatureMetadata(detail)) = decision else {
            Issue.record("expected signatureMetadata, got \(String(describing: decision))", sourceLocation: sourceLocation)
            return
        }
        #expect(text.isEmpty || detail.contains(text), "\(detail)", sourceLocation: sourceLocation)
    }

    @Test func unsignedBundleIsSkippedEntirely() throws {
        defer { cleanUp() }
        try FileManager.default.removeItem(at: app.appending(path: "Contents/_CodeSignature"))
        let d = classify()
        #expect(d.count == 4)
        for decision in d.values { expectSignatureMetadata(decision) }
    }

    @Test func unparseableSealIsSkipped() throws {
        defer { cleanUp() }
        try Data("not a property list".utf8).write(to: app.appending(path: Self.seal))
        let d = classify()
        expectSignatureMetadata(d[Self.main], containing: "not a property list")
        expectSignatureMetadata(d[Self.loose])
    }

    @Test func sealWithoutFiles2IsSkipped() throws {
        defer { cleanUp() }
        try editPlist(Self.seal) { $0["files2"] = nil }
        expectSignatureMetadata(classify()[Self.loose], containing: "files2")
    }

    @Test func version1HashWinsOverVersion2Cdhash() throws {
        defer { cleanUp() }
        try editPlist(Self.seal) { plist in
            var files = plist["files"] as? [String: Any] ?? [:]
            files["Frameworks/libloose.dylib"] = Data(repeating: 0, count: 20)
            plist["files"] = files
        }
        #expect(classify()[Self.loose] == .skip(.sealedAsData(by: "")))
    }

    @Test func unrecognizedSealEntryIsSkipped() throws {
        defer { cleanUp() }
        try editPlist(Self.seal) { plist in
            var files2 = plist["files2"] as? [String: Any] ?? [:]
            files2["Frameworks/libloose.dylib"] = ["something": "new"]
            plist["files2"] = files2
        }
        expectSignatureMetadata(classify()[Self.loose], containing: "unrecognized entry")
    }

    /// Absence from files2 alone never makes a file eligible.
    @Test func machOTheSealDoesNotMentionIsSkipped() throws {
        defer { cleanUp() }
        let copy = try Shell.run("/bin/cp", try Fixtures.url("macho/fat-arm64-x86_64").path,
                                 app.appending(path: "Contents/MacOS/extra").path)
        try #require(copy.status == 0)
        #expect(classify()["Contents/MacOS/extra"] == .skip(.unsealed("the bundle does not seal MacOS/extra")))
    }

    @Test func fileOutsideContentsIsSkipped() throws {
        defer { cleanUp() }
        let copy = try Shell.run("/bin/cp", try Fixtures.url("macho/fat-arm64-x86_64").path,
                                 app.appending(path: "stray").path)
        try #require(copy.status == 0)
        #expect(classify()["stray"] == .skip(.unsealed("outside the code of the bundle")))
    }

    @Test func missingCFBundleExecutableSkipsTheMainExecutableOnly() throws {
        defer { cleanUp() }
        try editPlist("Contents/Info.plist") { $0["CFBundleExecutable"] = nil }
        let d = classify()
        expectSignatureMetadata(d[Self.main], containing: "no CFBundleExecutable")
        #expect(isEligible(d[Self.loose]))
        #expect(isEligible(d[Self.foo]))
    }

    @Test func mainExecutableNameMustBeAFileName() throws {
        defer { cleanUp() }
        try editPlist("Contents/Info.plist") { $0["CFBundleExecutable"] = "../MacOS/Signed" }
        expectSignatureMetadata(classify()[Self.main], containing: "is not a file name")
    }

    @Test func fileInMacOSThatIsNotTheMainExecutableIsSkipped() throws {
        defer { cleanUp() }
        try editPlist("Contents/Info.plist") { $0["CFBundleExecutable"] = "Other" }
        #expect(classify()[Self.main] == .skip(.unsealed("the bundle does not seal MacOS/Signed")))
    }

    @Test func symlinkedSealIsNotFollowed() throws {
        defer { cleanUp() }
        let signature = app.appending(path: "Contents/_CodeSignature")
        let moved = dir.appending(path: "_CodeSignature")
        try FileManager.default.moveItem(at: signature, to: moved)
        try FileManager.default.createSymbolicLink(at: signature, withDestinationURL: moved)
        expectSignatureMetadata(classify()[Self.loose], containing: "symbolic link")
    }

    @Test func frameworkCurrentMustNameASiblingVersion() throws {
        defer { cleanUp() }
        let current = app.appending(path: "Contents/Frameworks/Foo.framework/Versions/Current")
        try FileManager.default.removeItem(at: current)
        try FileManager.default.createSymbolicLink(atPath: current.path, withDestinationPath: "../../..")
        let d = classify()
        expectSignatureMetadata(d[Self.foo], containing: "does not name a version directory")
        #expect(isEligible(d[Self.main]))
    }

    @Test func nestedBundleWithoutItsOwnSealIsSkipped() throws {
        defer { cleanUp() }
        try FileManager.default.removeItem(
            at: app.appending(path: "Contents/Frameworks/Foo.framework/Versions/A/_CodeSignature"))
        let d = classify()
        expectSignatureMetadata(d[Self.foo], containing: "Foo.framework")
        #expect(isEligible(d[Self.main]))
    }

    @Test func directoryThatIsNotABundleIsSkipped() throws {
        defer { cleanUp() }
        let plain = dir.appending(path: "plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let copy = try Shell.run("/bin/cp", try Fixtures.url("macho/fat-arm64-x86_64").path, plain.appending(path: "fat").path)
        try #require(copy.status == 0)
        let d = decisions(BundleClassifier.classify(plain))
        expectSignatureMetadata(d["fat"], containing: "neither Contents nor Versions")
    }
}

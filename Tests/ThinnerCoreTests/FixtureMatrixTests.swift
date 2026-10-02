import Foundation
import Testing

/// Checks that the fixture generator produces what every later phase assumes.
/// If one of these fails, classifier and writer tests built on the fixtures
/// cannot be trusted.
@Suite struct FixtureMatrixTests {
    struct MachOCase: CustomTestStringConvertible, Sendable {
        let path: String
        let magic: [UInt8]
        let archs: Set<String>
        var testDescription: String { path }
    }

    static let fat: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE]
    static let fat64: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBF]
    static let thin64: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE] // MH_MAGIC_64, little-endian on disk

    static let machOCases: [MachOCase] = [
        .init(path: "macho/fat-arm64-x86_64", magic: fat, archs: ["arm64", "x86_64"]),
        .init(path: "macho/fat-arm64e-x86_64", magic: fat, archs: ["arm64e", "x86_64"]),
        .init(path: "macho/fat-arm64-x86_64-x86_64h", magic: fat, archs: ["arm64", "x86_64", "x86_64h"]),
        .init(path: "macho/fat64-arm64-x86_64", magic: fat64, archs: ["arm64", "x86_64"]),
        .init(path: "macho/thin-arm64", magic: thin64, archs: ["arm64"]),
        .init(path: "macho/thin-x86_64", magic: thin64, archs: ["x86_64"]),
        .init(path: "macho/quarantined-fat-arm64-x86_64", magic: fat, archs: ["arm64", "x86_64"]),
        .init(path: "bundles/Signed.app/Contents/MacOS/Signed", magic: fat, archs: ["arm64", "x86_64"]),
        .init(path: "bundles/Signed.app/Contents/Frameworks/Foo.framework/Versions/A/Foo", magic: fat, archs: ["arm64", "x86_64"]),
        .init(path: "bundles/Signed.app/Contents/Frameworks/libloose.dylib", magic: fat, archs: ["arm64", "x86_64"]),
        .init(path: "bundles/Signed.app/Contents/Resources/addon.node", magic: fat, archs: ["arm64", "x86_64"]),
        .init(path: "bundles/Electron.app/Contents/MacOS/Electron", magic: fat, archs: ["arm64", "x86_64"]),
        .init(path: "\(electronFramework)/Versions/A/Electron Framework", magic: fat, archs: ["arm64", "x86_64"]),
        .init(path: "\(electronFramework)/Versions/A/Libraries/libEGL.dylib", magic: fat, archs: ["arm64", "x86_64"]),
        .init(path: "\(electronFramework)/Versions/A/Helpers/chrome_crashpad_handler", magic: fat, archs: ["arm64", "x86_64"]),
        .init(path: "bundles/Electron.app/Contents/Frameworks/Electron Helper (GPU).app/Contents/MacOS/Electron Helper (GPU)", magic: fat, archs: ["arm64", "x86_64"]),
        .init(path: "bundles/Electron.app/Contents/Helpers/native-host", magic: fat, archs: ["arm64", "x86_64"]),
        .init(path: "\(squirrel)/Versions/A/Squirrel", magic: fat, archs: ["arm64", "x86_64"]),
        .init(path: "\(squirrel)/Versions/A/Resources/ShipIt", magic: fat, archs: ["arm64", "x86_64"]),
        .init(path: "\(electronModules)/native/build/Release/native.node", magic: fat, archs: ["arm64", "x86_64"]),
        .init(path: "\(electronModules)/pty/prebuilds/darwin-arm64/pty.node", magic: thin64, archs: ["arm64"]),
        .init(path: "\(electronModules)/pty/prebuilds/darwin-x64/pty.node", magic: thin64, archs: ["x86_64"]),
    ]

    static let electronFramework = "bundles/Electron.app/Contents/Frameworks/Electron Framework.framework"
    static let squirrel = "bundles/Electron.app/Contents/Frameworks/Squirrel.framework"
    static let electronModules = "bundles/Electron.app/Contents/Resources/app.asar.unpacked/node_modules"

    @Test(arguments: machOCases)
    func machOFixture(_ fixture: MachOCase) throws {
        let url = try Fixtures.url(fixture.path)
        #expect(try Self.header(url, count: 4) == fixture.magic)

        let lipo = try Shell.run("/usr/bin/lipo", "-archs", url.path)
        try #require(lipo.status == 0, "\(lipo.output)")
        let archs = Set(lipo.output.split(whereSeparator: \.isWhitespace).map(String.init))
        #expect(archs == fixture.archs)
    }

    /// Java class files share FAT_MAGIC. Read as a fat header, the class
    /// version fields become nfat_arch, which lands well outside the sanity
    /// bound the classifier will use to reject them.
    @Test func javaClassLooksFatButIsNot() throws {
        let url = try Fixtures.url("java/Hello.class")
        let header = try Self.header(url, count: 8)
        #expect(Array(header[0..<4]) == Self.fat)

        let nfatArch = header[4..<8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        #expect(nfatArch == 52)

        let lipo = try Shell.run("/usr/bin/lipo", "-archs", url.path)
        #expect(lipo.status != 0)
    }

    @Test func quarantineAttributeIsSet() throws {
        let url = try Fixtures.url("macho/quarantined-fat-arm64-x86_64")
        let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        #expect(size > 0)
    }

    @Test func signedAppVerifies() throws {
        let app = try Fixtures.url("bundles/Signed.app")
        let verify = try Shell.run(
            "/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", app.path
        )
        #expect(verify.status == 0, "\(verify.output)")
    }

    /// The seal classes the classifier's thin/skip decision depends on.
    @Test func signedAppSealClasses() throws {
        let url = try Fixtures.url("bundles/Signed.app/Contents/_CodeSignature/CodeResources")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let files2 = try #require((plist as? [String: Any])?["files2"] as? [String: [String: Any]])

        #expect(files2["MacOS/Signed"] == nil)
        #expect(files2["Frameworks/Foo.framework"]?["cdhash"] != nil)
        #expect(files2["Frameworks/libloose.dylib"]?["cdhash"] != nil)
        #expect(files2["Resources/addon.node"]?["hash2"] != nil)
        #expect(files2["Resources/addon.node"]?["cdhash"] == nil)
    }

    @Test func electronAppVerifies() throws {
        let app = try Fixtures.url("bundles/Electron.app")
        let verify = try Shell.run(
            "/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", app.path
        )
        #expect(verify.status == 0, "\(verify.output)")
    }

    /// The app seals the framework by cdhash, but the framework's own seal
    /// covers its Libraries as data: the case only a full seal-chain walk
    /// catches.
    @Test func electronSealChain() throws {
        let app = try Self.files2("bundles/Electron.app/Contents/_CodeSignature/CodeResources")
        #expect(app["MacOS/Electron"] == nil)
        #expect(app["Frameworks/Electron Framework.framework"]?["cdhash"] != nil)
        for helper in ["Electron Helper", "Electron Helper (GPU)", "Electron Helper (Renderer)", "Electron Helper (Plugin)"] {
            #expect(app["Frameworks/\(helper).app"]?["cdhash"] != nil, "\(helper)")
        }
        #expect(app["Helpers/native-host"]?["cdhash"] != nil)
        let native = "Resources/app.asar.unpacked/node_modules/native/build/Release/native.node"
        #expect(app[native]?["hash2"] != nil)
        #expect(app[native]?["cdhash"] == nil)

        let framework = try Self.files2("\(Self.electronFramework)/Versions/A/_CodeSignature/CodeResources")
        #expect(framework["Electron Framework"] == nil)
        #expect(framework["Helpers/chrome_crashpad_handler"]?["cdhash"] != nil)
        for lib in ["libEGL", "libGLESv2", "libffmpeg"] {
            #expect(framework["Libraries/\(lib).dylib"]?["hash2"] != nil, "\(lib)")
            #expect(framework["Libraries/\(lib).dylib"]?["cdhash"] == nil, "\(lib)")
        }
    }

    @Test func electronFrameworkExposesDirectoriesThroughSymlinks() throws {
        let framework = try Fixtures.url(Self.electronFramework)
        let fm = FileManager.default
        #expect(try fm.destinationOfSymbolicLink(atPath: framework.appending(path: "Versions/Current").path) == "A")
        for link in ["Electron Framework", "Resources", "Libraries", "Helpers"] {
            #expect(try fm.destinationOfSymbolicLink(atPath: framework.appending(path: link).path) == "Versions/Current/\(link)")
        }
    }

    @Test func frameworkUsesVersionedSymlinks() throws {
        let framework = try Fixtures.url("bundles/Signed.app/Contents/Frameworks/Foo.framework")
        let fm = FileManager.default
        #expect(try fm.destinationOfSymbolicLink(atPath: framework.appending(path: "Versions/Current").path) == "A")
        #expect(try fm.destinationOfSymbolicLink(atPath: framework.appending(path: "Foo").path) == "Versions/Current/Foo")
        #expect(try fm.destinationOfSymbolicLink(atPath: framework.appending(path: "Resources").path) == "Versions/Current/Resources")
    }

    private static func files2(_ codeResources: String) throws -> [String: [String: Any]] {
        let url = try Fixtures.url(codeResources)
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require((plist as? [String: Any])?["files2"] as? [String: [String: Any]])
    }

    private static func header(_ url: URL, count: Int) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return Array(try handle.read(upToCount: count) ?? Data())
    }
}

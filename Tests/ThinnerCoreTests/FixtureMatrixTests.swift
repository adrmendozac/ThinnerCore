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
    ]

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

    @Test func frameworkUsesVersionedSymlinks() throws {
        let framework = try Fixtures.url("bundles/Signed.app/Contents/Frameworks/Foo.framework")
        let fm = FileManager.default
        #expect(try fm.destinationOfSymbolicLink(atPath: framework.appending(path: "Versions/Current").path) == "A")
        #expect(try fm.destinationOfSymbolicLink(atPath: framework.appending(path: "Foo").path) == "Versions/Current/Foo")
        #expect(try fm.destinationOfSymbolicLink(atPath: framework.appending(path: "Resources").path) == "Versions/Current/Resources")
    }

    private static func header(_ url: URL, count: Int) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return Array(try handle.read(upToCount: count) ?? Data())
    }
}

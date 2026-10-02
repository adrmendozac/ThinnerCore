import Foundation
import Testing
import ThinnerCore

@Suite struct BundleWalkerFixtureTests {
    @Test func electronAppIsWalkedOncePerPhysicalFile() throws {
        let result = BundleWalker.walk(try Fixtures.url("bundles/Electron.app"))
        #expect(result.issues.isEmpty, "\(result.issues)")

        let framework = "Contents/Frameworks/Electron Framework.framework/Versions/A"
        let helpers = ["Electron Helper", "Electron Helper (GPU)", "Electron Helper (Renderer)", "Electron Helper (Plugin)"]
        let expected = [
            "Contents/MacOS/Electron",
            "\(framework)/Electron Framework",
            "\(framework)/Helpers/chrome_crashpad_handler",
            "\(framework)/Libraries/libEGL.dylib",
            "\(framework)/Libraries/libGLESv2.dylib",
            "\(framework)/Libraries/libffmpeg.dylib",
            "Contents/Frameworks/Squirrel.framework/Versions/A/Squirrel",
            "Contents/Frameworks/Squirrel.framework/Versions/A/Resources/ShipIt",
            "Contents/Helpers/native-host",
            "Contents/Resources/app.asar.unpacked/node_modules/native/build/Release/native.node",
        ] + helpers.map { "Contents/Frameworks/\($0).app/Contents/MacOS/\($0)" }

        // Symlinked framework directories (Libraries, Helpers, Versions/Current)
        // add no second copies; single-arch prebuilds are not universal.
        #expect(result.files.map(\.relativePath) == expected.sorted())
        for file in result.files {
            #expect(file.architectures.count == 2, "\(file.relativePath)")
            guard case .eligible(removing: [.x86_64], _) = file.decision else {
                Issue.record("\(file.relativePath): \(file.decision)")
                continue
            }
        }
    }

    @Test func nestedAppReportsEveryUniversalFileWithItsDecision() throws {
        let result = BundleWalker.walk(try Fixtures.url("bundles/Nested.app"))
        #expect(result.issues.isEmpty, "\(result.issues)")
        let decisions = Dictionary(uniqueKeysWithValues: result.files.map { ($0.relativePath, $0.decision) })

        #expect(decisions["Contents/Frameworks/libarm64e.dylib"] == .skip(.noARM64))
        #expect(decisions["Contents/Frameworks/libintel.dylib"] == .skip(.noARM64))
        #expect(decisions["Contents/Frameworks/libapple.dylib"] == .skip(.noIntel))
        #expect(decisions["Contents/Frameworks/libthin.dylib"] == nil) // not universal
        #expect(decisions["Contents/Resources/Hello.class"] == nil) // Java, not Mach-O
        #expect(decisions["Contents/MacOS/Nested"] != nil)
        #expect(decisions["Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper"] != nil)
    }

    @Test func sizesMatchTheFilesystem() throws {
        let root = try Fixtures.url("bundles/Signed.app")
        for file in BundleWalker.walk(root).files {
            let attributes = try FileManager.default.attributesOfItem(atPath: root.appending(path: file.relativePath).path)
            #expect(file.size == (attributes[.size] as? UInt64), "\(file.relativePath)")
        }
    }
}

/// Cases that need a filesystem layout the shared fixtures do not have. Each
/// test builds its own throwaway directory from copies of fixture files.
@Suite struct BundleWalkerEdgeTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "thinner-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "root"), withIntermediateDirectories: true)
    }

    private var root: URL { dir.appending(path: "root") }

    private func copyFixture(_ fixture: String, to relativePath: String) throws {
        let destination = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try Fixtures.url(fixture), to: destination)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func symlinksOutOfTheRootAreNotFollowed() throws {
        defer { cleanUp() }
        let outside = dir.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try Fixtures.url("macho/fat-arm64-x86_64"), to: outside.appending(path: "fat"))
        try copyFixture("macho/fat-arm64-x86_64", to: "inside")

        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: root.appending(path: "file-link").path, withDestinationPath: "../outside/fat")
        try fm.createSymbolicLink(atPath: root.appending(path: "dir-link").path, withDestinationPath: outside.path)
        try fm.createSymbolicLink(atPath: root.appending(path: "loop").path, withDestinationPath: ".")

        let result = BundleWalker.walk(root)
        #expect(result.files.map(\.relativePath) == ["inside"])
        #expect(result.issues.isEmpty, "\(result.issues)")
    }

    @Test func aSymlinkedRootIsRefused() throws {
        defer { cleanUp() }
        try copyFixture("macho/fat-arm64-x86_64", to: "fat")
        let link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.path)

        let result = BundleWalker.walk(link)
        #expect(result.files.isEmpty)
        #expect(result.issues.map(\.relativePath) == [""])
        #expect(result.issues.map(\.problem) == ["is a symbolic link"])
    }

    @Test func hardLinkedFilesAreSkipped() throws {
        defer { cleanUp() }
        try copyFixture("macho/fat-arm64-x86_64", to: "a")
        try FileManager.default.linkItem(at: root.appending(path: "a"), to: root.appending(path: "b"))

        let result = BundleWalker.walk(root)
        #expect(result.files.map(\.relativePath) == ["a", "b"])
        #expect(result.files.allSatisfy { $0.decision == .skip(.hardLinked) })
    }

    @Test func fifosAreNotOpened() throws {
        defer { cleanUp() }
        try #require(mkfifo(root.appending(path: "pipe").path, 0o600) == 0)
        try copyFixture("macho/fat-arm64-x86_64", to: "fat")

        let result = BundleWalker.walk(root) // would block forever if the FIFO were opened
        #expect(result.files.map(\.relativePath) == ["fat"])
        #expect(result.issues.isEmpty)
    }

    @Test func unreadableFilesAreReportedNotSkipped() throws {
        defer {
            chmod(root.appending(path: "locked").path, 0o600)
            cleanUp()
        }
        try copyFixture("macho/fat-arm64-x86_64", to: "locked")
        try copyFixture("macho/fat-arm64-x86_64", to: "open")
        try #require(chmod(root.appending(path: "locked").path, 0o000) == 0)
        try #require(getuid() != 0, "root can read anything; this test needs a normal user")

        let result = BundleWalker.walk(root)
        #expect(result.files.map(\.relativePath) == ["open"])
        #expect(result.issues.map(\.relativePath) == ["locked"])
    }

    @Test func sliceThatIsNotMachOIsMalformed() throws {
        defer { cleanUp() }
        try copyFixture("macho/fat-arm64-x86_64", to: "fat")
        let path = root.appending(path: "fat").path

        // Overwrite the first bytes of the arm64 slice in the throwaway copy.
        let data = Array(try Data(contentsOf: URL(filePath: path)))
        let parsed = try #require(FatBinary.parse(Array(data.prefix(FatBinary.maxHeaderLength)), fileSize: UInt64(data.count)).fat)
        let arm = try #require(parsed.slices.first(where: { $0.arch == .arm64 }))
        var corrupted = data
        corrupted.replaceSubrange(Int(arm.offset)..<Int(arm.offset) + 4, with: [0, 0, 0, 0])
        try Data(corrupted).write(to: URL(filePath: path))

        let file = try #require(BundleWalker.walk(root).files.first)
        #expect(file.decision == .skip(.malformed("slice arm64 is not a Mach-O image")))
    }

    @Test func malformedHeaderIsReportedWithoutArchitectures() throws {
        defer { cleanUp() }
        // A fat header whose only slice runs past the end of the file.
        let header = fatHeader([.arm64()])
        try Data(header).write(to: root.appending(path: "broken"))

        let file = try #require(BundleWalker.walk(root).files.first)
        #expect(file.architectures.isEmpty)
        guard case .skip(.malformed) = file.decision else {
            Issue.record("expected malformed, got \(file.decision)")
            return
        }
    }
}

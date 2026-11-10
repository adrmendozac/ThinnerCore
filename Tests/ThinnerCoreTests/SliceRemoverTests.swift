import Foundation
import Testing
@testable import ThinnerCore

/// The in-process replacement for `lipo -remove`. `lipo` is used here only
/// as the reference its output must match byte for byte.
@Suite struct SliceRemoverTests {
    static let electron = "bundles/Electron.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"

    static let cases: [FatBinaryFixtureTests.LipoCase] = [
        .init(path: "macho/fat-arm64-x86_64", remove: [.x86_64]),
        .init(path: "macho/fat-arm64-x86_64-x86_64h", remove: [.x86_64, .x86_64h]),
        .init(path: "macho/fat-arm64-x86_64-x86_64h", remove: [.x86_64h]),
        .init(path: "macho/fat64-arm64-x86_64", remove: [.x86_64]),
        .init(path: "macho/quarantined-fat-arm64-x86_64", remove: [.x86_64]),
        .init(path: electron, remove: [.x86_64]),
    ]

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "slices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test(arguments: cases)
    func matchesLipoByteForByte(_ fixture: FatBinaryFixtureTests.LipoCase) throws {
        let source = try Fixtures.url(fixture.path)
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let native = dir.appending(path: "native")
        let reference = dir.appending(path: "lipo")

        try SliceRemover.remove(fixture.remove, from: source.path, to: native.path)
        var arguments = [source.path]
        for arch in fixture.remove.map(\.description).sorted() { arguments += ["-remove", arch] }
        let lipo = try Shell.run("/usr/bin/lipo", arguments: arguments + ["-output", reference.path])
        try #require(lipo.status == 0, "\(lipo.output)")

        #expect(try Data(contentsOf: native) == Data(contentsOf: reference))
    }

    @Test func neverLeavesAFileWithoutArm64() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appending(path: "out")
        #expect(throws: Problem.self) {
            try SliceRemover.remove([.arm64], from: Fixtures.url("macho/fat-arm64-x86_64").path, to: output.path)
        }
        #expect(throws: Problem.self, "arm64e alone is not enough") {
            try SliceRemover.remove([.x86_64], from: Fixtures.url("macho/fat-arm64e-x86_64").path, to: output.path)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func refusesWhatItCannotDo() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appending(path: "out")
        for (path, remove) in [("macho/fat-arm64-x86_64", Set([Arch.x86_64h])), ("macho/thin-arm64", [.x86_64]),
                               ("java/Hello.class", [.x86_64]), ("macho/fat-arm64-x86_64", [])] {
            #expect(throws: Problem.self, "\(path)") {
                try SliceRemover.remove(remove, from: Fixtures.url(path).path, to: output.path)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path), "nothing left behind")
    }

    /// The output is created exclusively and never through a symlink, so a
    /// file planted at the temp path cannot be overwritten or redirected.
    @Test func neverOverwritesOrFollowsTheOutput() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Fixtures.url("macho/fat-arm64-x86_64").path
        let existing = dir.appending(path: "existing")
        try Data("keep".utf8).write(to: existing)
        let link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appending(path: "target"))

        #expect(throws: Problem.self) { try SliceRemover.remove([.x86_64], from: source, to: existing.path) }
        #expect(try Data(contentsOf: existing) == Data("keep".utf8))
        #expect(throws: Problem.self) { try SliceRemover.remove([.x86_64], from: source, to: link.path) }
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "target").path))
    }
}

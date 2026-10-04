import Darwin
import Foundation
import Testing
@testable import ThinnerCore

@Suite struct MetadataDurabilityTests {
    @Test func copiesACLAndXattrsAndDetectsSubsequentMismatch() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "metadata-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "source").path
        let dest = dir.appending(path: "dest").path
        let src = open(source, O_CREAT | O_RDWR, 0o600)
        let dst = open(dest, O_CREAT | O_RDWR, 0o600)
        defer { close(src); close(dst) }
        try #require(src >= 0 && dst >= 0)
        let bytes: [UInt8] = [0, 1, 0, 255]
        try #require(bytes.withUnsafeBytes { fsetxattr(src, "dev.thinner.test", $0.baseAddress, $0.count, 0, 0) } == 0)
        try #require(try Shell.run("/bin/chmod", "+a", "everyone allow read", source).status == 0)
        let expected = try MetadataCopier.read(fd: src)
        #expect(!expected.acl.isEmpty)
        #expect(expected.xattrs["dev.thinner.test"] == Data(bytes))
        #expect(try MetadataCopier.copy(from: source, to: dest, sourceFD: src, destFD: dst) == nil)
        #expect(try MetadataCopier.read(fd: dst) == expected)
        try #require(fremovexattr(dst, "dev.thinner.test", 0) == 0)
        #expect(try MetadataCopier.verify(fd: dst, expected: expected) != nil)
        try #require(bytes.withUnsafeBytes { fsetxattr(dst, "dev.thinner.test", $0.baseAddress, $0.count, 0, 0) } == 0)
        try #require(try Shell.run("/bin/chmod", "-N", dest).status == 0)
        #expect(try MetadataCopier.verify(fd: dst, expected: expected) != nil)
    }

    /// Regression: `fcopyfile` rewrites the timestamp in `com.apple.quarantine`
    /// (observed on a real download, 2026-10-03), so the strict read-back
    /// refused every quarantined file. The value must arrive byte for byte.
    @Test func copiesQuarantineExactly() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "metadata-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "source").path
        let dest = dir.appending(path: "dest").path
        let src = open(source, O_CREAT | O_RDWR, 0o644)
        let dst = open(dest, O_CREAT | O_RDWR, 0o644)
        defer { close(src); close(dst) }
        try #require(src >= 0 && dst >= 0)
        let quarantine = Data("0081;6ac1bbc2;Chrome;D75BD39A-130E-4DB5-B0CD-5A2BCF5BF2F8".utf8)
        try #require(quarantine.withUnsafeBytes { fsetxattr(src, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) } == 0)

        #expect(try MetadataCopier.copy(from: source, to: dest, sourceFD: src, destFD: dst) == nil)
        #expect(try MetadataCopier.read(fd: dst).xattrs["com.apple.quarantine"] == quarantine)
    }

    /// `com.apple.provenance` is the one exemption: macOS sets it from the
    /// writing process and silently ignores writes to it, so a thinned file
    /// can never carry the original's. Every other xattr, an extra one
    /// included, still counts. Tests cannot create two different provenance
    /// tags, so the rule is checked directly.
    @Test func provenanceIsTheOnlyExemptXattr() {
        func metadata(_ xattrs: [String: Data]) -> MetadataCopier.Metadata {
            MetadataCopier.Metadata(uid: 501, gid: 20, mode: 0o755, flags: 0, acl: "", xattrs: xattrs)
        }
        let original = metadata(["com.apple.provenance": Data([1, 2]), "com.apple.quarantine": Data("q".utf8)])
        #expect(MetadataCopier.matches(metadata(["com.apple.provenance": Data([9]), "com.apple.quarantine": Data("q".utf8)]), original))
        #expect(MetadataCopier.matches(metadata(["com.apple.quarantine": Data("q".utf8)]), original))
        #expect(!MetadataCopier.matches(metadata(["com.apple.provenance": Data([1, 2]), "com.apple.quarantine": Data("r".utf8)]), original))
        #expect(!MetadataCopier.matches(metadata(["com.apple.provenance": Data([1, 2])]), original))
        #expect(!MetadataCopier.matches(metadata(["com.apple.provenance": Data([1, 2]), "com.apple.quarantine": Data("q".utf8),
                                                  "dev.thinner.extra": Data()]), original))
    }

    @Test func journalPropagatesDirectoryFlushFailure() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "journal-flush-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = Journal(operationID: UUID().uuidString, bundlePath: dir.appending(path: "Fixture.app").path,
                              startedAt: "test")
        do {
            try journal.persist(to: dir.appending(path: "journal.json"), flushDirectory: { _ in "injected EIO" })
            Issue.record("A failed directory flush must not report persistence success")
        } catch {
            #expect(error.description.contains("injected EIO"))
        }
        #expect(syncDirectory(dir.appending(path: "missing").path) != nil)
    }
}

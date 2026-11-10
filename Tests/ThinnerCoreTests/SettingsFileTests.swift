import Darwin
import Foundation
import Testing
@testable import ThinnerCore

/// Settings read on a user's behalf (the LaunchServices preferences) are
/// read bounded, and never through a symlink, FIFO, or device.
@Suite struct SettingsFileTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func commentedListEntriesCanBeRemovedUsingTheirDisplayedNames() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["skip-list.txt", "allow-list.txt"] {
            let file = dir.appending(path: name)
            let kept = "# Keep this heading\r\ncom.example.other # keep this entry\r\n"
            try Data((kept + " com.example.app # inline comment\r\ncom.example.app\r\n").utf8).write(to: file)
            #expect(try SkipListFile.entries(at: file).contains("com.example.app"))
            #expect(try SkipListFile.remove("com.example.app", at: file))
            #expect(try SkipListFile.entries(at: file) == ["com.example.other"])
            #expect(try String(contentsOf: file, encoding: .utf8) == kept)
            #expect(try !SkipListFile.remove("com.example.app", at: file))
        }
    }

    @Test func readsARegularFileAndReportsAbsence() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "file")
        try Data("hello".utf8).write(to: file)
        #expect(try readSettingsFile(file.path, limit: 5) == Data("hello".utf8))
        #expect(try readSettingsFile(dir.appending(path: "missing").path, limit: 5) == nil)
        #expect(throws: Problem.self, "over the limit") { try readSettingsFile(file.path, limit: 4) }
    }

    @Test func refusesSymlinksDirectoriesAndDevices() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appending(path: "target")
        try Data("x".utf8).write(to: target)
        let link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        for path in [link.path, dir.path, "/dev/zero"] {
            #expect(throws: Problem.self, "\(path)") { try readSettingsFile(path, limit: 1 << 20) }
        }
    }

    /// Regression: the preferences were read with Data(contentsOf:), so a
    /// FIFO at that path hung the scan for ever, also a scan run as root.
    @Test(.timeLimit(.minutes(1))) func preferencesFifoIsInconclusiveNotAHang() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appending(path: "com.apple.LaunchServices.plist")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let flags = RosettaFlags(preferences: fifo)
        guard case .unreadable = flags.status.preferences else {
            Issue.record("expected unreadable, got \(flags.status.preferences)"); return
        }
        guard case .inconclusive = flags.flag(for: "com.example.app") else {
            Issue.record("an unreadable file must never mean not flagged"); return
        }
    }

    @Test func absentPreferencesMeanNothingFlagged() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let flags = RosettaFlags(preferences: dir.appending(path: "missing.plist"))
        #expect(flags.status.preferences == .absent)
        #expect(flags.flag(for: "com.example.app") == .notFlagged)
    }
}

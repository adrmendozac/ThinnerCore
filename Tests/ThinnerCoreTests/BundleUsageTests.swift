import Foundation
import Testing
@testable import ThinnerCore

/// Running-process detection on disposable directories, with copies of
/// `/bin/sleep` and `/usr/bin/tail` as the processes. Never an installed app.
@Suite struct BundleUsageTests {
    let dir: URL
    let bundle: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "thinner-usage-\(UUID().uuidString)")
        bundle = dir.appending(path: "Fake.app")
        try FileManager.default.createDirectory(at: bundle.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try Data("data".utf8).write(to: bundle.appending(path: "Contents/data.txt"))
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: bundle.appending(path: "Contents/MacOS/sleeper").path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func findsNothingWhenUnused() throws {
        defer { remove() }
        // A process a parallel test is spawning briefly holds copies of this
        // process's close-on-exec descriptors, which can include the scan's
        // own walk of the bundle; it is gone by the next scan. A real use
        // would persist, so rescan a few times before calling it a use.
        var result = try BundleUsage.scan(bundle)
        for _ in 0..<3 where !result.uses.isEmpty { result = try BundleUsage.scan(bundle) }
        #expect(result.uses.isEmpty, "\(result.uses)")
        #expect(result.inspected > 0)
    }

    /// Regression: libproc failures other than EPERM read as "no files", so
    /// a process that could not be fully inspected counted as idle.
    @Test func onlyMeasuredEndAnswersCountAsComplete() {
        #expect(BundleUsage.regionWalkEnd(errno: EINVAL, paths: ["a"]) == .read(["a"]))
        #expect(BundleUsage.regionWalkEnd(errno: ESRCH, paths: ["a"]) == .gone)
        for code in [EPERM, ENOMEM, EIO, ENOENT, 0] {
            #expect(BundleUsage.regionWalkEnd(errno: code, paths: []) == .unreadable, "errno \(code)")
        }
        #expect(BundleUsage.emptyFDList(errno: 0) == .read([]))
        #expect(BundleUsage.emptyFDList(errno: ESRCH) == .gone)
        for code in [EPERM, ENOMEM, EINVAL] {
            #expect(BundleUsage.emptyFDList(errno: code) == .unreadable, "errno \(code)")
        }
        #expect(BundleUsage.fdInfoFailure(errno: EBADF, bytes: 0) == nil, "a closed descriptor is skipped")
        #expect(BundleUsage.fdInfoFailure(errno: ESRCH, bytes: 0) == .gone)
        #expect(BundleUsage.fdInfoFailure(errno: EPERM, bytes: 0) == .unreadable)
        #expect(BundleUsage.fdInfoFailure(errno: 0, bytes: 12) == .unreadable, "a short result is partial")
    }

    /// launchd belongs to root, so a normal user cannot read its files; the
    /// scan must count it rather than call it idle.
    @Test func countsAnotherUsersProcessAsUninspectable() throws {
        defer { remove() }
        try #require(getuid() != 0, "root can read every process; this test needs a normal user")
        #expect(BundleUsage.regions(1, BundleUsage.Matcher(bundle: bundle.path, files: [])) == .unreadable)
        #expect(BundleUsage.openFiles(1, BundleUsage.Matcher(bundle: bundle.path, files: [])) == .unreadable)
        #expect(try BundleUsage.scan(bundle).uninspectable > 0)
    }

    /// Regression: the identity walk skipped directories it could not list,
    /// so a file in one, in use through an outside hard link, went unseen.
    @Test func refusesABundleItCannotFullyList() throws {
        let locked = bundle.appending(path: "Contents/Locked")
        defer {
            chmod(locked.path, 0o755)
            remove()
        }
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: locked.appending(path: "lib.dylib"))
        try #require(chmod(locked.path, 0o000) == 0)
        try #require(getuid() != 0, "root can list anything; this test needs a normal user")
        #expect(throws: Problem.self) { try BundleUsage.scan(bundle) }
    }

    @Test func findsAnExecutableInsideTheBundle() throws {
        defer { remove() }
        let process = try start(bundle.appending(path: "Contents/MacOS/sleeper").path, ["30"])
        defer { stop(process) }
        let use = try waitForUse(by: process.processIdentifier)
        #expect(use?.how == .executable)
    }

    @Test func findsAFileHeldOpenByAnOutsideProcess() throws {
        defer { remove() }
        let process = try start("/usr/bin/tail", ["-f", bundle.appending(path: "Contents/data.txt").path])
        defer { stop(process) }
        let use = try waitForUse(by: process.processIdentifier)
        #expect(use?.how == .open)
    }

    /// The kernel may report a hard-linked file under any of its names, so
    /// only file identity catches a bundle executable run from outside.
    @Test func findsABundleExecutableRunThroughAHardLink() throws {
        defer { remove() }
        let link = dir.appending(path: "outside-link").path
        try #require(Darwin.link(bundle.appending(path: "Contents/MacOS/sleeper").path, link) == 0)
        let process = try start(link, ["30"])
        defer { stop(process) }
        #expect(try waitForUse(by: process.processIdentifier) != nil)
    }

    @Test func translocationMountsMapToTheBundle() {
        // No nullfs mount exists in tests; the function must at least not
        // invent one for an ordinary path.
        #expect(BundleUsage.translocatedPaths(of: bundle.path).isEmpty)
    }

    private func start(_ executable: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func stop(_ process: Process) {
        process.terminate()
        process.waitUntilExit()
    }

    private func waitForUse(by pid: pid_t) throws -> BundleUsage.Use? {
        for _ in 0..<50 {
            if let use = try BundleUsage.scan(bundle).uses.first(where: { $0.pid == pid }) { return use }
            usleep(100_000)
        }
        Issue.record("process \(pid) never showed up as using \(bundle.path)")
        return nil
    }
}

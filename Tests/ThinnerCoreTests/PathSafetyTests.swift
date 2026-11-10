import Darwin
import Foundation
import Testing
@testable import ThinnerCore

/// A run as root must not act on an app below a directory another user
/// controls: they could swap in a symlink and redirect root's writes.
@Suite struct PathSafetyTests {
    /// A directory owned by `uid`, group `gid`, with permission bits `mode`.
    func dir(_ uid: uid_t, _ gid: gid_t = 0, _ mode: mode_t = 0o755) -> stat {
        var info = stat()
        info.st_mode = S_IFDIR | mode
        info.st_uid = uid
        info.st_gid = gid
        return info
    }

    func check(_ tree: [String: stat], euid: uid_t = 0, invoker: uid_t? = 501) -> String? {
        PathSafety.untrustedAncestor(of: "/Users/sam/Applications/App.app", euid: euid, invoker: invoker) { tree[$0] }
    }

    var safe: [String: stat] {
        ["/": dir(0), "/Users": dir(0, 80), "/Users/sam": dir(501, 20, 0o750), "/Users/sam/Applications": dir(501, 20)]
    }

    @Test func invokingUsersOwnFoldersAreTrusted() {
        #expect(check(safe) == nil)
    }

    @Test func unprivilegedRunsAreNotChecked() {
        var tree = safe
        tree["/Users/sam/Applications"] = dir(502)
        #expect(check(tree, euid: 501) == nil)
    }

    @Test func folderOwnedByAnotherUserRefuses() throws {
        var tree = safe
        tree["/Users/sam/Applications"] = dir(502)
        #expect(try #require(check(tree)).contains("/Users/sam/Applications"))
        // Without sudo, only root's folders are trusted.
        #expect(check(safe, invoker: nil) != nil)
    }

    @Test func worldWritableFolderRefusesUnlessSticky() {
        var tree = safe
        tree["/Users/sam/Applications"] = dir(501, 20, 0o777)
        #expect(check(tree) != nil)
        tree["/Users/sam/Applications"] = dir(501, 20, 0o1777)
        #expect(check(tree) == nil)
    }

    @Test func groupWritableFolderRefusesUnlessAdminOrWheel() {
        var tree = safe
        tree["/Users/sam/Applications"] = dir(501, 20, 0o775) // staff
        #expect(check(tree) != nil)
        tree["/Users/sam/Applications"] = dir(0, 80, 0o775) // root:admin, like /Applications
        #expect(check(tree) == nil)
    }

    @Test func symlinkInThePathRefuses() {
        var tree = safe
        var link = dir(501)
        link.st_mode = S_IFLNK | 0o755
        tree["/Users/sam/Applications"] = link
        #expect(check(tree) != nil)
    }

    @Test func sudoUIDIgnoresRootAndGarbage() {
        #expect(PathSafety.sudoUID(["SUDO_UID": "501"]) == 501)
        #expect(PathSafety.sudoUID(["SUDO_UID": "0"]) == nil)
        #expect(PathSafety.sudoUID(["SUDO_UID": "x"]) == nil)
        #expect(PathSafety.sudoUID([:]) == nil)
    }

    /// The swap refuses a path whose directory was replaced by a symlink.
    @Test func renameRefusesASymlinkedDirectory() throws {
        let dir = try #require(realPath(FileManager.default.temporaryDirectory.path))
            + "/thinner-rename-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/real", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: dir + "/real")
        try Data("x".utf8).write(to: URL(filePath: dir + "/file"))

        #expect(PathSafety.renameNoFollow(dir + "/file", dir + "/link/file") != nil)
        #expect(!FileManager.default.fileExists(atPath: dir + "/real/file"))
        #expect(PathSafety.renameNoFollow(dir + "/file", dir + "/real/file") == nil)
        #expect(FileManager.default.fileExists(atPath: dir + "/real/file"))
    }
}

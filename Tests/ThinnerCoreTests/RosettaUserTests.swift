import Foundation
import Testing
@testable import ThinnerCore

/// Whose "Open using Rosetta" choices a run honors by default. Apply needs
/// root to inspect every process, and root's own preferences never hold the
/// user's choices, so a run under sudo must read the invoking user's.
@Suite struct RosettaUserTests {
    @Test func unprivilegedRunReadsItsOwnPreferences() throws {
        let user = RosettaFlags.defaultPreferencesUser(euid: 501, environment: ["SUDO_UID": "502"], consoleUID: { 503 })
        #expect(try user.get() == 501)
    }

    @Test func sudoRunReadsTheInvokingUsersPreferences() throws {
        let user = RosettaFlags.defaultPreferencesUser(euid: 0, environment: ["SUDO_UID": "501"], consoleUID: { 502 })
        #expect(try user.get() == 501)
    }

    @Test func rootRunWithoutSudoReadsTheConsoleUsersPreferences() throws {
        let user = RosettaFlags.defaultPreferencesUser(euid: 0, environment: [:], consoleUID: { 502 })
        #expect(try user.get() == 502)
    }

    @Test(arguments: [["SUDO_UID": "0"], [:], ["SUDO_UID": "not a number"]])
    func rootRunWithNoUserFailsClosed(environment: [String: String]) {
        let user = RosettaFlags.defaultPreferencesUser(euid: 0, environment: environment, consoleUID: { 0 })
        guard case let .failure(problem) = user else {
            Issue.record("expected failure, got \(user)")
            return
        }
        #expect(problem.description.contains("--rosetta-preferences"))
    }

    /// A root run with no user to read must skip every app, never treat it
    /// as not flagged.
    @Test func noDefaultUserSkipsEveryAppAsInconclusive() throws {
        let options = ScanOptions(launchServicesPreferences: nil,
                                  defaultUser: .failure(Problem("no user to read")))
        let result = AppScanner.scan(try Fixtures.url("bundles/Signed.app"), options: options)
        let app = try #require(result.apps.first)
        guard case let .rosettaInconclusive(detail) = app.skip else {
            Issue.record("expected rosettaInconclusive, got \(String(describing: app.skip))")
            return
        }
        #expect(detail.contains("no user to read"))
    }

    /// The report credits the user whose preferences were chosen even when
    /// their file does not exist, rather than the effective user (root).
    @Test func reportNamesTheChosenUser() throws {
        let absent = FileManager.default.temporaryDirectory.appending(path: "absent-\(UUID().uuidString).plist")
        let flags = RosettaFlags(preferences: absent, owner: 1)
        let name = String(cString: getpwuid(1)!.pointee.pw_name)
        #expect(flags.status.preferencesUser == name)
        #expect(flags.status.preferences == .absent)
    }
}

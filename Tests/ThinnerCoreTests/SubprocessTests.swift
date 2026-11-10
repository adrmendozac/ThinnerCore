import Foundation
import Testing
@testable import ThinnerCore

@Suite struct SubprocessTests {
    @Test func reportsStatusAndOutput() throws {
        let result = try Subprocess.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], timeout: 30)
        #expect(result.status == 3)
        #expect(!result.timedOut)
        #expect(result.output.contains("out") && result.output.contains("err"))
    }

    /// A hung tool must not hold the app's lock forever.
    @Test func killsAToolThatOutlivesItsTimeout() throws {
        let start = Date()
        let result = try Subprocess.run("/bin/sleep", ["60"], timeout: 1)
        #expect(result.timedOut)
        #expect(result.status != 0)
        #expect(Date().timeIntervalSince(start) < 30)
    }

    /// Regression: tools inherited the whole environment, so DEVELOPER_DIR,
    /// DYLD_* or PATH could steer them, also under `sudo -E`. Checked with
    /// HOME, which every test process has; changing the environment here
    /// would leak into tests running in parallel.
    @Test func toolsRunWithAMinimalEnvironment() throws {
        #expect(ProcessInfo.processInfo.environment["HOME"] != nil)
        let result = try Subprocess.run("/usr/bin/env", [], timeout: 30)
        #expect(Set(result.output.split(separator: "\n").map(String.init))
            == ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C"])
    }
}

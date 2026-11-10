import Foundation

/// Runs a system tool to completion, killed if it outlives `timeout`. The
/// write path holds the app's lock while `codesign` and `lipo` run, so a
/// hung tool must not hold it forever.
enum Subprocess {
    struct Result {
        let status: Int32
        /// stdout and stderr, interleaved.
        let output: String
        let timedOut: Bool
    }

    /// The whole environment every tool runs with.
    static let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws(Problem) -> Result {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        // Nothing inherited: variables such as DEVELOPER_DIR, DYLD_*, or a
        // PATH entry must not steer a tool this run starts, least of all a
        // run as root under `sudo -E`.
        process.environment = environment
        // One pipe for both streams, drained before waiting, so the tool can
        // never block on a full buffer.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw Problem("cannot run \(executable): \(error.localizedDescription)")
        }
        let timer = Timer(process, after: timeout)
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: output, timedOut: timer.finish())
    }

    /// Terminates the process when the deadline passes, then kills it if it
    /// is still there a few seconds later.
    private final class Timer: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var fired = false

        init(_ process: Process, after timeout: TimeInterval) {
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                guard fire() else { return }
                kill(pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
                    if !isDone() { kill(pid, SIGKILL) }
                }
            }
        }

        private func fire() -> Bool {
            lock.withLock {
                if done { return false }
                fired = true
                return true
            }
        }

        private func isDone() -> Bool { lock.withLock { done } }

        /// Stops the timer; true if it fired.
        func finish() -> Bool {
            lock.withLock {
                done = true
                return fired
            }
        }
    }
}

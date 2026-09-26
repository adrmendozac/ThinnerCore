import Foundation

enum Shell {
    struct Result {
        let status: Int32
        /// stdout and stderr, interleaved.
        let output: String
    }

    struct Failure: Error, CustomStringConvertible {
        let command: String
        let result: Result
        var description: String {
            "\(command) exited \(result.status): \(result.output)"
        }
    }

    static func run(_ executable: String, _ arguments: String...) throws -> Result {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        // One pipe for both streams, drained before waiting, so the child can
        // never block on a full buffer.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: output, as: UTF8.self)
        )
    }
}

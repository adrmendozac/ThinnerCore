import Foundation

enum Lipo {
    static func remove(architectures: Set<Arch>, from input: String, to output: String) throws(Problem) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/lipo")
        var args = [input]
        for arch in architectures {
            args.append("-remove")
            args.append(arch.description)
        }
        args.append("-output")
        args.append(output)
        process.arguments = args
        
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        
        do {
            try process.run()
        } catch {
            throw Problem("cannot run lipo: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Problem("lipo failed: \(out.isEmpty ? "exit \(process.terminationStatus)" : out)")
        }
    }
}

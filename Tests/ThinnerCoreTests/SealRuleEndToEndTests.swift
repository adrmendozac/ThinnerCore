import Foundation
import Testing
import ThinnerCore

/// Phase 0, gate 1: the seal-class rule, end to end.
///
/// For every file whose outcome depends on the seal chain, a throwaway copy of
/// the fixture app has that one file thinned with `lipo -remove`, then the
/// system decides: `codesign --verify --deep --strict --all-architectures`
/// must accept the copy exactly when the classifier called the file eligible.
/// Eligible files must also shrink to the predicted size, and eligible
/// executables must still run. Only fixture copies are ever modified.
@Suite struct SealRuleEndToEndTests {
    static let apps = ["bundles/Signed.app", "bundles/Nested.app", "bundles/Electron.app"]

    /// Skips that the seal chain decides; architecture skips never reach it.
    private static func dependsOnSeals(_ decision: Decision) -> Bool {
        switch decision {
        case .eligible: true
        case .skip(.sealedAsData), .skip(.unsealed), .skip(.signatureMetadata): true
        case .skip: false
        }
    }

    @Test(arguments: apps)
    func classifierAgreesWithCodesign(_ app: String) throws {
        let source = try Fixtures.url(app)
        let candidates = BundleClassifier.classify(source).files.filter { Self.dependsOnSeals($0.decision) }
        try #require(!candidates.isEmpty)
        // Each fixture has both outcomes, so neither side can pass vacuously.
        #expect(candidates.contains { $0.decision.isEligible })
        #expect(candidates.contains { !$0.decision.isEligible })

        let dir = FileManager.default.temporaryDirectory.appending(path: "thinner-gate1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        for file in candidates {
            let copy = dir.appending(path: source.lastPathComponent)
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try #require(try Shell.run("/bin/cp", "-R", source.path, copy.path).status == 0)

            let target = copy.appending(path: file.relativePath)
            let thin = dir.appending(path: "thin")
            let removals = file.architectures.filter(\.isIntel).flatMap { ["-remove", $0.description] }
            let lipo = try Shell.run("/usr/bin/lipo", arguments: [target.path] + removals + ["-output", thin.path])
            try #require(lipo.status == 0, "\(file.relativePath): \(lipo.output)")
            try #require(rename(thin.path, target.path) == 0)

            let verify = try Shell.run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", copy.path)
            let eligible = file.decision.isEligible
            #expect((verify.status == 0) == eligible,
                    "\(app)/\(file.relativePath): classifier \(file.decision), codesign \(verify.status): \(verify.output)")

            guard eligible else { continue }
            let size = try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? UInt64
            #expect(size == file.size - file.decision.savedBytes, "\(file.relativePath)")
            if try Self.isExecutable(target) {
                let run = try Shell.run(target.path)
                #expect(run.status == 0, "\(app)/\(file.relativePath) failed to run after thinning: \(run.output)")
            }
        }
    }

    /// True if the remaining arm64 slice is an `MH_EXECUTE` image.
    private static func isExecutable(_ url: URL) throws -> Bool {
        let bytes = Array(try Data(contentsOf: url))
        guard let binary = FatBinary.parse(Array(bytes.prefix(FatBinary.maxHeaderLength)), fileSize: UInt64(bytes.count)).fat,
              let slice = binary.slices.first(where: { $0.arch == .arm64 })
        else { return false }
        let at = Int(slice.offset) + 12 // mach_header.filetype, little-endian
        let fileType = bytes[at..<at + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return fileType == 2 // MH_EXECUTE
    }
}

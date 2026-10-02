import Foundation

/// Classifies every universal file in one signed bundle: the architecture
/// rule from the walker, then the seal chain for files that pass it.
///
/// Static eligibility only. It is not authorization to modify: the write path
/// rechecks everything with fresh inputs, and `codesign --verify` stays the
/// authority on the bundle's signature.
public enum BundleClassifier {
    public static func classify(_ bundle: URL) -> WalkResult {
        var result = BundleWalker.walk(bundle)
        guard result.files.contains(where: \.isEligible) else { return result }

        var chain: SealChain
        do {
            chain = SealChain(tree: try FileTree(bundle))
        } catch {
            let reason = SkipReason.signatureMetadata("cannot open the bundle: \(error)")
            result.files = result.files.map { $0.isEligible ? $0.with(.skip(reason)) : $0 }
            return result
        }

        result.files = result.files.map { file in
            guard file.isEligible, let reason = chain.check(file.relativePath) else { return file }
            return file.with(.skip(reason))
        }
        return result
    }
}

extension WalkedFile {
    var isEligible: Bool { decision.isEligible }

    func with(_ decision: Decision) -> WalkedFile {
        WalkedFile(relativePath: relativePath, size: size, architectures: architectures, decision: decision)
    }
}

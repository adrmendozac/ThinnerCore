import CommonCrypto
import Foundation

/// What identifies one installed version of an app.
///
/// Thinning changes none of these: it never touches `Info.plist`, and the
/// top-level `CodeResources` seals nested code by requirement, not by the
/// bytes thinning removes. Any update changes at least one of them. Restore
/// compares the identity recorded when the app was thinned with the app on
/// disk, and refuses to put old backups into a different version.
///
/// The write path must record this in its journal under `journalKey` before
/// the first swap. A journal without it cannot prove which version its
/// backups belong to, so restore refuses it.
public struct AppIdentity: Codable, Equatable, Sendable, CustomStringConvertible {
    public static let journalKey = "appIdentity"

    public let bundleIdentifier: String?
    /// `CFBundleVersion`.
    public let bundleVersion: String?
    /// `CFBundleShortVersionString`.
    public let shortVersion: String?
    /// SHA-256 of `Contents/_CodeSignature/CodeResources`, lowercase hex.
    public let codeResourcesHash: String

    public init(bundleIdentifier: String?, bundleVersion: String?, shortVersion: String?, codeResourcesHash: String) {
        self.bundleIdentifier = bundleIdentifier
        self.bundleVersion = bundleVersion
        self.shortVersion = shortVersion
        self.codeResourcesHash = codeResourcesHash
    }

    /// Reads the identity of the app at `app` without following any symlink.
    /// An app without sealed resources has no identity: it cannot have been
    /// thinned, because thinning requires a valid signature.
    public static func of(_ app: URL) throws(Problem) -> AppIdentity {
        let tree = try FileTree(app)
        let plistData = try tree.read(["Contents", "Info.plist"], limit: 16 << 20)
        guard let info = (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any] else {
            throw Problem("Info.plist is not a property list dictionary")
        }
        guard try tree.kind(["Contents", "_CodeSignature", "CodeResources"]) == .regular else {
            throw Problem("the app has no sealed resources (Contents/_CodeSignature/CodeResources)")
        }
        let seal = try tree.read(["Contents", "_CodeSignature", "CodeResources"], limit: 256 << 20)
        return AppIdentity(
            bundleIdentifier: info["CFBundleIdentifier"] as? String,
            bundleVersion: info["CFBundleVersion"] as? String,
            shortVersion: info["CFBundleShortVersionString"] as? String,
            codeResourcesHash: sha256Hex(seal)
        )
    }

    public var description: String {
        let id = bundleIdentifier ?? "unknown bundle ID"
        let version = [shortVersion, bundleVersion.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        return "\(id) \(version.isEmpty ? "unknown version" : version), seal \(codeResourcesHash.prefix(12))"
    }
}

func sha256Hex(_ data: Data) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { raw in
        _ = CC_SHA256(raw.baseAddress, CC_LONG(raw.count), &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
}

import Foundation

/// errno alone cannot establish which process receives App Management TCC
/// attribution. Do not tell users that sudo or a grant to this CLI fixes it.
public enum PermissionDiagnostic {
    public static func describe(_ code: Int32, path: String) -> String {
        let detail = String(cString: strerror(code))
        switch code {
        case EACCES:
            return "\(path): \(detail). Check ownership, directory search permissions, and ACLs for this path."
        case EPERM:
            return "\(path): \(detail). Check file flags and macOS Privacy & Security settings, including App Management. Permission attribution to the CLI or launching terminal has not been established; sudo is not a guaranteed remedy."
        case EROFS:
            return "\(path): \(detail). The volume is read-only; protected volumes cannot be modified."
        default:
            return "\(path): \(detail)"
        }
    }
}

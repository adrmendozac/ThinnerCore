import Foundation

/// Refuses to thin unless the hardware has arm64 and the tool is running
/// natively, not under Rosetta translation.
enum HostGate {
    enum Refusal: Equatable, CustomStringConvertible {
        case notARM64
        case translated
        
        var description: String {
            switch self {
            case .notARM64:
                return "Host machine is not Apple Silicon (arm64). Thinning apps for Apple Silicon on Intel hardware would result in unrunnable apps."
            case .translated:
                return "The tool is running under Rosetta translation. It must be run natively."
            }
        }
    }
    
    /// Nil when the host is suitable; the refusal reason otherwise.
    static func check() -> Refusal? {
        if sysctl("hw.optional.arm64") != 1 {
            return .notARM64
        }
        // If sysctl.proc_translated is 1, we are translated. If it doesn't exist or is 0, we are native.
        if sysctl("sysctl.proc_translated") == 1 {
            return .translated
        }
        return nil
    }
    
    /// Read an int32 sysctl by name. Returns nil if the key does not exist.
    private static func sysctl(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

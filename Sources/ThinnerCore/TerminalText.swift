import Foundation

/// Display untrusted filenames and error text without interpreting terminal
/// controls. JSON keeps the original strings, encoded by JSONEncoder.
///
/// Escaped: C0 and C1 controls; the Unicode line and paragraph separators,
/// which could start a forged report line; and the bidirectional controls,
/// which could make a path display as a different one.
public enum TerminalText {
    private static func isUnsafe(_ value: UInt32) -> Bool {
        switch value {
        case 0..<32, 127...159: true
        case 0x061C, 0x200E, 0x200F, 0x2028...0x202E, 0x2066...0x2069: true
        default: false
        }
    }

    public static func sanitize(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            if isUnsafe(scalar.value) {
                return String(format: "\\u{%02X}", scalar.value)
            }
            return String(scalar)
        }.joined()
    }
}

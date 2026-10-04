import Foundation

/// Display untrusted filenames and error text without interpreting terminal
/// controls. JSON keeps the original strings, encoded by JSONEncoder.
public enum TerminalText {
    public static func sanitize(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            if scalar.value < 32 || (127...159).contains(scalar.value) {
                return String(format: "\\u{%02X}", scalar.value)
            }
            return String(scalar)
        }.joined()
    }
}

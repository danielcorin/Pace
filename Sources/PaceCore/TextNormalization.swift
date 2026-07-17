import Foundation

public extension String {
    /// The string with every run of whitespace — spaces, tabs, newlines, and
    /// non-breaking spaces — collapsed to a single space and the ends trimmed.
    var trimmedSingleLine: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

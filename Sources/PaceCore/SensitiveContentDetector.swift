import Foundation

public struct SensitiveContentDetector: Sendable {
    public static let concealedPasteboardTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "com.agilebits.onepassword",
        "com.1password.password",
        "com.bitwarden.desktop"
    ]

    public init() {}

    public func isSensitive(typeIdentifiers: [String], text: String?) -> Bool {
        if !Set(typeIdentifiers).isDisjoint(with: Self.concealedPasteboardTypes) {
            return true
        }

        guard let text else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains("-----BEGIN ") && trimmed.contains("PRIVATE KEY-----") {
            return true
        }

        let patterns = [
            #"\b(?:sk|rk|pk)-(?:live|test|proj)-[A-Za-z0-9_-]{16,}\b"#,
            #"\bgh[opusr]_[A-Za-z0-9]{30,}\b"#,
            #"\bAKIA[0-9A-Z]{16}\b"#
        ]
        for pattern in patterns where trimmed.range(of: pattern, options: .regularExpression) != nil {
            return true
        }

        return containsLikelyPaymentCard(trimmed)
    }

    // A bare "13–19 digits" heuristic flags ordinary numeric IDs — crash
    // reports and logs are full of them (mach absolute times, thread state).
    // Only treat a digit run as a card number when it is contiguous or
    // properly grouped, starts with a known brand prefix at a valid length,
    // and passes the Luhn checksum.
    private func containsLikelyPaymentCard(_ text: String) -> Bool {
        let candidatePatterns = [
            #"\b\d{13,19}\b"#,
            #"\b\d{4}[ -]\d{4}[ -]\d{4}[ -]\d{4}\b"#,
            #"\b\d{4}[ -]\d{6}[ -]\d{5}\b"#
        ]
        for pattern in candidatePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            var found = false
            regex.enumerateMatches(in: text, range: range) { match, _, stop in
                guard let match, let matchRange = Range(match.range, in: text) else { return }
                let digits = String(text[matchRange].filter(\.isNumber))
                if Self.hasCardBrandShape(digits), Self.isLuhnValid(digits) {
                    found = true
                    stop.pointee = true
                }
            }
            if found { return true }
        }
        return false
    }

    private static func hasCardBrandShape(_ digits: String) -> Bool {
        let length = digits.count
        if digits.hasPrefix("4") { return [13, 16, 19].contains(length) }               // Visa
        guard let two = Int(digits.prefix(2)),
              let three = Int(digits.prefix(3)),
              let four = Int(digits.prefix(4)) else { return false }
        if (51...55).contains(two) || (2221...2720).contains(four) { return length == 16 }  // Mastercard
        if two == 34 || two == 37 { return length == 15 }                               // Amex
        if four == 6011 || two == 64 || two == 65 { return (16...19).contains(length) } // Discover
        if two == 62 { return (16...19).contains(length) }                              // UnionPay
        if (3528...3589).contains(four) { return (16...19).contains(length) }           // JCB
        if (300...305).contains(three) || two == 36 || two == 38 {                      // Diners
            return (14...19).contains(length)
        }
        return false
    }

    private static func isLuhnValid(_ digits: String) -> Bool {
        guard !digits.isEmpty else { return false }
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard let value = character.wholeNumberValue else { return false }
            let doubled = value * 2
            sum += index % 2 == 1 ? (doubled > 9 ? doubled - 9 : doubled) : value
        }
        return sum % 10 == 0
    }
}

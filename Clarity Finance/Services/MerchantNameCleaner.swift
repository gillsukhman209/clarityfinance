import Foundation

enum MerchantNameCleaner {
    static func clean(_ name: String) -> String {
        let original = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return "Unknown Merchant" }

        var cleaned = original
            .replacingOccurrences(of: #"(?i)\bTST\*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bSQ\s?\*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bSP\s?\*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bPAYPAL\s?\*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bAPPLE\.COM/BILL\b"#, with: "Apple", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bAMZN MKTP\b"#, with: "Amazon", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bAMAZON MKTPL\*.*"#, with: "Amazon", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bUBER\s+\*TRIP\b"#, with: "Uber", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bLYFT\s+\*RIDE\b"#, with: "Lyft", options: .regularExpression)

        cleaned = removeAddressFragments(from: cleaned)
        cleaned = removeTrailingReferenceCodes(from: cleaned)
        cleaned = collapseWhitespace(cleaned)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " -*#.,"))

        return cleaned.isEmpty ? original : titleCaseIfAllCaps(cleaned)
    }

    private static func removeAddressFragments(from name: String) -> String {
        var parts = name.components(separatedBy: CharacterSet(charactersIn: "•|"))
        if parts.count > 1 {
            parts = [parts[0]]
        }

        let addressStartPattern = #"(?i)\b(?:\d{2,}\s+[A-Z0-9]|[A-Z]{2}\s+\d{5}(?:-\d{4})?|UNITED STATES|USA|US)$"#
        var cleaned = parts[0]

        while let range = cleaned.range(of: addressStartPattern, options: .regularExpression) {
            cleaned.removeSubrange(range)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let cityStatePattern = #"(?i)\s+[A-Z][A-Z .'-]{2,},?\s+[A-Z]{2}(?:\s+\d{5}(?:-\d{4})?)?.*$"#
        if let range = cleaned.range(of: cityStatePattern, options: .regularExpression) {
            cleaned.removeSubrange(range)
        }

        return cleaned
    }

    private static func removeTrailingReferenceCodes(from name: String) -> String {
        name
            .replacingOccurrences(of: #"\s+#?\d{4,}\b.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+\*?[A-Z0-9]{8,}\b.*$"#, with: "", options: .regularExpression)
    }

    private static func collapseWhitespace(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    private static func titleCaseIfAllCaps(_ name: String) -> String {
        let letters = name.filter(\.isLetter)
        guard !letters.isEmpty, letters.allSatisfy(\.isUppercase) else { return name }

        let keepUppercase: Set<String> = ["HBO", "KFC", "AMC", "UPS", "USPS", "ATM", "ACH"]
        return name
            .split(separator: " ")
            .map { word in
                let value = String(word)
                return keepUppercase.contains(value) ? value : value.capitalized
            }
            .joined(separator: " ")
    }
}

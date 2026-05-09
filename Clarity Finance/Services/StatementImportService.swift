import Foundation
import PDFKit

struct StatementImportResult {
    var account: FinancialAccount
    var transactions: [FinanceTransaction]
}

enum StatementImportService {
    static func importAppleCardStatement(from url: URL) throws -> StatementImportResult {
        guard let document = PDFDocument(url: url) else {
            throw StatementImportError.unreadablePDF
        }

        var text = ""
        for pageIndex in 0..<document.pageCount {
            if let pageText = document.page(at: pageIndex)?.string {
                text.append(pageText)
                text.append("\n")
            }
        }

        let transactions = parseTransactions(from: text)
        guard !transactions.isEmpty else {
            throw StatementImportError.noTransactionsFound
        }

        let balance = parseStatementBalance(from: text) ?? transactions
            .filter { !$0.isIncome }
            .reduce(0) { $0 + abs($1.amount) }

        let account = FinancialAccount(
            id: "manual-apple-card",
            institutionName: "Apple Card",
            name: "Apple Card Statement",
            mask: "PDF",
            kind: .creditCard,
            currentBalance: balance,
            availableBalance: nil,
            currencyCode: "USD",
            isManual: true
        )

        return StatementImportResult(account: account, transactions: transactions)
    }

    private static func parseTransactions(from text: String) -> [FinanceTransaction] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return lines.compactMap { line in
            parseTransactionLine(line)
        }
    }

    private static func parseTransactionLine(_ line: String) -> FinanceTransaction? {
        let patterns = [
            #"^(\d{1,2}/\d{1,2}(?:/\d{2,4})?)\s+(.+?)\s+\$?(-?\d{1,3}(?:,\d{3})*\.\d{2})$"#,
            #"^([A-Z][a-z]{2}\s+\d{1,2})\s+(.+?)\s+\$?(-?\d{1,3}(?:,\d{3})*\.\d{2})$"#
        ]

        for pattern in patterns {
            guard let match = firstMatch(pattern: pattern, in: line) else {
                continue
            }

            let dateText = match[0]
            let merchant = cleanupMerchant(match[1])
            let amountText = match[2].replacingOccurrences(of: ",", with: "")
            guard let amount = Double(amountText), let date = parseDate(dateText) else {
                continue
            }

            return FinanceTransaction(
                id: "apple-pdf-\(date.timeIntervalSince1970)-\(merchant)-\(amount)",
                accountID: "manual-apple-card",
                merchantName: merchant,
                originalName: line,
                amount: amount,
                date: date,
                category: resolveCategory(for: merchant),
                pending: false,
                source: "Apple Card PDF"
            )
        }

        return nil
    }

    private static func parseStatementBalance(from text: String) -> Double? {
        let patterns = [
            #"(?i)new balance\s+\$?(\d{1,3}(?:,\d{3})*\.\d{2})"#,
            #"(?i)statement balance\s+\$?(\d{1,3}(?:,\d{3})*\.\d{2})"#,
            #"(?i)total balance\s+\$?(\d{1,3}(?:,\d{3})*\.\d{2})"#
        ]

        for pattern in patterns {
            guard let match = firstMatch(pattern: pattern, in: text) else {
                continue
            }
            return Double(match[0].replacingOccurrences(of: ",", with: ""))
        }

        return nil
    }

    private static func parseDate(_ text: String) -> Date? {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())

        let slashFormats = ["M/d/yyyy", "M/d/yy", "M/d"]
        for format in slashFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let parsed = formatter.date(from: text) {
                if format == "M/d" {
                    var components = calendar.dateComponents([.month, .day], from: parsed)
                    components.year = currentYear
                    return calendar.date(from: components)
                }
                return parsed
            }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d yyyy"
        return formatter.date(from: "\(text) \(currentYear)")
    }

    private static func cleanupMerchant(_ merchant: String) -> String {
        merchant
            .replacingOccurrences(of: #"(?i)\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveCategory(for merchant: String) -> TransactionCategory {
        let lowercased = merchant.lowercased()
        if lowercased.contains("apple") || lowercased.contains("netflix") || lowercased.contains("spotify") { return .subscriptions }
        if lowercased.contains("starbucks") || lowercased.contains("coffee") || lowercased.contains("whole") || lowercased.contains("restaurant") { return .food }
        if lowercased.contains("uber") || lowercased.contains("lyft") || lowercased.contains("shell") || lowercased.contains("chevron") { return .transport }
        if lowercased.contains("target") || lowercased.contains("amazon") || lowercased.contains("store") { return .shopping }
        if lowercased.contains("pharmacy") || lowercased.contains("medical") { return .health }
        return .other
    }

    private static func firstMatch(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return nil
        }

        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }
}

enum StatementImportError: LocalizedError {
    case unreadablePDF
    case noTransactionsFound

    var errorDescription: String? {
        switch self {
        case .unreadablePDF:
            "The selected PDF could not be opened."
        case .noTransactionsFound:
            "No transactions were found in that PDF. This parser works only when the PDF exposes transaction text."
        }
    }
}

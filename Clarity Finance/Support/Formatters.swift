import Foundation

enum MoneyFormat {
    static func currency(_ amount: Double, code: String = "USD", showsSign: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        formatter.positivePrefix = showsSign && amount > 0 ? "+\(formatter.positivePrefix ?? "")" : formatter.positivePrefix
        return formatter.string(from: NSNumber(value: amount)) ?? "$0.00"
    }

    static func compact(_ amount: Double, code: String = "USD") -> String {
        let absolute = abs(amount)
        let suffix: String
        let value: Double

        if absolute >= 1_000_000 {
            suffix = "M"
            value = amount / 1_000_000
        } else if absolute >= 1_000 {
            suffix = "k"
            value = amount / 1_000
        } else {
            suffix = ""
            value = amount
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = suffix.isEmpty ? 0 : 1
        return "\(formatter.string(from: NSNumber(value: value)) ?? "$0")\(suffix)"
    }
}

extension Date {
    static func daysFromNow(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
    }

    static func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    }
}

extension Array where Element == FinanceTransaction {
    var monthlyExpenseTotal: Double {
        let calendar = Calendar.current
        return filter {
            !$0.isIncome && calendar.isDate($0.date, equalTo: Date(), toGranularity: .month)
        }
        .reduce(0) { $0 + abs($1.amount) }
    }
}

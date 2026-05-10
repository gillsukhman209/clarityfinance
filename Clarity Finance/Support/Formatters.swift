import Foundation

enum MoneyFormat {
    static func currency(_ amount: Double, code: String = "USD", showsSign: Bool = false) -> String {
        let formatted = amount.formatted(.currency(code: code).precision(.fractionLength(2)))
        return showsSign && amount > 0 ? "+\(formatted)" : formatted
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

        let formatted = value.formatted(
            .currency(code: code)
                .precision(.fractionLength(suffix.isEmpty ? 0 : 1))
        )
        return "\(formatted)\(suffix)"
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

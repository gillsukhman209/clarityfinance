import Foundation

enum InsightTone: String, Hashable {
    case good
    case warning
    case urgent
    case neutral
}

struct MoneyInsight: Identifiable, Hashable {
    var id: String
    var title: String
    var message: String
    var action: String
    var symbolName: String
    var tone: InsightTone
    var amount: Double?
    var shareLine: String
}

struct SpendingPersonality: Hashable {
    var title: String
    var subtitle: String
    var symbolName: String
}

struct MoneyWrapped: Hashable {
    var monthTitle: String
    var totalSpent: Double
    var topCategory: TransactionCategory?
    var topCategoryAmount: Double
    var topMerchant: String?
    var topMerchantAmount: Double
    var biggestTransaction: FinanceTransaction?
    var subscriptionsTotal: Double
    var expensiveDay: String
    var personality: SpendingPersonality

    var shareLines: [String] {
        [
            "\(monthTitle) Money Wrapped",
            "Total spent: \(MoneyFormat.currency(totalSpent))",
            topCategory.map { "Top category: \($0.title) \(MoneyFormat.currency(topCategoryAmount))" },
            topMerchant.map { "Top merchant: \($0) \(MoneyFormat.currency(topMerchantAmount))" },
            "Recurring charges: \(MoneyFormat.currency(subscriptionsTotal))/mo",
            "Spending personality: \(personality.title)"
        ]
        .compactMap { $0 }
    }
}

struct SubscriptionIntelligence: Identifiable, Hashable {
    var id: String { subscription.id }
    var subscription: SubscriptionItem
    var account: FinancialAccount?
    var totalPaidThisYear: Double
    var chargeCount: Int
    var confidence: Double
    var isCancelCandidate: Bool
    var correction: RecurringChargeCorrection?

    var isIgnored: Bool {
        correction == .ignored
    }

    var confidenceLabel: String {
        if confidence >= 0.84 { return "High confidence" }
        if confidence >= 0.58 { return "Medium confidence" }
        return "Needs review"
    }

    var statusLine: String {
        if correction == .ignored { return "Hidden by you" }
        if correction == .subscription { return "Marked subscription by you" }
        if correction == .bill { return "Marked bill by you" }
        if !subscription.isActive { return "Inactive" }
        return subscription.frequency.isEmpty ? "Recurring" : subscription.frequency.lowercased().replacingOccurrences(of: "_", with: " ")
    }
}

enum AffordabilityVerdict: Hashable {
    case yes
    case caution
    case no

    var title: String {
        switch self {
        case .yes: "You can afford it"
        case .caution: "Maybe, but be careful"
        case .no: "Not smart right now"
        }
    }

    var symbolName: String {
        switch self {
        case .yes: "checkmark.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .no: "xmark.circle.fill"
        }
    }
}

struct AffordabilityDecision: Hashable {
    var verdict: AffordabilityVerdict
    var message: String
    var impact: String
    var suggestion: String
}

enum FinanceCoachEngine {
    static func insights(
        transactions: [FinanceTransaction],
        subscriptions: [SubscriptionItem],
        accounts: [FinancialAccount],
        anchor: Date
    ) -> [MoneyInsight] {
        let monthTransactions = expenseTransactions(transactions, inMonthOf: anchor)
        guard !monthTransactions.isEmpty else {
            return [
                MoneyInsight(
                    id: "empty",
                    title: "Connect more history",
                    message: "I need real transactions before I can coach your spending.",
                    action: "Connect accounts or import statements.",
                    symbolName: "arrow.triangle.2.circlepath",
                    tone: .neutral,
                    amount: nil,
                    shareLine: "Clarity is building my money picture."
                )
            ]
        }

        var output: [MoneyInsight] = []
        let calendar = Calendar.current
        let previousAnchor = calendar.date(byAdding: .month, value: -1, to: anchor) ?? anchor
        let monthTotal = monthTransactions.reduce(0) { $0 + abs($1.amount) }
        let previousTotal = expenseTransactions(transactions, inMonthOf: previousAnchor).reduce(0) { $0 + abs($1.amount) }

        if previousTotal > 0 {
            let delta = monthTotal - previousTotal
            let percent = delta / previousTotal
            if percent >= 0.15 {
                output.append(MoneyInsight(
                    id: "month-up",
                    title: "Your spending jumped",
                    message: "You are \(Self.percent(percent)) higher than last month.",
                    action: "Check the top category below before this becomes the new normal.",
                    symbolName: "chart.line.uptrend.xyaxis",
                    tone: .warning,
                    amount: delta,
                    shareLine: "My spending is up \(Self.percent(percent)) this month."
                ))
            } else if percent <= -0.12 {
                output.append(MoneyInsight(
                    id: "month-down",
                    title: "You pulled spending down",
                    message: "You are \(Self.percent(abs(percent))) lower than last month.",
                    action: "Keep the same pattern for another two weeks.",
                    symbolName: "arrow.down.right.circle.fill",
                    tone: .good,
                    amount: abs(delta),
                    shareLine: "I cut spending by \(Self.percent(abs(percent))) this month."
                ))
            }
        }

        if let topCategory = topCategory(from: monthTransactions) {
            output.append(MoneyInsight(
                id: "top-category-\(topCategory.category.rawValue)",
                title: "\(topCategory.category.title) is running the month",
                message: "\(MoneyFormat.currency(topCategory.total)) has gone here so far.",
                action: "Set one small rule for this category before your next purchase.",
                symbolName: topCategory.category.symbolName,
                tone: topCategory.total > monthTotal * 0.35 ? .warning : .neutral,
                amount: topCategory.total,
                shareLine: "My top spending category is \(topCategory.category.title)."
            ))
        }

        if let topMerchant = topMerchant(from: monthTransactions), topMerchant.count >= 2 {
            output.append(MoneyInsight(
                id: "top-merchant-\(normalized(topMerchant.name))",
                title: "\(topMerchant.name) keeps showing up",
                message: "\(topMerchant.count) charges this month, totaling \(MoneyFormat.currency(topMerchant.total)).",
                action: "Decide if this merchant is worth becoming a monthly habit.",
                symbolName: "repeat",
                tone: topMerchant.count >= 5 ? .warning : .neutral,
                amount: topMerchant.total,
                shareLine: "\(topMerchant.name) is my most repeated merchant this month."
            ))
        }

        let subscriptionTotal = subscriptions.reduce(0) { $0 + $1.monthlyAmount }
        if subscriptionTotal > 0 {
            output.append(MoneyInsight(
                id: "subscriptions",
                title: "Recurring charges are your quiet bill",
                message: "Subscriptions add up to \(MoneyFormat.currency(subscriptionTotal)) every month.",
                action: "Review anything you would not sign up for again today.",
                symbolName: "calendar.badge.clock",
                tone: subscriptionTotal >= 150 ? .urgent : .warning,
                amount: subscriptionTotal,
                shareLine: "My subscriptions cost \(MoneyFormat.currency(subscriptionTotal))/mo."
            ))
        }

        let weekday = mostExpensiveWeekday(from: monthTransactions)
        if weekday.total > 0 {
            output.append(MoneyInsight(
                id: "weekday-\(weekday.name)",
                title: "\(weekday.name) is your expensive day",
                message: "You spent \(MoneyFormat.currency(weekday.total)) on \(weekday.name)s this month.",
                action: "Plan that day before it plans your wallet.",
                symbolName: "calendar",
                tone: .neutral,
                amount: weekday.total,
                shareLine: "\(weekday.name) is my expensive day."
            ))
        }

        let creditDebt = accounts
            .filter { $0.kind.isLiability }
            .reduce(0) { $0 + $1.currentBalance }
        if creditDebt > 0 {
            output.append(MoneyInsight(
                id: "credit-debt",
                title: "Debt is part of your net worth",
                message: "Your credit and loan balance is \(MoneyFormat.currency(creditDebt)).",
                action: "Treat payoff like a bill, not a leftover.",
                symbolName: "creditcard.fill",
                tone: .warning,
                amount: creditDebt,
                shareLine: "Clarity showed me my real debt number."
            ))
        }

        return Array(output.prefix(8))
    }

    static func wrapped(
        transactions: [FinanceTransaction],
        subscriptions: [SubscriptionItem],
        anchor: Date
    ) -> MoneyWrapped {
        let monthTransactions = expenseTransactions(transactions, inMonthOf: anchor)
        let category = topCategory(from: monthTransactions)
        let merchant = topMerchant(from: monthTransactions)
        let biggest = monthTransactions.max { abs($0.amount) < abs($1.amount) }
        let weekday = mostExpensiveWeekday(from: monthTransactions)

        return MoneyWrapped(
            monthTitle: anchor.formatted(.dateTime.month(.wide).year()),
            totalSpent: monthTransactions.reduce(0) { $0 + abs($1.amount) },
            topCategory: category?.category,
            topCategoryAmount: category?.total ?? 0,
            topMerchant: merchant?.name,
            topMerchantAmount: merchant?.total ?? 0,
            biggestTransaction: biggest,
            subscriptionsTotal: subscriptions.reduce(0) { $0 + $1.monthlyAmount },
            expensiveDay: weekday.name,
            personality: personality(for: transactions, subscriptions: subscriptions, anchor: anchor)
        )
    }

    static func personality(
        for transactions: [FinanceTransaction],
        subscriptions: [SubscriptionItem],
        anchor: Date
    ) -> SpendingPersonality {
        let monthTransactions = expenseTransactions(transactions, inMonthOf: anchor)
        let total = monthTransactions.reduce(0) { $0 + abs($1.amount) }
        let category = topCategory(from: monthTransactions)
        let subscriptionTotal = subscriptions.reduce(0) { $0 + $1.monthlyAmount }

        if subscriptionTotal > 0, subscriptionTotal >= total * 0.18 {
            return SpendingPersonality(
                title: "Subscription Collector",
                subtitle: "Tiny charges are teaming up on you.",
                symbolName: "calendar.badge.clock"
            )
        }

        switch category?.category {
        case .food:
            return SpendingPersonality(title: "Convenience Maxxer", subtitle: "Food and quick decisions are carrying the month.", symbolName: "fork.knife")
        case .shopping:
            return SpendingPersonality(title: "Cart Philosopher", subtitle: "Your cart has opinions and a budget impact.", symbolName: "bag.fill")
        case .transport:
            return SpendingPersonality(title: "Always En Route", subtitle: "Getting around is one of your loudest expenses.", symbolName: "car.fill")
        case .entertainment:
            return SpendingPersonality(title: "Vibes Investor", subtitle: "Experiences are getting a real allocation.", symbolName: "play.tv.fill")
        case .housing:
            return SpendingPersonality(title: "Fixed Cost Realist", subtitle: "The big bills are setting the tone.", symbolName: "house.fill")
        default:
            return SpendingPersonality(title: "Balanced Chaos", subtitle: "Your money is spread out, but still needs rules.", symbolName: "sparkles")
        }
    }

    static func subscriptionIntelligence(
        subscriptions: [SubscriptionItem],
        transactions: [FinanceTransaction],
        accounts: [FinancialAccount],
        corrections: [String: RecurringChargeCorrection]
    ) -> [SubscriptionIntelligence] {
        subscriptions.map { subscription in
            let matching = matchingTransactions(for: subscription, in: transactions)
            let calendar = Calendar.current
            let thisYear = matching.filter { calendar.isDate($0.date, equalTo: Date(), toGranularity: .year) }
            let chargeCount = matching.count
            let confidence = confidenceScore(subscription: subscription, matchingTransactions: matching)
            let totalPaid = thisYear.reduce(0) { $0 + abs($1.amount) }
            let cancelCandidate = subscription.recurringKind == .subscription && subscription.monthlyAmount >= 50
            let account = subscription.accountID.flatMap { id in accounts.first { $0.id == id } }
            let correction = corrections[subscriptionKey(subscription)]

            return SubscriptionIntelligence(
                subscription: subscription,
                account: account,
                totalPaidThisYear: totalPaid,
                chargeCount: chargeCount,
                confidence: confidence,
                isCancelCandidate: cancelCandidate,
                correction: correction
            )
        }
        .sorted {
            if $0.isIgnored != $1.isIgnored {
                return !$0.isIgnored
            }
            if $0.subscription.recurringKind != $1.subscription.recurringKind {
                return $0.subscription.recurringKind == .subscription
            }
            return $0.subscription.monthlyAmount > $1.subscription.monthlyAmount
        }
    }

    static func affordabilityDecision(
        price: Double,
        category: TransactionCategory,
        isMonthly: Bool,
        transactions: [FinanceTransaction],
        accounts: [FinancialAccount],
        anchor: Date
    ) -> AffordabilityDecision {
        let income = incomeTransactions(transactions, inMonthOf: anchor).reduce(0) { $0 + abs($1.amount) }
        let checkingCash = accounts
            .filter { !$0.kind.isLiability }
            .reduce(0) { $0 + ($1.availableBalance ?? $1.currentBalance) }
        let categorySpent = expenseTransactions(transactions, inMonthOf: anchor)
            .filter { $0.category == category }
            .reduce(0) { $0 + abs($1.amount) }
        let effectivePrice = isMonthly ? price * 3 : price
        let cashRatio = checkingCash > 0 ? effectivePrice / checkingCash : 1
        let incomeRatio = income > 0 ? effectivePrice / income : cashRatio

        if cashRatio <= 0.05 && incomeRatio <= 0.08 {
            return AffordabilityDecision(
                verdict: .yes,
                message: "This fits your current money picture.",
                impact: "It would bring \(category.title) to \(MoneyFormat.currency(categorySpent + price)) this month.",
                suggestion: isMonthly ? "Still cancel something else if this becomes recurring." : "Buy it once, then keep the category calm."
            )
        }

        if cashRatio <= 0.14 && incomeRatio <= 0.18 {
            return AffordabilityDecision(
                verdict: .caution,
                message: "You can probably do it, but it will be noticeable.",
                impact: "This is \(Self.percent(incomeRatio)) of this month's tracked income.",
                suggestion: "Wait 24 hours or offset it by skipping one flexible category."
            )
        }

        return AffordabilityDecision(
            verdict: .no,
            message: "This is not smart right now.",
            impact: "It is too large compared with your current cash or income pattern.",
            suggestion: "Delay it, split it into savings, or remove a recurring charge first."
        )
    }

    static func subscriptionKey(_ subscription: SubscriptionItem) -> String {
        if subscription.source == .plaid {
            return subscription.id
        }

        return "\(subscription.accountID ?? "all")|\(MerchantNameCleaner.canonicalKey(for: subscription.displayName))"
    }

    static func matchingTransactions(for subscription: SubscriptionItem, in transactions: [FinanceTransaction]) -> [FinanceTransaction] {
        if let merchantKey = aiMerchantKey(for: subscription) {
            return transactions
                .filter { transaction in
                    guard !transaction.isIncome else { return false }
                    if let accountID = subscription.accountID, transaction.accountID != accountID {
                        return false
                    }
                    return MerchantNameCleaner.canonicalKey(for: transaction.merchantName) == merchantKey ||
                        MerchantNameCleaner.canonicalKey(for: transaction.originalName) == merchantKey
                }
                .sorted { $0.date > $1.date }
        }

        let merchantKeys = [
            subscription.merchantName,
            subscription.displayName
        ]
        .flatMap { value in
            [
                normalized(value),
                MerchantNameCleaner.canonicalKey(for: value)
            ]
        }
        .filter { !$0.isEmpty && $0 != "unknown merchant" }

        guard !merchantKeys.isEmpty else { return [] }

        return transactions
            .filter { transaction in
                guard !transaction.isIncome else { return false }
                if let accountID = subscription.accountID, transaction.accountID != accountID {
                    return false
                }
                let transactionKeys = [
                    transaction.merchantName,
                    transaction.originalName
                ]
                .flatMap { value in
                    [
                        normalized(value),
                        MerchantNameCleaner.canonicalKey(for: value)
                    ]
                }
                .filter { !$0.isEmpty }

                return transactionKeys.contains { transactionKey in
                    merchantKeys.contains { merchantKey in
                        transactionKey.contains(merchantKey) || merchantKey.contains(transactionKey)
                    }
                }
            }
            .sorted { $0.date > $1.date }
    }

    private static func aiMerchantKey(for subscription: SubscriptionItem) -> String? {
        guard subscription.source == .ai else { return nil }
        let prefix = "ai-recurring-"
        guard subscription.id.hasPrefix(prefix) else {
            return MerchantNameCleaner.canonicalKey(for: subscription.displayName)
        }
        return String(subscription.id.dropFirst(prefix.count))
    }

    private static func expenseTransactions(_ transactions: [FinanceTransaction], inMonthOf anchor: Date) -> [FinanceTransaction] {
        transactions.filter {
            !$0.isIncome && Calendar.current.isDate($0.date, equalTo: anchor, toGranularity: .month)
        }
    }

    private static func incomeTransactions(_ transactions: [FinanceTransaction], inMonthOf anchor: Date) -> [FinanceTransaction] {
        transactions.filter {
            $0.isIncome && Calendar.current.isDate($0.date, equalTo: anchor, toGranularity: .month)
        }
    }

    private static func topCategory(from transactions: [FinanceTransaction]) -> (category: TransactionCategory, total: Double)? {
        Dictionary(grouping: transactions, by: \.category)
            .map { category, transactions in
                (category: category, total: transactions.reduce(0) { $0 + abs($1.amount) })
            }
            .max { $0.total < $1.total }
    }

    private static func topMerchant(from transactions: [FinanceTransaction]) -> (name: String, total: Double, count: Int)? {
        Dictionary(grouping: transactions, by: \.merchantName)
            .map { merchant, transactions in
                (name: merchant, total: transactions.reduce(0) { $0 + abs($1.amount) }, count: transactions.count)
            }
            .max { $0.total < $1.total }
    }

    private static func mostExpensiveWeekday(from transactions: [FinanceTransaction]) -> (name: String, total: Double) {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        let totals = Dictionary(grouping: transactions) { transaction in
            formatter.string(from: transaction.date)
        }
        .mapValues { transactions in
            transactions.reduce(0) { $0 + abs($1.amount) }
        }

        let result = totals.max { $0.value < $1.value }
        return (result?.key ?? "Today", result?.value ?? 0)
    }

    private static func confidenceScore(subscription: SubscriptionItem, matchingTransactions: [FinanceTransaction]) -> Double {
        guard subscription.source == .plaid || subscription.source == .ai else { return 0.4 }
        var score = subscription.source == .ai ? 0.72 : 0.8
        if matchingTransactions.count >= 1 { score += 0.08 }
        if matchingTransactions.count >= 2 { score += 0.06 }
        if !subscription.frequency.isEmpty { score += 0.06 }
        if subscription.monthlyAmount > 0 { score += 0.1 }
        return min(score, 0.98)
    }

    private static func percent(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value * 100))%"
    }

    nonisolated private static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

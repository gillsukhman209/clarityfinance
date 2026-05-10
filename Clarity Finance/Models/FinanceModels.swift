import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case coach
    case transactions
    case budget
    case subscriptions
    case netWorth
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Today"
        case .coach: "Advice"
        case .transactions: "Activity"
        case .budget: "Budget"
        case .subscriptions: "Recurring"
        case .netWorth: "Net Worth"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "house.fill"
        case .coach: "sparkles"
        case .transactions: "list.bullet.rectangle.portrait.fill"
        case .budget: "chart.pie.fill"
        case .subscriptions: "calendar.badge.clock"
        case .netWorth: "chart.line.uptrend.xyaxis"
        case .settings: "gearshape.fill"
        }
    }
}

enum AccountKind: String, Codable, CaseIterable {
    case checking
    case savings
    case creditCard
    case investment
    case loan
    case manual

    var title: String {
        switch self {
        case .checking: "Checking"
        case .savings: "Savings"
        case .creditCard: "Credit Card"
        case .investment: "Investment"
        case .loan: "Loan"
        case .manual: "Manual"
        }
    }

    var isLiability: Bool {
        switch self {
        case .creditCard, .loan: true
        case .checking, .savings, .investment, .manual: false
        }
    }

    var symbolName: String {
        switch self {
        case .checking: "building.columns.fill"
        case .savings: "banknote.fill"
        case .creditCard: "creditcard.fill"
        case .investment: "chart.xyaxis.line"
        case .loan: "doc.text.fill"
        case .manual: "doc.richtext.fill"
        }
    }
}

enum TransactionCategory: String, Codable, CaseIterable, Identifiable {
    case food
    case shopping
    case transport
    case housing
    case entertainment
    case health
    case utilities
    case income
    case transfer
    case subscriptions
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .food: "Food"
        case .shopping: "Shopping"
        case .transport: "Transport"
        case .housing: "Housing"
        case .entertainment: "Entertainment"
        case .health: "Health"
        case .utilities: "Utilities"
        case .income: "Income"
        case .transfer: "Transfer"
        case .subscriptions: "Subscriptions"
        case .other: "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .food: "fork.knife"
        case .shopping: "bag.fill"
        case .transport: "car.fill"
        case .housing: "house.fill"
        case .entertainment: "play.tv.fill"
        case .health: "heart.fill"
        case .utilities: "bolt.fill"
        case .income: "arrow.down.circle.fill"
        case .transfer: "arrow.left.arrow.right"
        case .subscriptions: "calendar.badge.clock"
        case .other: "circle.grid.2x2.fill"
        }
    }
}

struct FinancialAccount: Identifiable, Codable, Hashable {
    var id: String
    var institutionName: String
    var name: String
    var mask: String?
    var kind: AccountKind
    var currentBalance: Double
    var availableBalance: Double?
    var currencyCode: String
    var isManual: Bool

    var displayName: String {
        if let mask, !mask.isEmpty {
            "\(name) • \(mask)"
        } else {
            name
        }
    }
}

struct FinanceTransaction: Identifiable, Codable, Hashable {
    var id: String
    var accountID: String
    var merchantName: String
    var originalName: String
    var amount: Double
    var date: Date
    var category: TransactionCategory
    var pending: Bool
    var source: String

    var isIncome: Bool {
        category == .income || amount < 0
    }

    var signedDisplayAmount: Double {
        isIncome ? abs(amount) : -abs(amount)
    }
}

enum RecurringChargeKind: String, Codable, Hashable {
    case subscription
    case bill

    var title: String {
        switch self {
        case .subscription: "Subscription"
        case .bill: "Bill"
        }
    }

    var pluralTitle: String {
        switch self {
        case .subscription: "Subscriptions"
        case .bill: "Bills"
        }
    }

    var symbolName: String {
        switch self {
        case .subscription: "calendar.badge.clock"
        case .bill: "doc.text.fill"
        }
    }
}

enum RecurringChargeSource: String, Codable, Hashable {
    case plaid
    case localLegacy
}

struct SubscriptionItem: Identifiable, Codable, Hashable {
    var id: String
    var merchantName: String
    var category: TransactionCategory
    var monthlyAmount: Double
    var nextExpectedDate: Date
    var accountID: String?
    var recurringKind: RecurringChargeKind
    var source: RecurringChargeSource
    var frequency: String
    var status: String
    var lastAmount: Double
    var averageAmount: Double
    var lastDate: Date?
    var streamDescription: String
    var isActive: Bool

    var displayName: String {
        let cleanedMerchant = MerchantNameCleaner.clean(merchantName)
        if cleanedMerchant != "Unknown Merchant" {
            return cleanedMerchant
        }

        let cleanedDescription = MerchantNameCleaner.clean(streamDescription)
        if cleanedDescription != "Unknown Merchant" {
            return cleanedDescription
        }

        return "Recurring charge"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case merchantName
        case category
        case monthlyAmount
        case nextExpectedDate
        case accountID
        case recurringKind
        case source
        case frequency
        case status
        case lastAmount
        case averageAmount
        case lastDate
        case streamDescription
        case isActive
    }

    init(
        id: String,
        merchantName: String,
        category: TransactionCategory,
        monthlyAmount: Double,
        nextExpectedDate: Date,
        accountID: String?,
        recurringKind: RecurringChargeKind = .subscription,
        source: RecurringChargeSource = .localLegacy,
        frequency: String = "",
        status: String = "",
        lastAmount: Double = 0,
        averageAmount: Double = 0,
        lastDate: Date? = nil,
        streamDescription: String = "",
        isActive: Bool = true
    ) {
        self.id = id
        self.merchantName = merchantName
        self.category = category
        self.monthlyAmount = monthlyAmount
        self.nextExpectedDate = nextExpectedDate
        self.accountID = accountID
        self.recurringKind = recurringKind
        self.source = source
        self.frequency = frequency
        self.status = status
        self.lastAmount = lastAmount
        self.averageAmount = averageAmount
        self.lastDate = lastDate
        self.streamDescription = streamDescription
        self.isActive = isActive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        merchantName = try container.decode(String.self, forKey: .merchantName)
        category = try container.decode(TransactionCategory.self, forKey: .category)
        monthlyAmount = try container.decode(Double.self, forKey: .monthlyAmount)
        nextExpectedDate = try container.decode(Date.self, forKey: .nextExpectedDate)
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
        recurringKind = try container.decodeIfPresent(RecurringChargeKind.self, forKey: .recurringKind) ?? .subscription
        source = try container.decodeIfPresent(RecurringChargeSource.self, forKey: .source) ?? .localLegacy
        frequency = try container.decodeIfPresent(String.self, forKey: .frequency) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        lastAmount = try container.decodeIfPresent(Double.self, forKey: .lastAmount) ?? 0
        averageAmount = try container.decodeIfPresent(Double.self, forKey: .averageAmount) ?? monthlyAmount
        lastDate = try container.decodeIfPresent(Date.self, forKey: .lastDate)
        streamDescription = try container.decodeIfPresent(String.self, forKey: .streamDescription) ?? ""
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
    }
}

struct BudgetCategory: Identifiable, Codable, Hashable {
    var id: String
    var category: TransactionCategory
    var limit: Double
    var spent: Double

    var progress: Double {
        guard limit > 0 else { return 0 }
        return min(spent / limit, 1)
    }
}

struct NetWorthSnapshot: Identifiable, Codable, Hashable {
    var id: String
    var date: Date
    var assets: Double
    var liabilities: Double

    var netWorth: Double {
        assets - liabilities
    }
}

struct PlaidConnection: Identifiable, Codable, Hashable {
    var id: String
    var itemID: String
    var institutionID: String
    var institutionName: String
    var accessToken: String
    var environment: PlaidEnvironment
    var cursor: String?
    var connectedAt: Date
    var lastSyncedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case itemID
        case institutionID
        case institutionName
        case accessToken
        case environment
        case cursor
        case connectedAt
        case lastSyncedAt
    }

    init(
        id: String,
        itemID: String,
        institutionID: String,
        institutionName: String,
        accessToken: String,
        environment: PlaidEnvironment,
        cursor: String?,
        connectedAt: Date,
        lastSyncedAt: Date?
    ) {
        self.id = id
        self.itemID = itemID
        self.institutionID = institutionID
        self.institutionName = institutionName
        self.accessToken = accessToken
        self.environment = environment
        self.cursor = cursor
        self.connectedAt = connectedAt
        self.lastSyncedAt = lastSyncedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        itemID = try container.decode(String.self, forKey: .itemID)
        institutionID = try container.decodeIfPresent(String.self, forKey: .institutionID) ?? "ins_109508"
        institutionName = try container.decode(String.self, forKey: .institutionName)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        environment = try container.decodeIfPresent(PlaidEnvironment.self, forKey: .environment)
            ?? (accessToken.contains("access-production") ? .production : .sandbox)
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor)
        connectedAt = try container.decode(Date.self, forKey: .connectedAt)
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
    }
}

struct FinanceDataSet: Codable {
    var accounts: [FinancialAccount]
    var transactions: [FinanceTransaction]
    var subscriptions: [SubscriptionItem]
    var budgets: [BudgetCategory]
    var netWorthSnapshots: [NetWorthSnapshot]
    var connections: [PlaidConnection]
    var ignoredSubscriptionKeys: Set<String>
    var recurringChargeCorrections: [String: RecurringChargeCorrection]

    static let empty = FinanceDataSet(
        accounts: [],
        transactions: [],
        subscriptions: [],
        budgets: [],
        netWorthSnapshots: [],
        connections: [],
        ignoredSubscriptionKeys: [],
        recurringChargeCorrections: [:]
    )

    enum CodingKeys: String, CodingKey {
        case accounts
        case transactions
        case subscriptions
        case budgets
        case netWorthSnapshots
        case connections
        case ignoredSubscriptionKeys
        case recurringChargeCorrections
    }

    init(
        accounts: [FinancialAccount],
        transactions: [FinanceTransaction],
        subscriptions: [SubscriptionItem],
        budgets: [BudgetCategory],
        netWorthSnapshots: [NetWorthSnapshot],
        connections: [PlaidConnection],
        ignoredSubscriptionKeys: Set<String> = [],
        recurringChargeCorrections: [String: RecurringChargeCorrection] = [:]
    ) {
        self.accounts = accounts
        self.transactions = transactions
        self.subscriptions = subscriptions
        self.budgets = budgets
        self.netWorthSnapshots = netWorthSnapshots
        self.connections = connections
        self.ignoredSubscriptionKeys = ignoredSubscriptionKeys
        self.recurringChargeCorrections = recurringChargeCorrections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decodeIfPresent([FinancialAccount].self, forKey: .accounts) ?? []
        transactions = try container.decodeIfPresent([FinanceTransaction].self, forKey: .transactions) ?? []
        subscriptions = try container.decodeIfPresent([SubscriptionItem].self, forKey: .subscriptions) ?? []
        budgets = try container.decodeIfPresent([BudgetCategory].self, forKey: .budgets) ?? []
        netWorthSnapshots = try container.decodeIfPresent([NetWorthSnapshot].self, forKey: .netWorthSnapshots) ?? []
        connections = try container.decodeIfPresent([PlaidConnection].self, forKey: .connections) ?? []
        ignoredSubscriptionKeys = try container.decodeIfPresent(Set<String>.self, forKey: .ignoredSubscriptionKeys) ?? []
        recurringChargeCorrections = try container.decodeIfPresent([String: RecurringChargeCorrection].self, forKey: .recurringChargeCorrections) ?? [:]
    }
}

enum RecurringChargeCorrection: String, Codable, Hashable {
    case subscription
    case bill
    case ignored
}

struct PlaidSandboxInstitution: Identifiable, Hashable {
    var id: String
    var name: String

    static let firstPlatypus = PlaidSandboxInstitution(
        id: "ins_109508",
        name: "First Platypus Bank"
    )
}

enum PlaidSandboxProfile: String, CaseIterable, Identifiable {
    case transactionsDynamic
    case good

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transactionsDynamic: "Transactions history"
        case .good: "Standard sandbox"
        }
    }

    var username: String {
        switch self {
        case .transactionsDynamic: "user_transactions_dynamic"
        case .good: "user_good"
        }
    }

    var password: String {
        "pass_good"
    }
}
